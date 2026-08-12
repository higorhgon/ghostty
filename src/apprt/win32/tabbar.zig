//! Bindings for ghostty_tabbar.dll -- a WinUI TabView hosted in a XAML
//! Island, which also serves as the window's title bar.
//!
//! Win32 has no tab control with the Windows 11 look, and Zig cannot host
//! XAML without speaking COM by hand, so the control lives behind a flat C
//! ABI in a C++/WinRT DLL. See dist/windows/tabbar/ for the DLL itself and
//! for the non-obvious constraints it works around.
//!
//! The DLL is deliberately dumb: it draws and reports. Every decision --
//! which shells exist, what a tab maps to, whether a tab may close --
//! stays here. In particular a close click is a *request*: the DLL never
//! removes a tab on its own, it calls `on_close_requested` and waits.
//!
//! IMPORTANT: WinUI 2 only activates for a process that has package
//! identity, so a Ghostty built against this must be MSIX-packaged or
//! `create` will fail and we fall back to the hand-drawn GDI strip.

const std = @import("std");

pub const TabId = u64;
pub const ProfileId = u32;

/// Passed as the profile when the user clicks the plain "+" instead of
/// picking a shell from the dropdown.
pub const profile_default: ProfileId = 0xFFFF_FFFF;

pub const CaptionButton = enum(c_int) {
    minimize = 0,
    maximize_restore = 1,
    close = 2,
};

pub const Callbacks = extern struct {
    ctx: ?*anyopaque = null,
    on_selected: ?*const fn (?*anyopaque, TabId) callconv(.c) void = null,
    on_close_requested: ?*const fn (?*anyopaque, TabId) callconv(.c) void = null,
    on_new_tab: ?*const fn (?*anyopaque, ProfileId) callconv(.c) void = null,
    on_caption_button: ?*const fn (?*anyopaque, CaptionButton) callconv(.c) void = null,
    on_drag_start: ?*const fn (?*anyopaque) callconv(.c) void = null,
    on_drag_double_click: ?*const fn (?*anyopaque) callconv(.c) void = null,
};

pub const TabBar = opaque {};

pub extern "ghostty_tabbar" fn ghostty_tabbar_create(
    parent_hwnd: ?*anyopaque,
    callbacks: Callbacks,
) callconv(.c) ?*TabBar;

pub extern "ghostty_tabbar" fn ghostty_tabbar_destroy(bar: *TabBar) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_height(bar: *TabBar) callconv(.c) i32;

pub extern "ghostty_tabbar" fn ghostty_tabbar_resize(
    bar: *TabBar,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_pretranslate(
    bar: *TabBar,
    msg: *anyopaque,
) callconv(.c) i32;

pub extern "ghostty_tabbar" fn ghostty_tabbar_add_tab(
    bar: *TabBar,
    title: [*:0]const u16,
) callconv(.c) TabId;

pub extern "ghostty_tabbar" fn ghostty_tabbar_remove_tab(
    bar: *TabBar,
    tab: TabId,
) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_set_title(
    bar: *TabBar,
    tab: TabId,
    title: [*:0]const u16,
) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_set_selected(
    bar: *TabBar,
    tab: TabId,
) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_add_profile(
    bar: *TabBar,
    profile: ProfileId,
    name: [*:0]const u16,
) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_clear_profiles(bar: *TabBar) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_set_theme(
    bar: *TabBar,
    r: u8,
    g: u8,
    b: u8,
    dark: i32,
) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_set_maximized(
    bar: *TabBar,
    maximized: i32,
) callconv(.c) void;

/// One entry in the new-tab dropdown: a shell we found on this machine.
pub const Profile = struct {
    id: ProfileId,
    /// Shown in the dropdown.
    name: []const u8,
    /// argv[0] for the shell. Empty means "whatever the config says",
    /// which is what the plain "+" button uses.
    command: []const u8,
};

// Shell discovery uses Win32 directly rather than std: SearchPathW is
// exactly the "resolve this against the standard search path" operation
// we want, and this file is Windows-only regardless.
extern "kernel32" fn SearchPathW(
    lpPath: ?[*:0]const u16,
    lpFileName: [*:0]const u16,
    lpExtension: ?[*:0]const u16,
    nBufferLength: u32,
    lpBuffer: ?[*]u16,
    lpFilePart: ?*?[*:0]u16,
) callconv(.winapi) u32;

extern "kernel32" fn GetFileAttributesW(
    lpFileName: [*:0]const u16,
) callconv(.winapi) u32;

const invalid_file_attributes: u32 = 0xFFFF_FFFF;

/// Looks for the shells worth offering in the dropdown. Only shells that
/// actually exist are returned, so the menu never offers something that
/// would fail to launch.
///
/// Caller owns the returned slice and the strings within it.
pub fn detectProfiles(alloc: std.mem.Allocator) ![]Profile {
    var list: std.ArrayListUnmanaged(Profile) = .empty;
    errdefer {
        for (list.items) |p| {
            alloc.free(p.name);
            alloc.free(p.command);
        }
        list.deinit(alloc);
    }

    const Candidate = struct {
        name: []const u8,
        command: []const u8,
        /// Absolute paths are checked directly; bare names go through
        /// SearchPathW. pwsh in particular lands in different places
        /// depending on whether it came from the MSI, the Store or winget.
        absolute: bool = false,
    };

    const candidates = [_]Candidate{
        .{ .name = "Command Prompt", .command = "cmd.exe" },
        .{ .name = "Windows PowerShell", .command = "powershell.exe" },
        .{ .name = "PowerShell 7", .command = "pwsh.exe" },
        .{
            .name = "Git Bash",
            .command = "C:\\Program Files\\Git\\bin\\bash.exe",
            .absolute = true,
        },
    };

    var next_id: ProfileId = 1;
    for (candidates) |c| {
        if (!exists(c.command, c.absolute)) continue;
        try list.append(alloc, .{
            .id = next_id,
            .name = try alloc.dupe(u8, c.name),
            .command = try alloc.dupe(u8, c.command),
        });
        next_id += 1;
    }

    return list.toOwnedSlice(alloc);
}

fn exists(path: []const u8, absolute: bool) bool {
    var buf: [512:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0..511], path) catch return false;
    buf[n] = 0;
    const name = buf[0..n :0];

    if (absolute) {
        return GetFileAttributesW(name) != invalid_file_attributes;
    }
    return SearchPathW(null, name, null, 0, null, null) != 0;
}

pub fn freeProfiles(alloc: std.mem.Allocator, profiles: []Profile) void {
    for (profiles) |p| {
        alloc.free(p.name);
        alloc.free(p.command);
    }
    alloc.free(profiles);
}
