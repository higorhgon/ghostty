//! Ghostty as Windows' default terminal.
//!
//! When a console program starts with no console of its own (from Explorer,
//! the Run dialog, a shortcut), Windows' console host can hand the session
//! to another terminal instead of opening a console window: it reads two
//! class IDs from `HKCU\Console\%%Startup` -- `DelegationConsole`, the
//! console host to hand over to, and `DelegationTerminal`, the terminal --
//! and the console host calls the terminal through COM, on
//! `ITerminalHandoff3::EstablishPtyHandoff`, with the session's handles.
//!
//! Ghostty is that terminal. COM starts ghostty.exe with `-Embedding`; the
//! apprt then registers the class below instead of opening a window, takes
//! the call, gives the console host the pipes to talk through, and opens a
//! window attached to the session (`termio.Exec.WindowsHandoff`). The console
//! host is Windows Terminal's OpenConsole, which is what
//! `DelegationConsole` names: Ghostty has no `IConsoleHandoff` server of its
//! own, and the proxy that carries both interfaces across processes is the
//! one Windows Terminal registers (OpenConsoleProxy.dll). The interface is
//! defined in microsoft/terminal, src/host/proxy/ITerminalHandoff.idl.
//!
//! The class is registered for COM by the installer (ghostty.iss, under
//! HKCU) or the MSIX manifest; choosing Ghostty is setting
//! `DelegationTerminal` to `clsid` (and `DelegationConsole` to Windows
//! Terminal's OpenConsole), which Settings > System > For developers does
//! for the packaged build and `+default-terminal` style tools for the other.
const std = @import("std");
const builtin = @import("builtin");
const termio = @import("../../termio.zig");
const Pty = @import("../../pty.zig").Pty;

const log = std.log.scoped(.win32_handoff);

pub const HANDLE = std.os.windows.HANDLE;
const BOOL = i32;
const HRESULT = i32;
const DWORD = u32;

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,

    fn eql(a: *const GUID, b: *const GUID) bool {
        return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
    }
};

/// Ghostty's terminal handoff class: `DelegationTerminal`, and the
/// CLSID the installer registers ghostty.exe under.
/// {5BFD48CD-0D7C-4D2C-96BB-2CC643119AB7}
pub const clsid: GUID = .{
    .data1 = 0x5BFD48CD,
    .data2 = 0x0D7C,
    .data3 = 0x4D2C,
    .data4 = .{ 0x96, 0xBB, 0x2C, 0xC6, 0x43, 0x11, 0x9A, 0xB7 },
};

const iid_iunknown: GUID = .{
    .data1 = 0x00000000,
    .data2 = 0x0000,
    .data3 = 0x0000,
    .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};
const iid_iclassfactory: GUID = .{
    .data1 = 0x00000001,
    .data2 = 0x0000,
    .data3 = 0x0000,
    .data4 = .{ 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46 },
};
/// ITerminalHandoff3 {6F23DA90-15C5-4203-9DB0-64E73F1B1B00}
const iid_terminal_handoff3: GUID = .{
    .data1 = 0x6F23DA90,
    .data2 = 0x15C5,
    .data3 = 0x4203,
    .data4 = .{ 0x9D, 0xB0, 0x64, 0xE7, 0x3F, 0x1B, 0x1B, 0x00 },
};

fn hr(comptime v: u32) HRESULT {
    return @bitCast(v);
}
const S_OK: HRESULT = 0;
const E_NOINTERFACE = hr(0x80004002);
const E_POINTER = hr(0x80004003);
const E_FAIL = hr(0x80004005);
const E_UNEXPECTED = hr(0x8000FFFF);
const CLASS_E_NOAGGREGATION = hr(0x80040110);

const ole32 = struct {
    extern "ole32" fn CoInitializeEx(?*anyopaque, DWORD) callconv(.winapi) HRESULT;
    extern "ole32" fn CoRegisterClassObject(
        *const GUID,
        *anyopaque,
        DWORD,
        DWORD,
        *DWORD,
    ) callconv(.winapi) HRESULT;
};

const k32 = struct {
    extern "kernel32" fn GetCommandLineW() callconv(.winapi) [*:0]const u16;
    extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
    extern "kernel32" fn DuplicateHandle(
        HANDLE,
        HANDLE,
        HANDLE,
        *HANDLE,
        DWORD,
        BOOL,
        DWORD,
    ) callconv(.winapi) BOOL;
    extern "kernel32" fn CloseHandle(HANDLE) callconv(.winapi) BOOL;
    extern "kernel32" fn GetProcessId(HANDLE) callconv(.winapi) DWORD;
    extern "kernel32" fn OpenProcess(DWORD, BOOL, DWORD) callconv(.winapi) ?HANDLE;
};

/// TERMINAL_STARTUP_INFO, as the console host fills it in from the
/// program's STARTUPINFO. Nothing in it is used yet.
const StartupInfo = extern struct {
    title: ?[*:0]u16,
    icon_path: ?[*:0]u16,
    icon_index: i32,
    x: DWORD,
    y: DWORD,
    x_size: DWORD,
    y_size: DWORD,
    x_count_chars: DWORD,
    y_count_chars: DWORD,
    fill_attribute: DWORD,
    flags: DWORD,
    show_window: u16,
};

/// Whether COM started this process to serve the handoff class: it adds
/// `-Embedding` to the command line it registered.
pub fn isEmbedding() bool {
    const line = std.mem.span(k32.GetCommandLineW());
    const needle = std.unicode.utf8ToUtf16LeStringLiteral("embedding");
    if (line.len < needle.len + 1) return false;
    var i: usize = 0;
    while (i + needle.len < line.len) : (i += 1) {
        if (line[i] != '-' and line[i] != '/') continue;
        const word = line[i + 1 ..][0..needle.len];
        var same = true;
        for (word, needle) |a, b| {
            const lower = if (a >= 'A' and a <= 'Z') a + 32 else a;
            if (lower != b) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}

/// Called on the apprt's thread, inside the COM call, with a session ready
/// to attach to. It owns the handoff from then on; it must not open the
/// window before the call returns (the console host is still waiting on
/// it), only arrange for it.
pub const Callback = *const fn (ctx: *anyopaque, handoff: termio.Exec.WindowsHandoff) void;

var callback: ?Callback = null;
var callback_ctx: *anyopaque = undefined;

/// Registers the handoff class with COM for this process, on the calling
/// thread, which must be the one with the message loop: COM delivers the
/// call through it (a single-threaded apartment, which the XAML tab strip
/// needs on that thread anyway). Single use: a second handoff while this
/// process is up starts another Ghostty, as every new Ghostty window is
/// its own process.
pub fn register(ctx: *anyopaque, cb: Callback) !void {
    callback = cb;
    callback_ctx = ctx;

    const COINIT_APARTMENTTHREADED = 0x2;
    const init_hr = ole32.CoInitializeEx(null, COINIT_APARTMENTTHREADED);
    // S_FALSE: already initialized as an STA, which is fine.
    if (init_hr < 0) {
        log.err("CoInitializeEx failed hr=0x{x}", .{@as(u32, @bitCast(init_hr))});
        return error.Unexpected;
    }

    const CLSCTX_LOCAL_SERVER = 0x4;
    const REGCLS_SINGLEUSE = 0;
    var cookie: DWORD = 0;
    const reg_hr = ole32.CoRegisterClassObject(
        &clsid,
        @ptrCast(@constCast(&factory)),
        CLSCTX_LOCAL_SERVER,
        REGCLS_SINGLEUSE,
        &cookie,
    );
    if (reg_hr < 0) {
        log.err("CoRegisterClassObject failed hr=0x{x}", .{@as(u32, @bitCast(reg_hr))});
        return error.Unexpected;
    }
    log.info("registered as the terminal handoff server", .{});
}

// -------------------------------------------------------------------- COM objects
//
// Both are static, so reference counting has nothing to free: the counts
// only have to be plausible.

const IUnknownVtbl = extern struct {
    QueryInterface: *const fn (*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    AddRef: *const fn (*anyopaque) callconv(.winapi) u32,
    Release: *const fn (*anyopaque) callconv(.winapi) u32,
};

const ClassFactoryVtbl = extern struct {
    base: IUnknownVtbl,
    CreateInstance: *const fn (*anyopaque, ?*anyopaque, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
    LockServer: *const fn (*anyopaque, BOOL) callconv(.winapi) HRESULT,
};

const HandoffVtbl = extern struct {
    base: IUnknownVtbl,
    EstablishPtyHandoff: *const fn (
        *anyopaque,
        ?*HANDLE,
        ?*HANDLE,
        HANDLE,
        HANDLE,
        HANDLE,
        HANDLE,
        ?*const StartupInfo,
    ) callconv(.winapi) HRESULT,
};

const Object = extern struct { vtbl: *const anyopaque };

fn addRef(_: *anyopaque) callconv(.winapi) u32 {
    return 2;
}
fn release(_: *anyopaque) callconv(.winapi) u32 {
    return 1;
}

const factory_vtbl: ClassFactoryVtbl = .{
    .base = .{ .QueryInterface = factoryQueryInterface, .AddRef = addRef, .Release = release },
    .CreateInstance = factoryCreateInstance,
    .LockServer = factoryLockServer,
};
const factory: Object = .{ .vtbl = &factory_vtbl };

fn factoryQueryInterface(self: *anyopaque, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
    if (riid.eql(&iid_iunknown) or riid.eql(&iid_iclassfactory)) {
        ppv.* = self;
        return S_OK;
    }
    ppv.* = null;
    return E_NOINTERFACE;
}

fn factoryCreateInstance(_: *anyopaque, outer: ?*anyopaque, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
    ppv.* = null;
    if (outer != null) return CLASS_E_NOAGGREGATION;
    return handoffQueryInterface(@ptrCast(@constCast(&handoff_object)), riid, ppv);
}

fn factoryLockServer(_: *anyopaque, _: BOOL) callconv(.winapi) HRESULT {
    return S_OK;
}

const handoff_vtbl: HandoffVtbl = .{
    .base = .{ .QueryInterface = handoffQueryInterface, .AddRef = addRef, .Release = release },
    .EstablishPtyHandoff = establishPtyHandoff,
};
const handoff_object: Object = .{ .vtbl = &handoff_vtbl };

fn handoffQueryInterface(self: *anyopaque, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT {
    if (riid.eql(&iid_iunknown) or riid.eql(&iid_terminal_handoff3)) {
        ppv.* = self;
        return S_OK;
    }
    ppv.* = null;
    return E_NOINTERFACE;
}

/// The handles passed in belong to COM and are closed when the call
/// returns, so the ones kept are duplicates. The two returned are the
/// console host's ends of the pipes, which COM carries across and closes
/// here; Ghostty keeps the other ends (`Pty.adopt`).
fn establishPtyHandoff(
    _: *anyopaque,
    in: ?*HANDLE,
    out: ?*HANDLE,
    signal: HANDLE,
    reference: HANDLE,
    server: HANDLE,
    client: HANDLE,
    startup_info: ?*const StartupInfo,
) callconv(.winapi) HRESULT {
    _ = startup_info;
    const in_ptr = in orelse return E_POINTER;
    const out_ptr = out orelse return E_POINTER;
    const cb = callback orelse return E_UNEXPECTED;

    const own_signal = duplicate(signal) orelse return E_FAIL;
    const own_reference = duplicate(reference) orelse {
        _ = k32.CloseHandle(own_signal);
        return E_FAIL;
    };
    const own_server = duplicate(server) orelse {
        _ = k32.CloseHandle(own_signal);
        _ = k32.CloseHandle(own_reference);
        return E_FAIL;
    };
    const own_client = openClient(client) orelse {
        _ = k32.CloseHandle(own_signal);
        _ = k32.CloseHandle(own_reference);
        _ = k32.CloseHandle(own_server);
        return E_FAIL;
    };

    // The pseudoconsole takes the server, reference and signal handles.
    const adopted = Pty.adopt(own_server, own_reference, own_signal) catch {
        _ = k32.CloseHandle(own_signal);
        _ = k32.CloseHandle(own_reference);
        _ = k32.CloseHandle(own_server);
        _ = k32.CloseHandle(own_client);
        return E_FAIL;
    };

    in_ptr.* = adopted.host.input;
    out_ptr.* = adopted.host.output;
    cb(callback_ctx, .{ .pty = adopted.pty, .client = own_client });
    log.info("took a console handoff", .{});
    return S_OK;
}

/// The program's process, opened again by its id with the rights the exit
/// watcher needs: libxev puts the process in a job object to hear about
/// its exit, which takes PROCESS_SET_QUOTA and PROCESS_TERMINATE, and the
/// handle the console host passes has neither. Falls back to a duplicate,
/// which still lets the surface start (and fail to watch) rather than not.
fn openClient(h: HANDLE) ?HANDLE {
    const pid = k32.GetProcessId(h);
    if (pid != 0) {
        const SYNCHRONIZE = 0x00100000;
        const PROCESS_TERMINATE = 0x0001;
        const PROCESS_SET_QUOTA = 0x0100;
        const PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
        if (k32.OpenProcess(
            SYNCHRONIZE | PROCESS_TERMINATE | PROCESS_SET_QUOTA | PROCESS_QUERY_LIMITED_INFORMATION,
            0,
            pid,
        )) |p| return p;
        log.warn("could not open the handed-off program pid={}, using the console host's handle", .{pid});
    }
    return duplicate(h);
}

fn duplicate(h: HANDLE) ?HANDLE {
    const DUPLICATE_SAME_ACCESS = 0x2;
    const self = k32.GetCurrentProcess();
    var out: HANDLE = undefined;
    if (k32.DuplicateHandle(self, h, self, &out, 0, 0, DUPLICATE_SAME_ACCESS) == 0) {
        log.warn("DuplicateHandle failed", .{});
        return null;
    }
    return out;
}
