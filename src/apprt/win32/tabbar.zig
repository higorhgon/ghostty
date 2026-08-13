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

const log = std.log.scoped(.win32_tabbar);

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

/// `icon_path` is any file whose shell icon should represent the tab, on
/// the same terms as `ghostty_tabbar_add_profile`. Null clears the icon.
pub extern "ghostty_tabbar" fn ghostty_tabbar_set_tab_icon(
    bar: *TabBar,
    tab: TabId,
    icon_path: ?[*:0]const u16,
) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_set_selected(
    bar: *TabBar,
    tab: TabId,
) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_add_profile(
    bar: *TabBar,
    profile: ProfileId,
    name: [*:0]const u16,
    icon_path: ?[*:0]const u16,
) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_clear_profiles(bar: *TabBar) callconv(.c) void;

/// Non-zero once the strip has composed its first frame. XAML does not
/// compose while the host window is hidden, so the window must be visible
/// -- if only off-screen -- for this to ever become true.
pub extern "ghostty_tabbar" fn ghostty_tabbar_rendered(bar: *TabBar) callconv(.c) i32;

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
    /// The command to run, index zero being the executable. Empty means
    /// "whatever the config says", which is what the plain "+" uses.
    argv: []const []const u8,
    /// A file whose shell icon represents this entry in the menu. Usually
    /// the shell's executable; for a WSL distribution it is the Start Menu
    /// shortcut, which is the only thing on disk carrying the distro logo.
    /// Empty for no icon.
    icon: []const u8 = "",
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
/// Caller owns the returned slice and everything reachable from it.
pub fn detectProfiles(alloc: std.mem.Allocator) ![]Profile {
    var list: std.ArrayListUnmanaged(Profile) = .empty;
    errdefer {
        for (list.items) |p| freeProfile(alloc, p);
        list.deinit(alloc);
    }

    const Candidate = struct {
        name: []const u8,
        argv: []const []const u8,
        /// Absolute paths are checked directly; bare names go through
        /// SearchPathW. pwsh in particular lands in different places
        /// depending on whether it came from the MSI, the Store or winget.
        absolute: bool = false,
    };

    const candidates = [_]Candidate{
        .{ .name = "Command Prompt", .argv = &.{"cmd.exe"} },
        .{ .name = "Windows PowerShell", .argv = &.{"powershell.exe"} },
        .{ .name = "PowerShell 7", .argv = &.{"pwsh.exe"} },
        .{ .name = "Nushell", .argv = &.{"nu.exe"} },
        .{
            .name = "Git Bash",
            // --login -i is what makes this an interactive login shell, so
            // the user's .bash_profile runs. Without it the prompt is bare
            // "bash-5.2$" and none of their setup is loaded.
            .argv = &.{ "C:\\Program Files\\Git\\bin\\bash.exe", "--login", "-i" },
            .absolute = true,
        },
    };

    var next_id: ProfileId = 1;
    for (candidates) |c| {
        if (!exists(c.argv[0], c.absolute)) continue;
        // SHGetFileInfo wants a real path; a bare "cmd.exe" yields the
        // generic unknown-file icon.
        var icon_buf: [512]u8 = undefined;
        const icon = if (c.absolute)
            c.argv[0]
        else
            (resolvePath(c.argv[0], &icon_buf) orelse c.argv[0]);
        try list.append(alloc, try makeProfile(alloc, next_id, c.name, c.argv, icon));
        next_id += 1;
    }

    // WSL distributions come last: they're the long tail, and grouping
    // them below the Windows shells matches how Windows Terminal orders
    // its generated profiles.
    appendWslProfiles(alloc, &list, &next_id) catch |err| {
        // A machine without WSL is the normal case, not an error worth
        // losing the rest of the menu over.
        log.debug("WSL enumeration failed err={}", .{err});
    };

    return list.toOwnedSlice(alloc);
}

fn makeProfile(
    alloc: std.mem.Allocator,
    id: ProfileId,
    name: []const u8,
    argv: []const []const u8,
    icon: []const u8,
) !Profile {
    const owned_argv = try alloc.alloc([]const u8, argv.len);
    var filled: usize = 0;
    errdefer {
        for (owned_argv[0..filled]) |a| alloc.free(a);
        alloc.free(owned_argv);
    }
    for (argv, owned_argv) |src, *dst| {
        dst.* = try alloc.dupe(u8, src);
        filled += 1;
    }

    return .{
        .id = id,
        .name = try alloc.dupe(u8, name),
        .argv = owned_argv,
        .icon = try alloc.dupe(u8, icon),
    };
}

/// Resolves a bare executable name to its full path via the standard
/// search path, writing UTF-8 into `buf`. Null if it isn't found or
/// doesn't fit.
fn resolvePath(name: []const u8, buf: []u8) ?[]const u8 {
    var wname: [512:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wname[0..511], name) catch return null;
    wname[n] = 0;

    var out: [512:0]u16 = undefined;
    const len = SearchPathW(null, wname[0..n :0], null, out.len, &out, null);
    if (len == 0 or len >= out.len) return null;

    const written = std.unicode.utf16LeToUtf8(buf, out[0..len]) catch return null;
    return buf[0..written];
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

// WSL distributions are registered under HKCU. This is the same source
// Windows Terminal reads, and it is deliberately preferred over shelling
// out to `wsl.exe --list`: that spawns a console process (a visible flash
// from a GUI app) and prints UTF-16 with a localized header.
const HKEY = ?*anyopaque;

extern "advapi32" fn RegOpenKeyExW(
    hKey: HKEY,
    lpSubKey: ?[*:0]const u16,
    ulOptions: u32,
    samDesired: u32,
    phkResult: *HKEY,
) callconv(.winapi) i32;

extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) i32;

extern "advapi32" fn RegEnumKeyExW(
    hKey: HKEY,
    dwIndex: u32,
    lpName: [*]u16,
    lpcchName: *u32,
    lpReserved: ?*u32,
    lpClass: ?[*]u16,
    lpcchClass: ?*u32,
    lpftLastWriteTime: ?*anyopaque,
) callconv(.winapi) i32;

extern "advapi32" fn RegGetValueW(
    hkey: HKEY,
    lpSubKey: ?[*:0]const u16,
    lpValue: ?[*:0]const u16,
    dwFlags: u32,
    pdwType: ?*u32,
    pvData: ?*anyopaque,
    pcbData: ?*u32,
) callconv(.winapi) i32;

const error_success: i32 = 0;
const key_read: u32 = 0x2_0019;
const rrf_rt_reg_sz: u32 = 0x0000_0002;
const rrf_rt_reg_dword: u32 = 0x0000_0018;

fn hkeyCurrentUser() HKEY {
    return @ptrFromInt(0x8000_0001);
}

const lxss_path = std.unicode.utf8ToUtf16LeStringLiteral(
    "Software\\Microsoft\\Windows\\CurrentVersion\\Lxss",
);

/// Adds one profile per installed WSL distribution.
fn appendWslProfiles(
    alloc: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Profile),
    next_id: *ProfileId,
) !void {
    // wsl.exe itself gates everything: the Lxss key can survive an
    // uninstall, and a profile we cannot launch is worse than none.
    if (!exists("wsl.exe", false)) return;

    var lxss: HKEY = null;
    if (RegOpenKeyExW(hkeyCurrentUser(), lxss_path, 0, key_read, &lxss) != error_success) {
        return error.NoWslRegistryKey;
    }
    defer _ = RegCloseKey(lxss);

    var index: u32 = 0;
    while (true) : (index += 1) {
        // Subkey names are GUIDs, so this is generously sized.
        var guid: [128:0]u16 = undefined;
        var guid_len: u32 = guid.len;
        if (RegEnumKeyExW(lxss, index, &guid, &guid_len, null, null, null, null) != error_success) {
            break;
        }
        guid[guid_len] = 0;

        // State 1 is "installed". Anything else is mid-install or
        // mid-uninstall and would fail to launch.
        var state: u32 = 0;
        var state_len: u32 = @sizeOf(u32);
        if (RegGetValueW(
            lxss,
            guid[0..guid_len :0],
            std.unicode.utf8ToUtf16LeStringLiteral("State"),
            rrf_rt_reg_dword,
            null,
            &state,
            &state_len,
        ) != error_success) continue;
        if (state != 1) continue;

        var name_buf: [256:0]u16 = undefined;
        var name_len: u32 = @sizeOf(@TypeOf(name_buf));
        if (RegGetValueW(
            lxss,
            guid[0..guid_len :0],
            std.unicode.utf8ToUtf16LeStringLiteral("DistributionName"),
            rrf_rt_reg_sz,
            null,
            &name_buf,
            &name_len,
        ) != error_success) continue;

        // name_len counts bytes and includes the terminator.
        if (name_len < 2 * @sizeOf(u16)) continue;
        const name_utf16 = name_buf[0 .. name_len / @sizeOf(u16) - 1];

        var utf8: [512]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&utf8, name_utf16) catch continue;
        const name = utf8[0..n];

        // Docker Desktop registers two hidden distros that exist to hold
        // its VM state. Neither has a usable shell.
        if (std.mem.startsWith(u8, name, "docker-desktop")) continue;

        // --cd ~ lands in the distro's home directory. Without it WSL
        // inherits our Windows working directory and drops the user in
        // /mnt/c/..., which is not where anyone wants to start.
        // The Start Menu shortcut is where the distro logo lives; the
        // registry has no icon of its own and wsl.exe would give every
        // distribution the same one.
        var icon_buf: [1024]u8 = undefined;
        const icon = shortcutPath(lxss, guid[0..guid_len :0], &icon_buf) orelse blk: {
            var exe_buf: [512]u8 = undefined;
            break :blk if (resolvePath("wsl.exe", &exe_buf)) |p|
                (std.fmt.bufPrint(&icon_buf, "{s}", .{p}) catch "")
            else
                "";
        };

        const argv = [_][]const u8{ "wsl.exe", "-d", name, "--cd", "~" };
        try list.append(alloc, try makeProfile(alloc, next_id.*, name, &argv, icon));
        next_id.* += 1;
    }
}

/// Reads a distribution's `ShortcutPath` -- the .lnk WSL drops in the
/// Start Menu, which is the only file on disk carrying the distro's own
/// logo. Null when the key is absent, which is the case for distros
/// installed before WSL started writing shortcuts.
fn shortcutPath(lxss: HKEY, guid: [:0]const u16, buf: []u8) ?[]const u8 {
    var wbuf: [512:0]u16 = undefined;
    var cb: u32 = @sizeOf(@TypeOf(wbuf));
    if (RegGetValueW(
        lxss,
        guid,
        std.unicode.utf8ToUtf16LeStringLiteral("ShortcutPath"),
        rrf_rt_reg_sz,
        null,
        &wbuf,
        &cb,
    ) != error_success) return null;
    if (cb < 2 * @sizeOf(u16)) return null;

    const utf16 = wbuf[0 .. cb / @sizeOf(u16) - 1];
    const n = std.unicode.utf16LeToUtf8(buf, utf16) catch return null;
    if (GetFileAttributesW(wbuf[0..utf16.len :0]) == invalid_file_attributes) {
        return null;
    }
    return buf[0..n];
}

fn freeProfile(alloc: std.mem.Allocator, p: Profile) void {
    for (p.argv) |a| alloc.free(a);
    alloc.free(p.argv);
    alloc.free(p.name);
    alloc.free(p.icon);
}

pub fn freeProfiles(alloc: std.mem.Allocator, profiles: []Profile) void {
    for (profiles) |p| freeProfile(alloc, p);
    alloc.free(profiles);
}
