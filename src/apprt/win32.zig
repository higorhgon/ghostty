//! A minimal, hand-rolled native Win32/WGL apprt for Ghostty.
//!
//! This is an early skeleton: it opens real top-level Win32 windows, drives
//! a WGL (desktop OpenGL) context, supports multiple tabs per window (each
//! tab optionally split into two panes), and forwards keyboard/mouse/
//! clipboard events into the core Ghostty engine. It does NOT have feature
//! parity with the GTK (Linux) or macOS (Swift) apps -- splits are limited
//! to a single 2-pane split per tab (no recursive nesting, no drag-resize
//! of the divider), there's no settings UI, no command palette, no
//! high-DPI awareness, and keyboard handling only covers the common
//! ASCII/navigation cases. Its purpose is to be a real, buildable starting
//! point for a fuller native Windows app.
const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const apprt = @import("../apprt.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const CoreApp = @import("../App.zig");
const CoreSurface = @import("../Surface.zig");
const input = @import("../input.zig");
const global = @import("../global.zig");
const internal_os = @import("../os/main.zig");

const log = std.log.scoped(.win32);

pub const resourcesDir = internal_os.resourcesDir;

/// Height in pixels of the GDI-drawn tab strip at the top of each window.
const tab_bar_height: i32 = 32;
/// Fixed width in pixels of each tab in the strip. A fixed width keeps the
/// hit-testing/drawing code simple; it doesn't shrink to fit many tabs.
const tab_width: i32 = 180;
/// Width in pixels of the divider line drawn between two split panes.
const split_divider: i32 = 2;

/// Hand-rolled Win32 API bindings. Zig's std.os.windows only covers
/// kernel32/ntdll-style syscalls, not user32/gdi32/opengl32 GUI APIs, so
/// we declare the small subset we need ourselves (mirrors the approach
/// already used in src/os/windows.zig for the kernel32/ntdll side).
const w32 = struct {
    pub const HWND = *opaque {};
    pub const HDC = *opaque {};
    pub const HGLRC = *opaque {};
    pub const HINSTANCE = *opaque {};
    pub const HICON = *opaque {};
    pub const HCURSOR = *opaque {};
    pub const HBRUSH = *opaque {};
    pub const HMENU = *opaque {};
    pub const HANDLE = *opaque {};
    pub const HGDIOBJ = *opaque {};

    pub const ATOM = u16;
    pub const BOOL = i32;
    pub const DWORD = u32;
    pub const WORD = u16;
    pub const UINT = u32;
    pub const LONG = i32;
    pub const COLORREF = DWORD;
    pub const WPARAM = usize;
    pub const LPARAM = isize;
    pub const LRESULT = isize;

    pub const TRUE: BOOL = 1;
    pub const FALSE: BOOL = 0;

    pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

    pub const WNDCLASSEXW = extern struct {
        cbSize: UINT = @sizeOf(WNDCLASSEXW),
        style: UINT = 0,
        lpfnWndProc: WNDPROC,
        cbClsExtra: c_int = 0,
        cbWndExtra: c_int = 0,
        hInstance: HINSTANCE,
        hIcon: ?HICON = null,
        hCursor: ?HCURSOR = null,
        hbrBackground: ?HBRUSH = null,
        lpszMenuName: ?[*:0]const u16 = null,
        lpszClassName: [*:0]const u16,
        hIconSm: ?HICON = null,
    };

    pub const POINT = extern struct { x: i32, y: i32 };
    pub const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

    pub const MSG = extern struct {
        hwnd: ?HWND,
        message: UINT,
        wParam: WPARAM,
        lParam: LPARAM,
        time: DWORD,
        pt: POINT,
    };

    pub const CREATESTRUCTW = extern struct {
        lpCreateParams: ?*anyopaque,
        hInstance: ?HINSTANCE,
        hMenu: ?HMENU,
        hwndParent: ?HWND,
        cy: i32,
        cx: i32,
        y: i32,
        x: i32,
        style: LONG,
        lpszName: ?[*:0]const u16,
        lpszClass: ?[*:0]const u16,
        dwExStyle: DWORD,
    };

    pub const PAINTSTRUCT = extern struct {
        hdc: ?HDC,
        fErase: BOOL,
        rcPaint: RECT,
        fRestore: BOOL,
        fIncUpdate: BOOL,
        rgbReserved: [32]u8,
    };

    pub const PIXELFORMATDESCRIPTOR = extern struct {
        nSize: WORD = @sizeOf(PIXELFORMATDESCRIPTOR),
        nVersion: WORD = 1,
        dwFlags: DWORD = 0,
        iPixelType: u8 = 0,
        cColorBits: u8 = 0,
        cRedBits: u8 = 0,
        cRedShift: u8 = 0,
        cGreenBits: u8 = 0,
        cGreenShift: u8 = 0,
        cBlueBits: u8 = 0,
        cBlueShift: u8 = 0,
        cAlphaBits: u8 = 0,
        cAlphaShift: u8 = 0,
        cAccumBits: u8 = 0,
        cAccumRedBits: u8 = 0,
        cAccumGreenBits: u8 = 0,
        cAccumBlueBits: u8 = 0,
        cAccumAlphaBits: u8 = 0,
        cDepthBits: u8 = 0,
        cStencilBits: u8 = 0,
        cAuxBuffers: u8 = 0,
        iLayerType: u8 = 0,
        bReserved: u8 = 0,
        dwLayerMask: DWORD = 0,
        dwVisibleMask: DWORD = 0,
        dwDamageMask: DWORD = 0,
    };

    // Window styles / messages / constants we need.
    pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
    pub const WS_CHILD: DWORD = 0x40000000;
    pub const WS_VISIBLE: DWORD = 0x10000000;
    pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
    pub const SW_SHOW: c_int = 5;
    pub const SW_HIDE: c_int = 0;
    pub const CS_OWNDC: UINT = 0x0020;
    pub const CS_HREDRAW: UINT = 0x0002;
    pub const CS_VREDRAW: UINT = 0x0002;
    pub const GWLP_USERDATA: c_int = -21;
    pub const IDC_ARROW: [*:0]const u16 = @ptrFromInt(32512);

    pub const WM_CREATE: UINT = 0x0001;
    pub const WM_DESTROY: UINT = 0x0002;
    pub const WM_SIZE: UINT = 0x0005;
    pub const WM_SETFOCUS: UINT = 0x0007;
    pub const WM_KILLFOCUS: UINT = 0x0008;
    pub const WM_PAINT: UINT = 0x000F;
    pub const WM_CLOSE: UINT = 0x0010;
    pub const WM_QUIT: UINT = 0x0012;
    pub const WM_ERASEBKGND: UINT = 0x0014;
    pub const WM_KEYDOWN: UINT = 0x0100;
    pub const WM_KEYUP: UINT = 0x0101;
    pub const WM_CHAR: UINT = 0x0102;
    pub const WM_SYSKEYDOWN: UINT = 0x0104;
    pub const WM_SYSKEYUP: UINT = 0x0105;
    pub const WM_MOUSEMOVE: UINT = 0x0200;
    pub const WM_LBUTTONDOWN: UINT = 0x0201;
    pub const WM_LBUTTONUP: UINT = 0x0202;
    pub const WM_RBUTTONDOWN: UINT = 0x0204;
    pub const WM_RBUTTONUP: UINT = 0x0205;
    pub const WM_MBUTTONDOWN: UINT = 0x0207;
    pub const WM_MBUTTONUP: UINT = 0x0208;
    pub const WM_MOUSEWHEEL: UINT = 0x020A;
    pub const WM_NCCREATE: UINT = 0x0081;
    pub const WM_APP: UINT = 0x8000;

    pub const PFD_DRAW_TO_WINDOW: DWORD = 0x00000004;
    pub const PFD_SUPPORT_OPENGL: DWORD = 0x00000020;
    pub const PFD_DOUBLEBUFFER: DWORD = 0x00000001;
    pub const PFD_TYPE_RGBA: u8 = 0;
    pub const PFD_MAIN_PLANE: u8 = 0;

    pub const VK_BACK: u32 = 0x08;
    pub const VK_TAB: u32 = 0x09;
    pub const VK_RETURN: u32 = 0x0D;
    pub const VK_SHIFT: u32 = 0x10;
    pub const VK_CONTROL: u32 = 0x11;
    pub const VK_MENU: u32 = 0x12;
    pub const VK_ESCAPE: u32 = 0x1B;
    pub const VK_SPACE: u32 = 0x20;
    pub const VK_PRIOR: u32 = 0x21;
    pub const VK_NEXT: u32 = 0x22;
    pub const VK_END: u32 = 0x23;
    pub const VK_HOME: u32 = 0x24;
    pub const VK_LEFT: u32 = 0x25;
    pub const VK_UP: u32 = 0x26;
    pub const VK_RIGHT: u32 = 0x27;
    pub const VK_DOWN: u32 = 0x28;
    pub const VK_INSERT: u32 = 0x2D;
    pub const VK_DELETE: u32 = 0x2E;
    pub const VK_F1: u32 = 0x70;
    pub const VK_E: u32 = 0x45;
    pub const VK_O: u32 = 0x4F;
    pub const VK_T: u32 = 0x54;
    pub const VK_W: u32 = 0x57;

    pub const CF_UNICODETEXT: UINT = 13;
    pub const GMEM_MOVEABLE: UINT = 0x0002;

    pub const TRANSPARENT: c_int = 1;
    pub const DT_CENTER: UINT = 0x1;
    pub const DT_VCENTER: UINT = 0x4;
    pub const DT_SINGLELINE: UINT = 0x20;
    pub const DT_END_ELLIPSIS: UINT = 0x8000;

    pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
    pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) DWORD;
    pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) ?HANDLE;
    pub extern "kernel32" fn GlobalLock(hMem: HANDLE) callconv(.winapi) ?*anyopaque;
    pub extern "kernel32" fn GlobalUnlock(hMem: HANDLE) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetConsoleWindow() callconv(.winapi) ?HWND;

    // DWM (Desktop Window Manager) attributes, used to make the native
    // titlebar match the terminal's theme instead of clashing with it.
    // DWMWA_CAPTION_COLOR/DWMWA_TEXT_COLOR require Windows 11 (build
    // 22000+); DwmSetWindowAttribute simply fails (harmlessly, we ignore
    // the result) on older Windows for those, while
    // DWMWA_USE_IMMERSIVE_DARK_MODE alone still works back to Windows 10
    // 1809 and gets us a dark-vs-light-appropriate titlebar even there.
    pub const DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20;
    pub const DWMWA_BORDER_COLOR: DWORD = 34;
    pub const DWMWA_CAPTION_COLOR: DWORD = 35;
    pub const DWMWA_TEXT_COLOR: DWORD = 36;
    pub extern "dwmapi" fn DwmSetWindowAttribute(
        hwnd: HWND,
        dwAttribute: DWORD,
        pvAttribute: *const anyopaque,
        cbAttribute: DWORD,
    ) callconv(.winapi) i32;

    pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) ATOM;
    pub extern "user32" fn CreateWindowExW(
        dwExStyle: DWORD,
        lpClassName: [*:0]const u16,
        lpWindowName: [*:0]const u16,
        dwStyle: DWORD,
        X: i32,
        Y: i32,
        nWidth: i32,
        nHeight: i32,
        hWndParent: ?HWND,
        hMenu: ?HMENU,
        hInstance: HINSTANCE,
        lpParam: ?*anyopaque,
    ) callconv(.winapi) ?HWND;
    pub extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
    pub extern "user32" fn ShowWindow(HWND, c_int) callconv(.winapi) BOOL;
    pub extern "user32" fn UpdateWindow(HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn GetMessageW(*MSG, ?HWND, UINT, UINT) callconv(.winapi) BOOL;
    pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
    pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
    pub extern "user32" fn PostQuitMessage(c_int) callconv(.winapi) void;
    pub extern "user32" fn PostThreadMessageW(DWORD, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
    pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
    pub extern "user32" fn SetWindowLongPtrW(HWND, c_int, isize) callconv(.winapi) isize;
    pub extern "user32" fn GetWindowLongPtrW(HWND, c_int) callconv(.winapi) isize;
    pub extern "user32" fn LoadCursorW(?HINSTANCE, [*:0]const u16) callconv(.winapi) ?HCURSOR;
    pub extern "user32" fn GetDC(HWND) callconv(.winapi) ?HDC;
    pub extern "user32" fn ReleaseDC(HWND, HDC) callconv(.winapi) c_int;
    pub extern "user32" fn GetKeyState(c_int) callconv(.winapi) i16;
    pub extern "user32" fn SetWindowTextW(HWND, [*:0]const u16) callconv(.winapi) BOOL;
    pub extern "user32" fn OpenClipboard(?HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
    pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
    pub extern "user32" fn SetClipboardData(UINT, ?HANDLE) callconv(.winapi) ?HANDLE;
    pub extern "user32" fn GetClipboardData(UINT) callconv(.winapi) ?HANDLE;
    pub extern "user32" fn MoveWindow(HWND, i32, i32, i32, i32, BOOL) callconv(.winapi) BOOL;
    pub extern "user32" fn InvalidateRect(HWND, ?*const RECT, BOOL) callconv(.winapi) BOOL;
    pub extern "user32" fn BeginPaint(HWND, *PAINTSTRUCT) callconv(.winapi) ?HDC;
    pub extern "user32" fn EndPaint(HWND, *const PAINTSTRUCT) callconv(.winapi) BOOL;
    pub extern "user32" fn FillRect(HDC, *const RECT, HBRUSH) callconv(.winapi) c_int;
    pub extern "user32" fn DrawTextW(HDC, [*]const u16, c_int, *RECT, UINT) callconv(.winapi) c_int;
    pub extern "user32" fn SetFocus(?HWND) callconv(.winapi) ?HWND;

    pub extern "gdi32" fn ChoosePixelFormat(HDC, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
    pub extern "gdi32" fn SetPixelFormat(HDC, c_int, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
    pub extern "gdi32" fn SwapBuffers(HDC) callconv(.winapi) BOOL;
    pub extern "gdi32" fn CreateSolidBrush(COLORREF) callconv(.winapi) ?HBRUSH;
    pub extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.winapi) BOOL;
    pub extern "gdi32" fn SetBkMode(HDC, c_int) callconv(.winapi) c_int;
    pub extern "gdi32" fn SetTextColor(HDC, COLORREF) callconv(.winapi) DWORD;

    pub extern "opengl32" fn wglCreateContext(HDC) callconv(.winapi) ?HGLRC;
    pub extern "opengl32" fn wglMakeCurrent(?HDC, ?HGLRC) callconv(.winapi) BOOL;
    pub extern "opengl32" fn wglDeleteContext(HGLRC) callconv(.winapi) BOOL;
    pub extern "opengl32" fn glViewport(x: i32, y: i32, width: i32, height: i32) callconv(.winapi) void;
    pub extern "opengl32" fn glClearColor(r: f32, g: f32, b: f32, a: f32) callconv(.winapi) void;
    pub extern "opengl32" fn glClear(mask: u32) callconv(.winapi) void;
    pub extern "opengl32" fn glScissor(x: i32, y: i32, width: i32, height: i32) callconv(.winapi) void;
    pub extern "opengl32" fn glEnable(cap: u32) callconv(.winapi) void;
    pub extern "opengl32" fn glDisable(cap: u32) callconv(.winapi) void;
    pub extern "opengl32" fn glGetError() callconv(.winapi) u32;
    pub const GL_FRAMEBUFFER: u32 = 0x8D40;

    // glBindFramebuffer is OpenGL 3.0+ / ARB_framebuffer_object, which
    // Windows' opengl32.dll does NOT export directly (it only exports
    // 1.1-era functions); it must be resolved dynamically.
    pub extern "opengl32" fn wglGetProcAddress(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    var bind_framebuffer_fn: ?*const fn (u32, u32) callconv(.winapi) void = null;
    pub fn glBindFramebuffer(target: u32, framebuffer: u32) void {
        if (bind_framebuffer_fn == null) {
            bind_framebuffer_fn = @ptrCast(wglGetProcAddress("glBindFramebuffer"));
        }
        if (bind_framebuffer_fn) |f| f(target, framebuffer);
    }
    pub const GL_SCISSOR_TEST: u32 = 0x0C11;
    pub const GL_COLOR_BUFFER_BIT: u32 = 0x4000;

    pub inline fn LOWORD(l: anytype) u16 {
        return @truncate(@as(usize, @bitCast(@as(isize, @intCast(l)))) & 0xFFFF);
    }
    pub inline fn HIWORD(l: anytype) u16 {
        return @truncate((@as(usize, @bitCast(@as(isize, @intCast(l)))) >> 16) & 0xFFFF);
    }
    pub inline fn RGB(r: u8, g: u8, b: u8) COLORREF {
        return @as(COLORREF, r) | (@as(COLORREF, g) << 8) | (@as(COLORREF, b) << 16);
    }
};

const frame_class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyFrameClass");
const gl_class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyGLClass");

/// This is the main entrypoint to the apprt for Ghostty on Windows.
pub const App = @This();

/// See gtk apprt for the rationale: since our GL context stays current
/// on the main thread for the lifetime of the app (we never hand it off
/// to the renderer thread), all actual GL draw calls must also happen on
/// the main thread. The renderer thread just requests a redraw via the
/// app mailbox, which we service in our own message loop.
pub const must_draw_from_app_thread = true;

core_app: *CoreApp,
config: Config,
hinstance: w32.HINSTANCE,
main_thread_id: w32.DWORD,
quitting: bool = false,

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but we don't use it.
    opts: struct {},
) !void {
    _ = opts;

    // If we were launched with an attached console (always true for MSVC
    // builds today, since they use the console subsystem so the linker
    // doesn't require a WinMain entry point -- see GhosttyExe.zig), hide
    // it. This gives a native-looking GUI app experience without needing
    // to bridge Zig's std.start WinMain dispatch, which would require
    // touching the shared cross-platform entrypoint in main.zig.
    if (w32.GetConsoleWindow()) |console_hwnd| {
        _ = w32.ShowWindow(console_hwnd, w32.SW_HIDE);
    }

    const hinstance = w32.GetModuleHandleW(null) orelse return error.Unexpected;

    const frame_wc: w32.WNDCLASSEXW = .{
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
        .lpfnWndProc = &frameWndProc,
        .hInstance = hinstance,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .hbrBackground = w32.CreateSolidBrush(w32.RGB(0x2b, 0x2b, 0x2b)),
        .lpszClassName = frame_class_name,
    };
    if (w32.RegisterClassExW(&frame_wc) == 0) return error.Unexpected;

    const gl_wc: w32.WNDCLASSEXW = .{
        .style = w32.CS_HREDRAW | w32.CS_VREDRAW | w32.CS_OWNDC,
        .lpfnWndProc = &glWndProc,
        .hInstance = hinstance,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .lpszClassName = gl_class_name,
    };
    if (w32.RegisterClassExW(&gl_wc) == 0) return error.Unexpected;

    var config = try Config.load(core_app.alloc);
    errdefer config.deinit();

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .main_thread_id = w32.GetCurrentThreadId(),
    };
}

pub fn terminate(self: *App) void {
    self.config.deinit();
}

pub fn run(self: *App) !void {
    // Open our first window with one tab. Further windows/tabs can be
    // opened via the `new_window`/`new_tab` actions (keybindings).
    _ = self.newWindow() catch |err| {
        log.err("failed to create initial window err={}", .{err});
        return err;
    };

    var msg: w32.MSG = undefined;
    while (!self.quitting) {
        const ret = w32.GetMessageW(&msg, null, 0, 0);
        if (ret == 0 or ret == -1) break;
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);

        self.core_app.tick(self) catch |err| {
            log.warn("app tick failed err={}", .{err});
        };
    }
}

/// Called by CoreApp to wake up the event loop (e.g. when another thread
/// has pushed to the app mailbox and wants us to drain it).
pub fn wakeup(self: *App) void {
    _ = w32.PostThreadMessageW(self.main_thread_id, 0, 0, 0);
}

pub fn performAction(
    self: *App,
    target: apprt.Target,
    comptime action: apprt.Action.Key,
    value: apprt.Action.Value(action),
) !bool {
    switch (action) {
        .quit => {
            self.quitting = true;
            w32.PostQuitMessage(0);
            return true;
        },

        .new_window => {
            _ = try self.newWindow();
            return true;
        },

        .new_tab => {
            switch (target) {
                .app => _ = try self.newWindow(),
                .surface => |core| _ = try self.newTab(core.rt_surface.tab.window, .tab),
            }
            return true;
        },

        .new_split => {
            switch (target) {
                .app => {},
                .surface => |core| {
                    const dir: SplitDir = switch (value) {
                        .right, .left => .vertical,
                        .down, .up => .horizontal,
                    };
                    _ = self.newSplit(core.rt_surface, dir) catch |err| {
                        log.warn("failed to create split err={}", .{err});
                    };
                },
            }
            return true;
        },

        .close_tab => {
            switch (target) {
                .app => {},
                .surface => |core| closePane(core.rt_surface),
            }
            return true;
        },

        .close_window => {
            switch (target) {
                .app => {},
                .surface => |core| _ = w32.DestroyWindow(core.rt_surface.tab.window.hwnd),
            }
            return true;
        },

        .close_all_windows => {
            self.quitting = true;
            w32.PostQuitMessage(0);
            return true;
        },

        .quit_timer => return true,

        .render => {
            switch (target) {
                .app => {},
                .surface => |core| {
                    const surf: *Surface = core.rt_surface;
                    if (surf.tab.window.activeTabPtr() == surf.tab) {
                        reflow(surf.tab.window);
                    }
                },
            }
            return true;
        },

        .set_title => {
            switch (target) {
                .app => {},
                .surface => |core| {
                    const surf: *Surface = core.rt_surface;
                    const n = @min(value.title.len, surf.title_buf.len);
                    @memcpy(surf.title_buf[0..n], value.title[0..n]);
                    surf.title_len = n;

                    const window = surf.tab.window;
                    if (window.activeTabPtr() == surf.tab) reflow(window);
                    invalidateTabBar(window);
                },
            }
            return true;
        },

        else => return false,
    }
}

/// Send the given IPC to a running Ghostty. IPC (single-instance,
/// new-window-from-CLI, etc.) is not implemented for this skeleton.
pub fn performIpc(
    alloc: Allocator,
    target: apprt.ipc.Target,
    comptime action: apprt.ipc.Action.Key,
    value: apprt.ipc.Action.Value(action),
) !bool {
    _ = alloc;
    _ = target;
    _ = value;
    return false;
}

/// No inspector UI in this skeleton.
pub fn redrawInspector(_: *App, _: *Surface) void {}

pub const SplitDir = enum { horizontal, vertical };

/// A top-level window frame: the OS window, its child GL surface, its own
/// WGL context, and its list of tabs.
pub const Window = struct {
    app: *App,
    hwnd: w32.HWND,
    gl_hwnd: w32.HWND,
    hdc: w32.HDC,
    hglrc: w32.HGLRC,
    tabs: std.ArrayListUnmanaged(*Tab) = .empty,
    active: usize = 0,

    fn activeTabPtr(self: *Window) ?*Tab {
        if (self.active >= self.tabs.items.len) return null;
        return self.tabs.items[self.active];
    }

    fn focusedSurface(self: *Window) ?*Surface {
        const tab = self.activeTabPtr() orelse return null;
        return tab.focusedPane();
    }
};

/// One entry in a window's tab strip. Holds 1 or 2 panes (CoreSurfaces);
/// with 2 panes, `split` says whether they're arranged side-by-side
/// (vertical) or stacked (horizontal), matching Ghostty's naming (the
/// split direction is the direction of the dividing line's *normal*).
pub const Tab = struct {
    window: *Window,
    panes: std.ArrayListUnmanaged(*Surface) = .empty,
    split: ?SplitDir = null,
    focused: usize = 0,

    fn focusedPane(self: *Tab) ?*Surface {
        if (self.focused >= self.panes.items.len) return null;
        return self.panes.items[self.focused];
    }

    /// Pixel rect for the pane at `index`, given the tab's total content
    /// area. Only supports exactly 1 or 2 panes (MVP: no nested splits).
    fn paneRect(self: *Tab, index: usize, total: w32.RECT) w32.RECT {
        if (self.panes.items.len < 2 or self.split == null) return total;
        return switch (self.split.?) {
            .vertical => v: {
                const mid = @divTrunc(total.left + total.right, 2);
                break :v if (index == 0)
                    w32.RECT{ .left = total.left, .top = total.top, .right = mid - @divTrunc(split_divider, 2), .bottom = total.bottom }
                else
                    w32.RECT{ .left = mid + @divTrunc(split_divider, 2), .top = total.top, .right = total.right, .bottom = total.bottom };
            },
            .horizontal => h: {
                const mid = @divTrunc(total.top + total.bottom, 2);
                break :h if (index == 0)
                    w32.RECT{ .left = total.left, .top = total.top, .right = total.right, .bottom = mid - @divTrunc(split_divider, 2) }
                else
                    w32.RECT{ .left = total.left, .top = mid + @divTrunc(split_divider, 2), .right = total.right, .bottom = total.bottom };
            },
        };
    }

    fn paneAt(self: *Tab, x: i32, y: i32) ?usize {
        for (self.panes.items, 0..) |pane, i| {
            const r = pane.last_rect;
            if (x >= r.left and x < r.right and y >= r.top and y < r.bottom) return i;
        }
        return null;
    }
};

/// Makes the native titlebar match the terminal's configured theme instead
/// of clashing with it: picks light-vs-dark titlebar chrome/text based on
/// the background's perceived luminance (works since Windows 10 1809),
/// and on Windows 11 (build 22000+) also matches the exact caption
/// background/text colors to the theme's background/foreground. Both
/// DwmSetWindowAttribute calls are best-effort -- their result is ignored,
/// since unsupported attributes simply fail harmlessly on older Windows.
fn applyTitlebarTheme(hwnd: w32.HWND, config: *const Config) void {
    const bg = config.background;
    const fg = config.foreground;

    // Perceived (ITU-R BT.601) luminance of the background.
    const luminance = (@as(u32, bg.r) * 299 + @as(u32, bg.g) * 587 + @as(u32, bg.b) * 114) / 1000;
    const dark: i32 = if (luminance < 128) 1 else 0;
    _ = w32.DwmSetWindowAttribute(
        hwnd,
        w32.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &dark,
        @sizeOf(i32),
    );

    const caption_color = w32.RGB(bg.r, bg.g, bg.b);
    _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_CAPTION_COLOR, &caption_color, @sizeOf(w32.COLORREF));
    const text_color = w32.RGB(fg.r, fg.g, fg.b);
    _ = w32.DwmSetWindowAttribute(hwnd, w32.DWMWA_TEXT_COLOR, &text_color, @sizeOf(w32.COLORREF));
}

fn newWindow(self: *App) !*Window {
    const alloc = self.core_app.alloc;
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    window.* = .{
        .app = self,
        .hwnd = undefined,
        .gl_hwnd = undefined,
        .hdc = undefined,
        .hglrc = undefined,
    };

    const hwnd = w32.CreateWindowExW(
        0,
        frame_class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        w32.WS_OVERLAPPEDWINDOW,
        w32.CW_USEDEFAULT,
        w32.CW_USEDEFAULT,
        1000,
        700,
        null,
        null,
        self.hinstance,
        window,
    ) orelse return error.Unexpected;
    window.hwnd = hwnd;

    var client_rect: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &client_rect);

    const gl_hwnd = w32.CreateWindowExW(
        0,
        gl_class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        w32.WS_CHILD | w32.WS_VISIBLE,
        0,
        tab_bar_height,
        client_rect.right - client_rect.left,
        @max(0, (client_rect.bottom - client_rect.top) - tab_bar_height),
        hwnd,
        null,
        self.hinstance,
        window,
    ) orelse return error.Unexpected;
    window.gl_hwnd = gl_hwnd;

    const hdc = w32.GetDC(gl_hwnd) orelse return error.Unexpected;
    window.hdc = hdc;

    var pfd: w32.PIXELFORMATDESCRIPTOR = .{
        .dwFlags = w32.PFD_DRAW_TO_WINDOW | w32.PFD_SUPPORT_OPENGL | w32.PFD_DOUBLEBUFFER,
        .iPixelType = w32.PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cDepthBits = 24,
        .cStencilBits = 8,
        .iLayerType = w32.PFD_MAIN_PLANE,
    };
    const format = w32.ChoosePixelFormat(hdc, &pfd);
    if (format == 0) return error.Unexpected;
    if (w32.SetPixelFormat(hdc, format, &pfd) == w32.FALSE) return error.Unexpected;

    const hglrc = w32.wglCreateContext(hdc) orelse return error.Unexpected;
    window.hglrc = hglrc;
    if (w32.wglMakeCurrent(hdc, hglrc) == w32.FALSE) return error.Unexpected;

    _ = try self.newTab(window, .window);

    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(hwnd);
    _ = w32.SetFocus(gl_hwnd);
    applyTitlebarTheme(hwnd, &self.config);

    return window;
}

fn newPane(
    self: *App,
    window: *Window,
    tab: *Tab,
    context: apprt.surface.NewSurfaceContext,
) !*Surface {
    const alloc = self.core_app.alloc;
    const surf = try alloc.create(Surface);
    errdefer alloc.destroy(surf);
    surf.* = .{
        .tab = tab,
        .core_surface = undefined,
        .core_ready = false,
        .title_buf = undefined,
        .title_len = 0,
        .cursor_pos = .{ .x = 0, .y = 0 },
        .last_rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    };

    try self.core_app.addSurface(surf);
    errdefer self.core_app.deleteSurface(surf);

    var config = try apprt.surface.newConfig(self.core_app, &self.config, context);
    defer config.deinit();

    if (w32.wglMakeCurrent(window.hdc, window.hglrc) == w32.FALSE) return error.Unexpected;

    try CoreSurface.init(
        &surf.core_surface,
        alloc,
        &config,
        self.core_app,
        self,
        surf,
    );
    surf.core_ready = true;

    return surf;
}

fn newTab(
    self: *App,
    window: *Window,
    context: apprt.surface.NewSurfaceContext,
) !*Surface {
    const alloc = self.core_app.alloc;
    const tab = try alloc.create(Tab);
    errdefer alloc.destroy(tab);
    tab.* = .{ .window = window };

    const surf = try self.newPane(window, tab, context);
    errdefer {
        self.core_app.deleteSurface(surf);
        if (surf.core_ready) surf.core_surface.deinit();
        alloc.destroy(surf);
    }
    try tab.panes.append(alloc, surf);

    try window.tabs.append(alloc, tab);
    window.active = window.tabs.items.len - 1;
    reflow(window);
    invalidateTabBar(window);

    return surf;
}

/// Split the tab containing `pane` into two panes. MVP limitation: only a
/// single level of splitting is supported (no recursive nesting), so this
/// does nothing if the tab is already split.
fn newSplit(self: *App, pane: *Surface, dir: SplitDir) !*Surface {
    const tab = pane.tab;
    if (tab.panes.items.len >= 2) return error.AlreadySplit;
    const window = tab.window;
    const alloc = self.core_app.alloc;

    const new_pane = try self.newPane(window, tab, .split);
    errdefer {
        self.core_app.deleteSurface(new_pane);
        if (new_pane.core_ready) new_pane.core_surface.deinit();
        alloc.destroy(new_pane);
    }

    try tab.panes.append(alloc, new_pane);
    tab.split = dir;
    tab.focused = tab.panes.items.len - 1;

    reflow(window);
    return new_pane;
}

/// Close the given pane. If it's the last pane in its tab, the tab itself
/// is closed (and if that was the last tab, the window is destroyed).
fn closePane(surf: *Surface) void {
    const tab = surf.tab;
    const window = tab.window;
    const app = window.app;
    const alloc = app.core_app.alloc;

    var index: ?usize = null;
    for (tab.panes.items, 0..) |p, i| {
        if (p == surf) {
            index = i;
            break;
        }
    }
    const i = index orelse return;

    app.core_app.deleteSurface(surf);
    if (surf.core_ready) surf.core_surface.deinit();
    alloc.destroy(surf);
    _ = tab.panes.orderedRemove(i);

    if (tab.panes.items.len == 0) {
        closeTabStruct(tab);
        return;
    }

    // Collapse back to a single full-size pane (MVP: only ever 0-2 panes).
    tab.split = null;
    if (tab.focused >= tab.panes.items.len) tab.focused = tab.panes.items.len - 1;
    reflow(window);
    invalidateTabBar(window);
}

fn closeTabStruct(tab: *Tab) void {
    const window = tab.window;
    const app = window.app;
    const alloc = app.core_app.alloc;

    var index: ?usize = null;
    for (window.tabs.items, 0..) |t, i| {
        if (t == tab) {
            index = i;
            break;
        }
    }
    const i = index orelse return;
    alloc.destroy(tab);
    _ = window.tabs.orderedRemove(i);

    if (window.tabs.items.len == 0) {
        _ = w32.DestroyWindow(window.hwnd);
        return;
    }

    if (window.active >= window.tabs.items.len) window.active = window.tabs.items.len - 1;
    reflow(window);
    invalidateTabBar(window);
}

fn switchTab(window: *Window, index: usize) void {
    if (index >= window.tabs.items.len) return;
    if (window.active == index) return;
    window.active = index;
    reflow(window);
    invalidateTabBar(window);
}

fn nextTab(window: *Window, delta: isize) void {
    const count = window.tabs.items.len;
    if (count <= 1) return;
    const cur: isize = @intCast(window.active);
    var next = @mod(cur + delta, @as(isize, @intCast(count)));
    if (next < 0) next += @as(isize, @intCast(count));
    switchTab(window, @intCast(next));
}

/// Move keyboard/mouse focus to the other pane in the active tab's split.
fn toggleFocus(window: *Window) void {
    const tab = window.activeTabPtr() orelse return;
    if (tab.panes.items.len < 2) return;
    tab.focused = (tab.focused + 1) % tab.panes.items.len;
    reflow(window);
}

/// Sync the active tab's (focused pane's) title to the OS window title,
/// lay out and resize every pane of the active tab to its rect, and
/// redraw all of them into the shared GL framebuffer before presenting
/// with a single SwapBuffers. All panes are always redrawn together
/// (rather than just whichever pane's renderer asked for a redraw)
/// because they share one double-buffered framebuffer -- swapping after
/// only one pane's content is updated would show a torn/incomplete frame.
fn reflow(window: *Window) void {
    const tab = window.activeTabPtr() orelse return;
    _ = w32.SetFocus(window.gl_hwnd);

    if (tab.focusedPane()) |focused| {
        if (focused.title_len > 0) {
            var zbuf: [513:0]u16 = undefined;
            const wn = std.unicode.utf8ToUtf16Le(zbuf[0..512], focused.title_buf[0..focused.title_len]) catch 0;
            zbuf[wn] = 0;
            _ = w32.SetWindowTextW(window.hwnd, zbuf[0..wn :0]);
        }
    }

    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(window.gl_hwnd, &client_rect) == w32.FALSE) return;
    if (w32.wglMakeCurrent(window.hdc, window.hglrc) == w32.FALSE) return;

    const win_width = client_rect.right - client_rect.left;
    const win_height = client_rect.bottom - client_rect.top;
    if (win_width <= 0 or win_height <= 0) return;

    // Clear the whole window first so the gap between two split panes
    // (and any area not yet covered by a pane) isn't left with garbage
    // from a previous frame. Each pane's own drawFrame renders into (and
    // clears) its own offscreen target, not the default framebuffer
    // directly, so this clear only affects the parts *outside* of what
    // gets blitted below.
    w32.glBindFramebuffer(w32.GL_FRAMEBUFFER, 0);
    w32.glDisable(w32.GL_SCISSOR_TEST);
    w32.glViewport(0, 0, win_width, win_height);
    w32.glClearColor(0, 0, 0, 1);
    w32.glClear(w32.GL_COLOR_BUFFER_BIT);

    for (tab.panes.items, 0..) |pane, i| {
        const rect = tab.paneRect(i, client_rect);
        pane.last_rect = rect;
        if (!pane.core_ready) continue;

        const w: i32 = @max(0, rect.right - rect.left);
        const h: i32 = @max(0, rect.bottom - rect.top);
        if (w == 0 or h == 0) continue;

        pane.core_surface.sizeCallback(.{
            .width = @intCast(w),
            .height = @intCast(h),
        }) catch |err| log.warn("sizeCallback failed err={}", .{err});

        // NOTE: we deliberately do NOT set glViewport/glScissor here.
        // Each pane's drawFrame renders into its own appropriately-sized
        // offscreen target (a separate FBO in its own (0,0)-(w,h) local
        // coordinate space), so a window-space viewport/scissor would
        // only corrupt that -- e.g. a scissor rect offset for the right
        // pane has no overlap at all with the left pane's target's local
        // coordinates, silently clipping away everything it tries to
        // draw. The only place window position matters is *after*
        // rendering, when the OpenGL renderer's present() blits the
        // finished target onto the shared default framebuffer -- that's
        // what present_offset_{x,y} is for (glBlitFramebuffer's
        // destination rect is in absolute framebuffer pixels and ignores
        // glViewport entirely).
        const gl_y = win_height - rect.bottom;
        pane.core_surface.renderer.api.present_offset_x = rect.left;
        pane.core_surface.renderer.api.present_offset_y = gl_y;

        pane.core_surface.renderer.drawFrame(true) catch |err| {
            log.warn("drawFrame failed err={}", .{err});
        };
    }
    w32.glDisable(w32.GL_SCISSOR_TEST);

    _ = w32.SwapBuffers(window.hdc);
}

fn invalidateTabBar(window: *Window) void {
    const rect: w32.RECT = .{ .left = 0, .top = 0, .right = 100000, .bottom = tab_bar_height };
    _ = w32.InvalidateRect(window.hwnd, &rect, w32.TRUE);
}

/// Scales a single color channel by `factor` (e.g. 0.7 to darken, 1.0 to
/// leave unchanged), clamped to a valid byte.
fn scaleChannel(c: u8, factor: f32) u8 {
    const v = @as(f32, @floatFromInt(c)) * factor;
    return @intFromFloat(std.math.clamp(v, 0, 255));
}

fn paintTabBar(window: *Window, hdc: w32.HDC) void {
    const bg = window.app.config.background;
    const fg = window.app.config.foreground;

    // The active tab uses the theme's exact background color, so it
    // blends seamlessly into the terminal content right below it.
    // Inactive tabs (and the titlebar-adjacent strip background) use a
    // darkened variant so the active tab still stands out.
    const active_color = w32.RGB(bg.r, bg.g, bg.b);
    const inactive_color = w32.RGB(
        scaleChannel(bg.r, 0.6),
        scaleChannel(bg.g, 0.6),
        scaleChannel(bg.b, 0.6),
    );
    const active_text = w32.RGB(fg.r, fg.g, fg.b);
    const inactive_text = w32.RGB(
        scaleChannel(fg.r, 0.6),
        scaleChannel(fg.g, 0.6),
        scaleChannel(fg.b, 0.6),
    );

    const active_brush = w32.CreateSolidBrush(active_color);
    defer if (active_brush) |b| {
        _ = w32.DeleteObject(@ptrCast(b));
    };
    const inactive_brush = w32.CreateSolidBrush(inactive_color);
    defer if (inactive_brush) |b| {
        _ = w32.DeleteObject(@ptrCast(b));
    };

    // Clear the whole strip first. Without this, closing a tab (or
    // otherwise shrinking the tab count) leaves stale pixels behind from
    // whatever used to be drawn in that area, since the loop below only
    // repaints the rects for tabs that currently exist.
    var client_rect: w32.RECT = undefined;
    _ = w32.GetClientRect(window.hwnd, &client_rect);
    client_rect.bottom = tab_bar_height;
    if (inactive_brush) |b| _ = w32.FillRect(hdc, &client_rect, b);

    _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

    for (window.tabs.items, 0..) |tab, i| {
        const left: i32 = @as(i32, @intCast(i)) * tab_width;
        var rect: w32.RECT = .{ .left = left, .top = 0, .right = left + tab_width, .bottom = tab_bar_height };

        const is_active = i == window.active;
        if (w32.FillRect(hdc, &rect, (if (is_active) active_brush else inactive_brush) orelse continue) == 0) {}
        _ = w32.SetTextColor(hdc, if (is_active) active_text else inactive_text);

        const title_surf = tab.focusedPane();
        var title_w: [513]u16 = undefined;
        const title_len = if (title_surf) |s|
            (std.unicode.utf8ToUtf16Le(&title_w, s.title_buf[0..s.title_len]) catch 0)
        else
            0;
        var text_rect: w32.RECT = .{ .left = left + 10, .top = 0, .right = left + tab_width - 10, .bottom = tab_bar_height };
        if (title_len > 0) {
            _ = w32.DrawTextW(
                hdc,
                &title_w,
                @intCast(title_len),
                &text_rect,
                w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_END_ELLIPSIS,
            );
        } else {
            const fallback = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
            _ = w32.DrawTextW(
                hdc,
                fallback,
                @intCast(fallback.len),
                &text_rect,
                w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_END_ELLIPSIS,
            );
        }
    }
}

/// A single pane: owns a CoreSurface and belongs to exactly one Tab. This
/// is what `apprt.Surface` resolves to -- `CoreSurface.rt_surface` points
/// here.
pub const Surface = struct {
    tab: *Tab,
    core_surface: CoreSurface,
    core_ready: bool,
    /// UTF-8 title as last reported by the terminal (via the `set_title`
    /// action). Only the focused pane's title of the active tab is shown
    /// on the OS window titlebar / in the tab strip.
    title_buf: [512]u8,
    title_len: usize,
    cursor_pos: apprt.CursorPos,
    /// This pane's last-computed on-screen rect within the shared GL
    /// child window, in that window's client coordinates. Updated by
    /// `reflow`; used for input hit-testing/routing and `getSize`.
    last_rect: w32.RECT,

    pub fn deinit(self: *Surface) void {
        _ = self;
    }

    pub fn core(self: *Surface) *CoreSurface {
        return &self.core_surface;
    }

    pub fn rtApp(self: *Surface) *App {
        return self.tab.window.app;
    }

    pub fn close(self: *Surface, process_active: bool) void {
        _ = process_active;
        closePane(self);
    }

    pub fn getTitle(self: *Surface) ?[:0]const u8 {
        if (self.title_len == 0) return null;
        self.title_buf[self.title_len] = 0;
        return self.title_buf[0..self.title_len :0];
    }

    pub fn getContentScale(self: *const Surface) !apprt.ContentScale {
        _ = self;
        // TODO: query GetDpiForWindow for real high-DPI support.
        return .{ .x = 1, .y = 1 };
    }

    pub fn getSize(self: *const Surface) !apprt.SurfaceSize {
        return .{
            .width = @intCast(@max(0, self.last_rect.right - self.last_rect.left)),
            .height = @intCast(@max(0, self.last_rect.bottom - self.last_rect.top)),
        };
    }

    pub fn getCursorPos(self: *const Surface) !apprt.CursorPos {
        return self.cursor_pos;
    }

    pub fn supportsClipboard(
        self: *const Surface,
        clipboard_type: apprt.Clipboard,
    ) bool {
        _ = self;
        return clipboard_type == .standard;
    }

    pub fn clipboardRequest(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        state: apprt.ClipboardRequest,
    ) !bool {
        if (clipboard_type != .standard) return false;

        const alloc = self.tab.window.app.core_app.alloc;
        const text = readClipboardUtf8(alloc) catch |err| {
            log.warn("failed to read clipboard err={}", .{err});
            return false;
        } orelse return false;
        defer alloc.free(text);

        self.core_surface.completeClipboardRequest(state, text, false) catch |err| {
            log.warn("failed to complete clipboard request err={}", .{err});
        };
        return true;
    }

    pub fn setClipboard(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
        contents: []const apprt.ClipboardContent,
        confirm: bool,
    ) !void {
        _ = self;
        _ = confirm;
        if (clipboard_type != .standard) return;
        if (contents.len == 0) return;

        writeClipboardUtf8(contents[0].data) catch |err| {
            log.warn("failed to write clipboard err={}", .{err});
        };
    }

    pub fn defaultTermioEnv(self: *Surface) !std.process.Environ.Map {
        _ = self;
        return try global.environMap();
    }
};

fn readClipboardUtf8(alloc: Allocator) !?[:0]const u8 {
    if (w32.OpenClipboard(null) == w32.FALSE) return null;
    defer _ = w32.CloseClipboard();

    const handle = w32.GetClipboardData(w32.CF_UNICODETEXT) orelse return null;
    const ptr = w32.GlobalLock(handle) orelse return null;
    defer _ = w32.GlobalUnlock(handle);

    const wptr: [*:0]const u16 = @ptrCast(@alignCast(ptr));
    const wlen = std.mem.len(wptr);
    return try std.unicode.utf16LeToUtf8AllocZ(alloc, wptr[0..wlen]);
}

fn writeClipboardUtf8(text: []const u8) !void {
    var buf: [8192]u16 = undefined;
    const n = try std.unicode.utf8ToUtf16Le(&buf, text);

    const handle = w32.GlobalAlloc(w32.GMEM_MOVEABLE, (n + 1) * @sizeOf(u16)) orelse return error.Unexpected;
    const ptr = w32.GlobalLock(handle) orelse return error.Unexpected;
    const wptr: [*]u16 = @ptrCast(@alignCast(ptr));
    @memcpy(wptr[0..n], buf[0..n]);
    wptr[n] = 0;
    _ = w32.GlobalUnlock(handle);

    if (w32.OpenClipboard(null) == w32.FALSE) return error.Unexpected;
    defer _ = w32.CloseClipboard();
    _ = w32.EmptyClipboard();
    _ = w32.SetClipboardData(w32.CF_UNICODETEXT, handle);
}

fn getWindow(hwnd: w32.HWND) ?*Window {
    const ptr = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

fn currentMods() input.Mods {
    return .{
        .shift = w32.GetKeyState(@intCast(w32.VK_SHIFT)) < 0,
        .ctrl = w32.GetKeyState(@intCast(w32.VK_CONTROL)) < 0,
        .alt = w32.GetKeyState(@intCast(w32.VK_MENU)) < 0,
    };
}

/// Maps non-printable virtual key codes to Ghostty's layout-independent
/// Key enum. This intentionally excludes keys that already generate a
/// WM_CHAR (backspace/tab/enter/escape/space/letters/digits), which are
/// handled via handleChar instead to avoid double delivery.
fn vkToKey(vk: u32) ?input.Key {
    return switch (vk) {
        w32.VK_LEFT => .arrow_left,
        w32.VK_RIGHT => .arrow_right,
        w32.VK_UP => .arrow_up,
        w32.VK_DOWN => .arrow_down,
        w32.VK_HOME => .home,
        w32.VK_END => .end,
        w32.VK_PRIOR => .page_up,
        w32.VK_NEXT => .page_down,
        w32.VK_INSERT => .insert,
        w32.VK_DELETE => .delete,
        w32.VK_F1...(w32.VK_F1 + 23) => @enumFromInt(@as(c_int, @intFromEnum(input.Key.f1)) + @as(c_int, @intCast(vk - w32.VK_F1))),
        else => null,
    };
}

fn handleChar(surf: *Surface, wparam: w32.WPARAM) void {
    if (!surf.core_ready) return;

    const cu: u16 = @truncate(wparam);
    // Skip UTF-16 surrogate halves; non-BMP input isn't handled by this
    // skeleton.
    if (cu >= 0xD800 and cu <= 0xDFFF) return;

    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cu, &utf8_buf) catch return;

    const key: input.Key = if (cu < 128)
        (input.Key.fromASCII(@intCast(cu)) orelse .unidentified)
    else
        .unidentified;

    const event: input.KeyEvent = .{
        .action = .press,
        .key = key,
        .mods = currentMods(),
        .utf8 = utf8_buf[0..len],
    };
    _ = surf.core_surface.keyCallback(event) catch |err| {
        log.warn("keyCallback failed err={}", .{err});
    };
}

fn handleKey(surf: *Surface, wparam: w32.WPARAM, action: input.Action) void {
    if (!surf.core_ready) return;

    const vk: u32 = @intCast(wparam);
    const key = vkToKey(vk) orelse return;
    const event: input.KeyEvent = .{
        .action = action,
        .key = key,
        .mods = currentMods(),
        .utf8 = "",
    };
    _ = surf.core_surface.keyCallback(event) catch |err| {
        log.warn("keyCallback failed err={}", .{err});
    };
}

fn mouseButton(
    surf: *Surface,
    action: input.MouseButtonState,
    button: input.MouseButton,
) void {
    if (!surf.core_ready) return;
    _ = surf.core_surface.mouseButtonCallback(action, button, currentMods()) catch |err| {
        log.warn("mouseButtonCallback failed err={}", .{err});
    };
}

/// True if this WM_KEYDOWN was a tab/split-management shortcut and was
/// handled (Ctrl+T new tab, Ctrl+W close pane/tab, Ctrl+Tab /
/// Ctrl+Shift+Tab switch tab, Ctrl+Shift+O/E split vertical/horizontal,
/// Ctrl+Alt+Arrow move focus between panes). These are intercepted before
/// being forwarded to the terminal.
fn handleTabShortcut(window: *Window, wparam: w32.WPARAM) bool {
    const ctrl = w32.GetKeyState(@intCast(w32.VK_CONTROL)) < 0;
    if (!ctrl) return false;
    const shift = w32.GetKeyState(@intCast(w32.VK_SHIFT)) < 0;
    const alt = w32.GetKeyState(@intCast(w32.VK_MENU)) < 0;

    const vk: u32 = @intCast(wparam);

    if (shift) {
        switch (vk) {
            w32.VK_O => {
                if (window.focusedSurface()) |surf| {
                    _ = window.app.newSplit(surf, .vertical) catch |err| {
                        log.warn("failed to create split err={}", .{err});
                    };
                }
                return true;
            },
            w32.VK_E => {
                if (window.focusedSurface()) |surf| {
                    _ = window.app.newSplit(surf, .horizontal) catch |err| {
                        log.warn("failed to create split err={}", .{err});
                    };
                }
                return true;
            },
            w32.VK_TAB => {
                nextTab(window, -1);
                return true;
            },
            else => {},
        }
        return false;
    }

    if (alt) {
        switch (vk) {
            w32.VK_LEFT, w32.VK_RIGHT, w32.VK_UP, w32.VK_DOWN => {
                toggleFocus(window);
                return true;
            },
            else => {},
        }
        return false;
    }

    switch (vk) {
        w32.VK_T => {
            _ = window.app.newTab(window, .tab) catch |err| {
                log.warn("failed to create tab err={}", .{err});
            };
            return true;
        },
        w32.VK_W => {
            if (window.focusedSurface()) |surf| closePane(surf);
            return true;
        },
        w32.VK_TAB => {
            nextTab(window, 1);
            return true;
        },
        else => return false,
    }
}

/// Window procedure for the top-level frame window. This owns the tab
/// strip (drawn with GDI) and hosts the GL child window below it.
fn frameWndProc(
    hwnd: w32.HWND,
    msg: w32.UINT,
    wparam: w32.WPARAM,
    lparam: w32.LPARAM,
) callconv(.winapi) w32.LRESULT {
    if (msg == w32.WM_NCCREATE) {
        const cs: *const w32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |params| {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(params)));
        }
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const window = getWindow(hwnd) orelse
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_DESTROY => {
            const app = window.app;
            const alloc = app.core_app.alloc;

            for (window.tabs.items) |tab| {
                for (tab.panes.items) |surf| {
                    app.core_app.deleteSurface(surf);
                    if (surf.core_ready) surf.core_surface.deinit();
                    alloc.destroy(surf);
                }
                tab.panes.deinit(alloc);
                alloc.destroy(tab);
            }
            window.tabs.deinit(alloc);

            _ = w32.wglMakeCurrent(null, null);
            _ = w32.wglDeleteContext(window.hglrc);
            _ = w32.ReleaseDC(window.gl_hwnd, window.hdc);
            alloc.destroy(window);

            if (app.core_app.surfaces.items.len == 0) {
                app.quitting = true;
                w32.PostQuitMessage(0);
            }
            return 0;
        },

        w32.WM_CLOSE => {
            _ = w32.DestroyWindow(hwnd);
            return 0;
        },

        w32.WM_SIZE => {
            const width = w32.LOWORD(lparam);
            const height = w32.HIWORD(lparam);
            _ = w32.MoveWindow(
                window.gl_hwnd,
                0,
                tab_bar_height,
                width,
                @max(0, @as(i32, height) - tab_bar_height),
                w32.TRUE,
            );
            return 0;
        },

        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            paintTabBar(window, hdc);
            return 0;
        },

        // The frame window itself never wants keyboard focus -- forward it
        // to the GL child so terminal input keeps working after clicking
        // the titlebar, alt-tabbing back, etc.
        w32.WM_SETFOCUS => {
            _ = w32.SetFocus(window.gl_hwnd);
            return 0;
        },

        w32.WM_ERASEBKGND => return 1,

        w32.WM_LBUTTONDOWN => {
            const x: i16 = @bitCast(w32.LOWORD(lparam));
            const y: i16 = @bitCast(w32.HIWORD(lparam));
            if (y >= 0 and y < tab_bar_height and x >= 0) {
                const index: usize = @intCast(@divTrunc(@as(i32, x), tab_width));
                switchTab(window, index);
            }
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// Window procedure for the child GL surface. This forwards keyboard/
/// mouse/focus/size events to the active tab's currently focused pane.
fn glWndProc(
    hwnd: w32.HWND,
    msg: w32.UINT,
    wparam: w32.WPARAM,
    lparam: w32.LPARAM,
) callconv(.winapi) w32.LRESULT {
    if (msg == w32.WM_NCCREATE) {
        const cs: *const w32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |params| {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, @bitCast(@intFromPtr(params)));
        }
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const window = getWindow(hwnd) orelse
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

    switch (msg) {
        w32.WM_SIZE => {
            reflow(window);
            return 0;
        },

        w32.WM_SETFOCUS, w32.WM_KILLFOCUS => {
            if (window.focusedSurface()) |surf| {
                if (surf.core_ready) {
                    surf.core_surface.focusCallback(msg == w32.WM_SETFOCUS) catch |err| {
                        log.warn("focusCallback failed err={}", .{err});
                    };
                }
            }
            return 0;
        },

        w32.WM_ERASEBKGND => return 1,

        w32.WM_CHAR => {
            if (window.focusedSurface()) |surf| handleChar(surf, wparam);
            return 0;
        },

        w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN => {
            if (!handleTabShortcut(window, wparam)) {
                if (window.focusedSurface()) |surf| handleKey(surf, wparam, .press);
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_KEYUP, w32.WM_SYSKEYUP => {
            if (window.focusedSurface()) |surf| handleKey(surf, wparam, .release);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_MOUSEMOVE => {
            if (window.focusedSurface()) |surf| {
                const x: i16 = @bitCast(w32.LOWORD(lparam));
                const y: i16 = @bitCast(w32.HIWORD(lparam));
                surf.cursor_pos = .{
                    .x = @as(f32, @floatFromInt(x)) - @as(f32, @floatFromInt(surf.last_rect.left)),
                    .y = @as(f32, @floatFromInt(y)) - @as(f32, @floatFromInt(surf.last_rect.top)),
                };
                if (surf.core_ready) {
                    surf.core_surface.cursorPosCallback(surf.cursor_pos, currentMods()) catch |err| {
                        log.warn("cursorPosCallback failed err={}", .{err});
                    };
                }
            }
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            _ = w32.SetFocus(hwnd);
            if (window.activeTabPtr()) |tab| {
                const x: i16 = @bitCast(w32.LOWORD(lparam));
                const y: i16 = @bitCast(w32.HIWORD(lparam));
                if (tab.paneAt(x, y)) |idx| tab.focused = idx;
                if (tab.focusedPane()) |surf| mouseButton(surf, .press, .left);
            }
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (window.focusedSurface()) |surf| mouseButton(surf, .release, .left);
            return 0;
        },
        w32.WM_RBUTTONDOWN => {
            if (window.focusedSurface()) |surf| mouseButton(surf, .press, .right);
            return 0;
        },
        w32.WM_RBUTTONUP => {
            if (window.focusedSurface()) |surf| mouseButton(surf, .release, .right);
            return 0;
        },
        w32.WM_MBUTTONDOWN => {
            if (window.focusedSurface()) |surf| mouseButton(surf, .press, .middle);
            return 0;
        },
        w32.WM_MBUTTONUP => {
            if (window.focusedSurface()) |surf| mouseButton(surf, .release, .middle);
            return 0;
        },

        w32.WM_MOUSEWHEEL => {
            if (window.focusedSurface()) |surf| {
                if (surf.core_ready) {
                    const delta: i16 = @bitCast(w32.HIWORD(wparam));
                    const yoff: f64 = @as(f64, @floatFromInt(delta)) / 120.0;
                    surf.core_surface.scrollCallback(0, yoff, .{}) catch |err| {
                        log.warn("scrollCallback failed err={}", .{err});
                    };
                }
            }
            return 0;
        },

        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
