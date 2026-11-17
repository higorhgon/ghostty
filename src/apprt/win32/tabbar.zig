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
    on_tab_moved: ?*const fn (?*anyopaque, TabId, i32) callconv(.c) void = null,
    on_overview: ?*const fn (?*anyopaque) callconv(.c) void = null,
    on_tab_context: ?*const fn (?*anyopaque, TabId) callconv(.c) void = null,
};

/// The dropdown's rows that are not shells. They arrive through
/// `on_new_tab` under these ids.
pub const menu_settings: ProfileId = 0xFFFF_FFF0;
pub const menu_palette: ProfileId = 0xFFFF_FFF1;
/// Or-ed into a shell's id when it was picked with Ctrl held.
pub const profile_elevated: ProfileId = 0x4000_0000;

/// Callbacks for the input popup: the search box, the command palette and
/// the rename prompt. See ghostty_tabbar.h.
pub const InputCallbacks = extern struct {
    ctx: ?*anyopaque = null,
    on_text: ?*const fn (?*anyopaque, [*:0]const u16) callconv(.c) void = null,
    on_submit: ?*const fn (?*anyopaque, i32, [*:0]const u16, i32) callconv(.c) void = null,
    on_cancel: ?*const fn (?*anyopaque) callconv(.c) void = null,
};

pub extern "ghostty_tabbar" fn ghostty_tabbar_input_show(
    bar: *TabBar,
    x: i32,
    y: i32,
    width: i32,
    placeholder: ?[*:0]const u16,
    text: ?[*:0]const u16,
    keep_open: i32,
    callbacks: InputCallbacks,
) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_input_set_items(
    bar: *TabBar,
    items: ?[*]const ?[*:0]const u16,
    count: i32,
) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_input_set_status(
    bar: *TabBar,
    text: ?[*:0]const u16,
) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_input_hide(bar: *TabBar) callconv(.c) void;

pub extern "ghostty_tabbar" fn ghostty_tabbar_input_visible(bar: *TabBar) callconv(.c) i32;

/// A context menu at a screen position, or at the pointer when both
/// coordinates are negative. A null label is a separator. Returns the id
/// picked, or 0. Blocks until the menu closes.
pub extern "ghostty_tabbar" fn ghostty_tabbar_popup_menu(
    bar: *TabBar,
    x: i32,
    y: i32,
    labels: [*]const ?[*:0]const u16,
    ids: [*]const u32,
    count: i32,
) callconv(.c) u32;

pub extern "ghostty_tabbar" fn ghostty_tabbar_notify(
    title: ?[*:0]const u16,
    body: ?[*:0]const u16,
) callconv(.c) void;

pub const Progress = enum(i32) {
    none = 0,
    normal = 1,
    @"error" = 2,
    indeterminate = 3,
    paused = 4,
};

pub extern "ghostty_tabbar" fn ghostty_tabbar_set_progress(
    hwnd: ?*anyopaque,
    state: Progress,
    percent: i32,
) callconv(.c) void;

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

/// Moves a tab to `index`, counting from zero. Does not fire
/// `on_tab_moved`, which is only for a drag by the user.
pub extern "ghostty_tabbar" fn ghostty_tabbar_move_tab(
    bar: *TabBar,
    tab: TabId,
    index: i32,
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
/// `custom` is the user's own entries, each `Name=command` as written in
/// `windows-profile`. They follow the detected shells.
///
/// Caller owns the returned slice and everything reachable from it.
pub fn detectProfiles(
    alloc: std.mem.Allocator,
    custom: []const [:0]const u8,
) ![]Profile {
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
        /// A file to take the icon from when the executable has none worth
        /// showing. Ignored if it does not exist.
        icon: ?[]const u8 = null,
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
            // bin\bash.exe is a bare launcher stub with no icon resource,
            // so the shell hands back the generic "program" icon for it.
            // The Git for Windows logo lives in git-bash.exe.
            .icon = "C:\\Program Files\\Git\\git-bash.exe",
        },
    };

    var next_id: ProfileId = 1;
    for (candidates) |c| {
        if (!exists(c.argv[0], c.absolute)) continue;
        // SHGetFileInfo wants a real path; a bare "cmd.exe" yields the
        // generic unknown-file icon.
        var icon_buf: [512]u8 = undefined;
        const icon = icon: {
            if (c.icon) |path| if (exists(path, true)) break :icon path;
            if (c.absolute) break :icon c.argv[0];
            break :icon resolvePath(c.argv[0], &icon_buf) orelse c.argv[0];
        };
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

    appendVsProfiles(alloc, &list, &next_id) catch |err| {
        log.debug("Visual Studio enumeration failed err={}", .{err});
    };

    for (custom) |entry| {
        appendCustomProfile(alloc, &list, &next_id, entry) catch |err| {
            log.warn("windows-profile={s} ignored err={}", .{ entry, err });
        };
    }

    return list.toOwnedSlice(alloc);
}

/// Adds one profile from a `windows-profile` entry.
fn appendCustomProfile(
    alloc: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Profile),
    next_id: *ProfileId,
    entry: []const u8,
) !void {
    const eq = std.mem.indexOfScalar(u8, entry, '=') orelse return error.NoCommand;
    const name = std.mem.trim(u8, entry[0..eq], " \t");
    const cmd = std.mem.trim(u8, entry[eq + 1 ..], " \t");
    if (name.len == 0 or cmd.len == 0) return error.Empty;

    // Split on spaces, with double quotes holding a word together. This is
    // deliberately not the full Windows command-line grammar: there is no
    // escaping of a quote, because a path cannot contain one.
    var argv_buf: [32][]const u8 = undefined;
    var argc: usize = 0;
    var i: usize = 0;
    while (i < cmd.len and argc < argv_buf.len) {
        while (i < cmd.len and cmd[i] == ' ') i += 1;
        if (i >= cmd.len) break;
        if (cmd[i] == '"') {
            const end = std.mem.indexOfScalarPos(u8, cmd, i + 1, '"') orelse cmd.len;
            argv_buf[argc] = cmd[i + 1 .. end];
            i = @min(cmd.len, end + 1);
        } else {
            const end = std.mem.indexOfScalarPos(u8, cmd, i, ' ') orelse cmd.len;
            argv_buf[argc] = cmd[i..end];
            i = end;
        }
        argc += 1;
    }
    if (argc == 0) return error.Empty;

    const exe = argv_buf[0];
    const absolute = std.mem.indexOfAny(u8, exe, "\\/") != null;
    if (!exists(exe, absolute)) return error.ProgramNotFound;

    var icon_buf: [512]u8 = undefined;
    const icon = if (absolute) exe else (resolvePath(exe, &icon_buf) orelse exe);
    try list.append(alloc, try makeProfile(alloc, next_id.*, name, argv_buf[0..argc], icon));
    next_id.* += 1;
}

const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: [2]u32,
    ftLastAccessTime: [2]u32,
    ftLastWriteTime: [2]u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

extern "kernel32" fn FindFirstFileW(
    lpFileName: [*:0]const u16,
    lpFindFileData: *WIN32_FIND_DATAW,
) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn FindNextFileW(
    hFindFile: ?*anyopaque,
    lpFindFileData: *WIN32_FIND_DATAW,
) callconv(.winapi) i32;
extern "kernel32" fn FindClose(hFindFile: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?*anyopaque,
) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn ReadFile(
    hFile: ?*anyopaque,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: u32,
    lpNumberOfBytesRead: *u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(
    hFile: ?*anyopaque,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: *u32,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) callconv(.winapi) i32;

fn invalidHandle(h: ?*anyopaque) bool {
    return h == null or @intFromPtr(h) == std.math.maxInt(usize);
}

/// Reads up to `buf.len` bytes from the start of a file. Null if it cannot
/// be opened.
pub fn readFileHead(path: []const u8, buf: []u8) ?[]u8 {
    var wpath: [1024:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wpath[0..1023], path) catch return null;
    wpath[n] = 0;

    // GENERIC_READ, shared for reading and writing, OPEN_EXISTING.
    const file = CreateFileW(wpath[0..n :0], 0x8000_0000, 3, null, 3, 0, null);
    if (invalidHandle(file)) return null;
    defer _ = CloseHandle(file);

    var total: usize = 0;
    while (total < buf.len) {
        var got: u32 = 0;
        const want: u32 = @intCast(@min(buf.len - total, 1 << 20));
        if (ReadFile(file, buf[total..].ptr, want, &got, null) == 0 or got == 0) break;
        total += got;
    }
    return buf[0..total];
}

/// Writes a whole file, replacing what was there. False on failure.
pub fn writeWholeFile(path: []const u8, data: []const u8) bool {
    var wpath: [1024:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wpath[0..1023], path) catch return false;
    wpath[n] = 0;

    // GENERIC_WRITE, no sharing, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL.
    const file = CreateFileW(wpath[0..n :0], 0x4000_0000, 0, null, 2, 0x80, null);
    if (invalidHandle(file)) return false;
    defer _ = CloseHandle(file);

    var written: u32 = 0;
    return WriteFile(file, data.ptr, @intCast(data.len), &written, null) != 0 and
        written == data.len;
}

/// The value of a string member named `key`, found by looking for the key
/// rather than by parsing the document: the files this reads are large and
/// only two short values are wanted from near the top. Undoes the two
/// escapes a Windows path can contain. Null if the key is not there or the
/// value does not fit.
fn jsonString(data: []const u8, comptime key: []const u8, out: []u8) ?[]const u8 {
    const needle = "\"" ++ key ++ "\"";
    const at = std.mem.indexOf(u8, data, needle) orelse return null;
    var i = at + needle.len;
    while (i < data.len and data[i] != ':') i += 1;
    while (i < data.len and data[i] != '"') i += 1;
    if (i >= data.len) return null;
    i += 1;

    var len: usize = 0;
    while (i < data.len and data[i] != '"') : (i += 1) {
        if (data[i] == '\\' and i + 1 < data.len) i += 1;
        if (len >= out.len) return null;
        out[len] = data[i];
        len += 1;
    }
    return out[0..len];
}

/// Adds the developer prompts of every installed Visual Studio.
///
/// Read from the installer's own record of each instance rather than by
/// running vswhere: that is a console program, and spawning one from a GUI
/// app flashes a console window on every start.
fn appendVsProfiles(
    alloc: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(Profile),
    next_id: *ProfileId,
) !void {
    const instances = "C:\\ProgramData\\Microsoft\\VisualStudio\\Packages\\_Instances";
    var find: WIN32_FIND_DATAW = undefined;
    const handle = FindFirstFileW(
        std.unicode.utf8ToUtf16LeStringLiteral(instances ++ "\\*"),
        &find,
    );
    if (invalidHandle(handle)) return error.NoVisualStudio;
    defer _ = FindClose(handle);

    const state = try alloc.alloc(u8, 256 * 1024);
    defer alloc.free(state);

    while (true) {
        const name_len = std.mem.indexOfScalar(u16, &find.cFileName, 0) orelse find.cFileName.len;
        var name_buf: [512]u8 = undefined;
        const name_n = std.unicode.utf16LeToUtf8(&name_buf, find.cFileName[0..name_len]) catch 0;
        const name = name_buf[0..name_n];

        // FILE_ATTRIBUTE_DIRECTORY.
        if (find.dwFileAttributes & 0x10 != 0 and name.len > 0 and name[0] != '.') add: {
            var path_buf: [1024]u8 = undefined;
            const state_path = std.fmt.bufPrint(
                &path_buf,
                "{s}\\{s}\\state.json",
                .{ instances, name },
            ) catch break :add;
            const data = readFileHead(state_path, state) orelse break :add;

            var install_buf: [512]u8 = undefined;
            const install = jsonString(data, "installationPath", &install_buf) orelse break :add;
            var version_buf: [32]u8 = undefined;
            const version = jsonString(data, "productLineVersion", &version_buf) orelse "";

            var cmd_buf: [1024]u8 = undefined;
            const dev_cmd = std.fmt.bufPrint(
                &cmd_buf,
                "{s}\\Common7\\Tools\\VsDevCmd.bat",
                .{install},
            ) catch break :add;
            if (exists(dev_cmd, true)) {
                var title_buf: [128]u8 = undefined;
                const title = std.fmt.bufPrint(
                    &title_buf,
                    "Developer Command Prompt for VS {s}",
                    .{version},
                ) catch break :add;
                var icon_buf: [512]u8 = undefined;
                const icon = resolvePath("cmd.exe", &icon_buf) orelse "cmd.exe";
                const argv = [_][]const u8{ "cmd.exe", "/k", dev_cmd };
                try list.append(alloc, try makeProfile(alloc, next_id.*, title, &argv, icon));
                next_id.* += 1;
            }

            var dll_buf: [1024]u8 = undefined;
            const dev_shell = std.fmt.bufPrint(
                &dll_buf,
                "{s}\\Common7\\Tools\\Microsoft.VisualStudio.DevShell.dll",
                .{install},
            ) catch break :add;
            if (exists(dev_shell, true) and exists("powershell.exe", false)) {
                var title_buf: [128]u8 = undefined;
                const title = std.fmt.bufPrint(
                    &title_buf,
                    "Developer PowerShell for VS {s}",
                    .{version},
                ) catch break :add;
                var script_buf: [2048]u8 = undefined;
                const script = std.fmt.bufPrint(
                    &script_buf,
                    "&{{Import-Module '{s}'; Enter-VsDevShell -VsInstallPath '{s}' -SkipAutomaticLocation}}",
                    .{ dev_shell, install },
                ) catch break :add;
                var icon_buf: [512]u8 = undefined;
                const icon = resolvePath("powershell.exe", &icon_buf) orelse "powershell.exe";
                const argv = [_][]const u8{ "powershell.exe", "-NoExit", "-Command", script };
                try list.append(alloc, try makeProfile(alloc, next_id.*, title, &argv, icon));
                next_id.* += 1;
            }
        }

        if (FindNextFileW(handle, &find) == 0) break;
    }
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
        // The distro's own logo, which wsl.exe would not give us: every
        // distribution would get the same penguin. WSL keeps it as
        // shortcut.ico in the distro's directory and points the Start Menu
        // shortcut at it. The .ico is preferred over the shortcut because
        // the shell draws a shortcut's icon with the link arrow on top.
        var icon_buf: [1024]u8 = undefined;
        const icon = distroIconPath(lxss, guid[0..guid_len :0], &icon_buf) orelse
            shortcutPath(lxss, guid[0..guid_len :0], &icon_buf) orelse blk: {
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

/// The `shortcut.ico` WSL writes into a distribution's `BasePath`. Null
/// when either is missing, which is the case for distros registered by
/// older versions of WSL.
fn distroIconPath(lxss: HKEY, guid: [:0]const u16, buf: []u8) ?[]const u8 {
    var wbuf: [512:0]u16 = undefined;
    var cb: u32 = @sizeOf(@TypeOf(wbuf));
    if (RegGetValueW(
        lxss,
        guid,
        std.unicode.utf8ToUtf16LeStringLiteral("BasePath"),
        rrf_rt_reg_sz,
        null,
        &wbuf,
        &cb,
    ) != error_success) return null;
    if (cb < 2 * @sizeOf(u16)) return null;

    var base_buf: [1024]u8 = undefined;
    const base_len = std.unicode.utf16LeToUtf8(
        &base_buf,
        wbuf[0 .. cb / @sizeOf(u16) - 1],
    ) catch return null;
    // Some versions record the path with the \\?\ prefix, which the shell's
    // icon lookup does not accept.
    var base: []const u8 = base_buf[0..base_len];
    if (std.mem.startsWith(u8, base, "\\\\?\\")) base = base[4..];

    const path = std.fmt.bufPrint(buf, "{s}\\shortcut.ico", .{base}) catch return null;
    if (!exists(path, true)) return null;
    return path;
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
