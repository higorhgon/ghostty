//! A minimal, hand-rolled native Win32/WGL apprt for Ghostty.
//!
//! This is an early skeleton: it opens real top-level Win32 windows, drives
//! a WGL (desktop OpenGL) context, supports multiple tabs per window (each
//! tab split into as many panes as wanted, with a tab overview), and
//! forwards keyboard/mouse/clipboard events into the core Ghostty engine.
//! It does NOT have feature parity with the GTK (Linux) or macOS (Swift)
//! apps -- there's no settings UI, no command palette, no search box, no
//! quick terminal, no high-DPI awareness, and keyboard handling only covers
//! the common ASCII/navigation cases. Its purpose is to be a real,
//! buildable starting point for a fuller native Windows app.
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
const tabbar = @import("win32/tabbar.zig");
const handoff = @import("win32/handoff.zig");
const termio = @import("../termio.zig");
const file_load = @import("../config/file_load.zig");
const gl = @import("opengl");
const wgl = @import("../renderer/OpenGL.zig").wgl;

const log = std.log.scoped(.win32);

pub const resourcesDir = internal_os.resourcesDir;

/// Height in pixels of the GDI-drawn tab strip at the top of each window.
const tab_bar_height: i32 = 32;
/// Fixed width in pixels of each tab in the strip. A fixed width keeps the
/// hit-testing/drawing code simple; it doesn't shrink to fit many tabs.
const tab_width: i32 = 180;
/// Width in pixels of the divider line drawn between two split panes.
const split_divider: i32 = 2;
/// Corner radius used when drawing each tab's rounded top corners.
const tab_radius: i32 = 8;
/// Size (both dimensions) of the per-tab close (x) button hit-box.
const close_btn_size: i32 = 18;
/// Gap between the close button and the tab's right edge.
const close_btn_margin: i32 = 8;
/// Width of the trailing "+" (new tab) button at the end of the strip.
const add_btn_width: i32 = 36;

/// What part of the tab strip the mouse is currently over, used to draw
/// hover feedback (and repaint only when it actually changes).
const HoverTarget = union(enum) {
    none,
    tab: usize,
    close: usize,
    add,

    fn eql(a: HoverTarget, b: HoverTarget) bool {
        return switch (a) {
            .none => b == .none,
            .add => b == .add,
            .tab => |i| switch (b) {
                .tab => |j| i == j,
                else => false,
            },
            .close => |i| switch (b) {
                .close => |j| i == j,
                else => false,
            },
        };
    }
};

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
    pub const IDC_ARROW: [*:0]align(1) const u16 = @ptrFromInt(32512);

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
    pub const WM_MOUSELEAVE: UINT = 0x02A3;
    pub const WM_NCCREATE: UINT = 0x0081;
    pub const WM_NCCALCSIZE: UINT = 0x0083;
    pub const WM_NCHITTEST: UINT = 0x0084;
    pub const WM_NCLBUTTONDOWN: UINT = 0x00A1;
    pub const WM_SYSCOMMAND: UINT = 0x0112;
    /// SC_MOVE with HTCAPTION in its low bits is what a press on a real
    /// title bar becomes: a move that follows the mouse, not the keyboard.
    pub const SC_MOVE: WPARAM = 0xF010;

    pub const HTCLIENT: LRESULT = 1;
    pub const HTCAPTION: LRESULT = 2;
    pub const HTTOP: LRESULT = 12;

    pub const SW_SHOWNOACTIVATE: c_int = 4;
    pub const SW_MINIMIZE: c_int = 6;
    pub const SW_MAXIMIZE: c_int = 3;
    pub const SW_RESTORE: c_int = 9;

    pub const SIZE_MAXIMIZED: WPARAM = 2;

    pub const SM_CYFRAME: c_int = 33;
    pub const SM_CXPADDEDBORDER: c_int = 92;

    pub const SWP_NOSIZE: UINT = 0x0001;
    pub const SWP_NOMOVE: UINT = 0x0002;
    pub const SWP_NOZORDER: UINT = 0x0004;
    pub const SWP_NOACTIVATE: UINT = 0x0010;
    pub const SWP_FRAMECHANGED: UINT = 0x0020;

    pub const NCCALCSIZE_PARAMS = extern struct {
        rgrc: [3]RECT,
        lppos: ?*anyopaque,
    };
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
    // OEM keys are positional; the names below are their US layout meaning.
    pub const VK_OEM_1: u32 = 0xBA;
    pub const VK_OEM_PLUS: u32 = 0xBB;
    pub const VK_OEM_COMMA: u32 = 0xBC;
    pub const VK_OEM_MINUS: u32 = 0xBD;
    pub const VK_OEM_PERIOD: u32 = 0xBE;
    pub const VK_OEM_2: u32 = 0xBF;
    pub const VK_OEM_3: u32 = 0xC0;
    pub const VK_OEM_4: u32 = 0xDB;
    pub const VK_OEM_5: u32 = 0xDC;
    pub const VK_OEM_6: u32 = 0xDD;
    pub const VK_OEM_7: u32 = 0xDE;
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
    pub extern "user32" fn PeekMessageW(*MSG, ?HWND, UINT, UINT, UINT) callconv(.winapi) BOOL;
    pub const PM_REMOVE: UINT = 0x0001;
    pub extern "user32" fn GetWindowRect(HWND, *RECT) callconv(.winapi) BOOL;
    pub extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
    pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
    pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
    pub extern "user32" fn PostQuitMessage(c_int) callconv(.winapi) void;
    pub extern "user32" fn PostThreadMessageW(DWORD, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
    pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
    pub extern "user32" fn SetWindowLongPtrW(HWND, c_int, isize) callconv(.winapi) isize;
    pub extern "user32" fn GetWindowLongPtrW(HWND, c_int) callconv(.winapi) isize;
    pub extern "user32" fn LoadCursorW(?HINSTANCE, [*:0]align(1) const u16) callconv(.winapi) ?HCURSOR;
    pub extern "user32" fn GetDC(HWND) callconv(.winapi) ?HDC;
    pub extern "user32" fn ReleaseDC(HWND, HDC) callconv(.winapi) c_int;
    pub extern "user32" fn GetKeyState(c_int) callconv(.winapi) i16;
    pub extern "user32" fn GetAsyncKeyState(c_int) callconv(.winapi) i16;
    pub extern "user32" fn GetKeyboardState(*[256]u8) callconv(.winapi) BOOL;
    pub extern "user32" fn SetKeyboardState(*[256]u8) callconv(.winapi) BOOL;
    pub const VK_LBUTTON = 0x01;
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
    pub extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
    pub extern "user32" fn MapVirtualKeyW(uCode: u32, uMapType: u32) callconv(.winapi) u32;
    pub const MAPVK_VK_TO_CHAR: u32 = 2;
    pub extern "user32" fn GetActiveWindow() callconv(.winapi) ?HWND;
    pub extern "user32" fn TrackMouseEvent(*TRACKMOUSEEVENT) callconv(.winapi) BOOL;
    pub extern "user32" fn SetWindowPos(HWND, ?HWND, i32, i32, i32, i32, UINT) callconv(.winapi) BOOL;
    pub extern "user32" fn PostMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) BOOL;
    pub extern "user32" fn SendMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
    pub extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
    pub extern "user32" fn IsZoomed(HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn GetSystemMetrics(c_int) callconv(.winapi) c_int;
    pub extern "user32" fn ScreenToClient(HWND, *POINT) callconv(.winapi) BOOL;

    pub const WM_ACTIVATE: UINT = 0x0006;
    pub const WM_HOTKEY: UINT = 0x0312;
    pub extern "user32" fn RegisterHotKey(?HWND, c_int, UINT, UINT) callconv(.winapi) BOOL;
    pub extern "user32" fn UnregisterHotKey(?HWND, c_int) callconv(.winapi) BOOL;
    pub extern "user32" fn VkKeyScanW(ch: u16) callconv(.winapi) i16;
    pub extern "user32" fn keybd_event(bVk: u8, bScan: u8, dwFlags: DWORD, dwExtraInfo: usize) callconv(.winapi) void;
    pub extern "kernel32" fn CreateDirectoryW([*:0]const u16, ?*anyopaque) callconv(.winapi) BOOL;
    pub extern "user32" fn IsWindowVisible(HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn FindWindowW(?[*:0]const u16, ?[*:0]const u16) callconv(.winapi) ?HWND;
    pub extern "kernel32" fn GetModuleFileNameW(?HINSTANCE, [*]u16, DWORD) callconv(.winapi) DWORD;

    pub const HMONITOR = *opaque {};
    pub const HFONT = *opaque {};
    pub const HDROP = *opaque {};

    pub const WS_POPUP: DWORD = 0x80000000;
    pub const WS_CLIPSIBLINGS: DWORD = 0x04000000;
    pub const GWL_STYLE: c_int = -16;
    pub const SWP_SHOWWINDOW: UINT = 0x0040;
    pub const SWP_HIDEWINDOW: UINT = 0x0080;
    pub const MONITOR_DEFAULTTONEAREST: DWORD = 2;
    pub const SW_SHOWNORMAL: c_int = 1;

    pub const WM_SETCURSOR: UINT = 0x0020;
    pub const WM_TIMER: UINT = 0x0113;
    pub const WM_DROPFILES: UINT = 0x0233;
    pub const HTTRANSPARENT: LRESULT = -1;

    pub const VK_LWIN: u32 = 0x5B;
    pub const VK_RWIN: u32 = 0x5C;

    pub const IDC_IBEAM: [*:0]align(1) const u16 = @ptrFromInt(32513);
    pub const IDC_WAIT: [*:0]align(1) const u16 = @ptrFromInt(32514);
    pub const IDC_CROSS: [*:0]align(1) const u16 = @ptrFromInt(32515);
    pub const IDC_SIZENWSE: [*:0]align(1) const u16 = @ptrFromInt(32642);
    pub const IDC_SIZENESW: [*:0]align(1) const u16 = @ptrFromInt(32643);
    pub const IDC_SIZEWE: [*:0]align(1) const u16 = @ptrFromInt(32644);
    pub const IDC_SIZENS: [*:0]align(1) const u16 = @ptrFromInt(32645);
    pub const IDC_SIZEALL: [*:0]align(1) const u16 = @ptrFromInt(32646);
    pub const IDC_NO: [*:0]align(1) const u16 = @ptrFromInt(32648);
    pub const IDC_HAND: [*:0]align(1) const u16 = @ptrFromInt(32649);
    pub const IDC_APPSTARTING: [*:0]align(1) const u16 = @ptrFromInt(32650);
    pub const IDC_HELP: [*:0]align(1) const u16 = @ptrFromInt(32651);

    /// The pseudo-handles SetWindowPos takes for "above everything" and
    /// "back among the ordinary windows".
    pub fn hwndTopmost() ?HWND {
        return @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
    }
    pub fn hwndNoTopmost() ?HWND {
        return @ptrFromInt(@as(usize, @bitCast(@as(isize, -2))));
    }

    pub const MONITORINFO = extern struct {
        cbSize: DWORD = @sizeOf(MONITORINFO),
        rcMonitor: RECT = undefined,
        rcWork: RECT = undefined,
        dwFlags: DWORD = 0,
    };

    pub const FLASHW_TRAY: DWORD = 0x2;
    pub const FLASHW_TIMERNOFG: DWORD = 0xC;
    pub const FLASHWINFO = extern struct {
        cbSize: UINT = @sizeOf(FLASHWINFO),
        hwnd: HWND,
        dwFlags: DWORD,
        uCount: UINT,
        dwTimeout: DWORD,
    };

    pub const FILETIME = extern struct { low: DWORD, high: DWORD };
    pub const WIN32_FILE_ATTRIBUTE_DATA = extern struct {
        dwFileAttributes: DWORD,
        ftCreationTime: FILETIME,
        ftLastAccessTime: FILETIME,
        ftLastWriteTime: FILETIME,
        nFileSizeHigh: DWORD,
        nFileSizeLow: DWORD,
    };

    pub extern "user32" fn MonitorFromWindow(HWND, DWORD) callconv(.winapi) ?HMONITOR;
    pub extern "user32" fn GetMonitorInfoW(HMONITOR, *MONITORINFO) callconv(.winapi) BOOL;
    pub extern "user32" fn SetCapture(HWND) callconv(.winapi) ?HWND;
    pub extern "user32" fn SetCursor(?HCURSOR) callconv(.winapi) ?HCURSOR;
    pub extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;
    pub extern "user32" fn GetForegroundWindow() callconv(.winapi) ?HWND;
    pub extern "user32" fn SetForegroundWindow(HWND) callconv(.winapi) BOOL;
    pub extern "user32" fn FlashWindowEx(*const FLASHWINFO) callconv(.winapi) BOOL;
    pub extern "user32" fn SetTimer(?HWND, usize, UINT, ?*const anyopaque) callconv(.winapi) usize;
    pub extern "user32" fn KillTimer(?HWND, usize) callconv(.winapi) BOOL;
    pub extern "user32" fn GetWindowTextW(HWND, [*]u16, c_int) callconv(.winapi) c_int;
    pub extern "user32" fn IsIconic(HWND) callconv(.winapi) BOOL;
    pub extern "kernel32" fn GetCurrentPackageFullName(
        len: *u32,
        name: ?[*]u16,
    ) callconv(.winapi) i32;
    pub extern "shell32" fn SetCurrentProcessExplicitAppUserModelID(
        id: [*:0]const u16,
    ) callconv(.winapi) i32;
    pub extern "kernel32" fn SetConsoleCtrlHandler(
        handler: ?*const anyopaque,
        add: BOOL,
    ) callconv(.winapi) BOOL;
    pub extern "gdi32" fn CreateFontW(
        cHeight: c_int,
        cWidth: c_int,
        cEscapement: c_int,
        cOrientation: c_int,
        cWeight: c_int,
        bItalic: DWORD,
        bUnderline: DWORD,
        bStrikeOut: DWORD,
        iCharSet: DWORD,
        iOutPrecision: DWORD,
        iClipPrecision: DWORD,
        iQuality: DWORD,
        iPitchAndFamily: DWORD,
        pszFaceName: [*:0]const u16,
    ) callconv(.winapi) ?HFONT;
    pub extern "shell32" fn ShellExecuteW(
        hwnd: ?HWND,
        lpOperation: ?[*:0]const u16,
        lpFile: [*:0]const u16,
        lpParameters: ?[*:0]const u16,
        lpDirectory: ?[*:0]const u16,
        nShowCmd: c_int,
    ) callconv(.winapi) ?*anyopaque;
    pub extern "shell32" fn DragAcceptFiles(HWND, BOOL) callconv(.winapi) void;
    pub extern "shell32" fn DragQueryFileW(HDROP, UINT, ?[*]u16, UINT) callconv(.winapi) UINT;
    pub extern "shell32" fn DragFinish(HDROP) callconv(.winapi) void;
    pub extern "kernel32" fn GetFileAttributesExW(
        lpFileName: [*:0]const u16,
        fInfoLevelId: c_int,
        lpFileInformation: *WIN32_FILE_ATTRIBUTE_DATA,
    ) callconv(.winapi) BOOL;

    pub const TME_LEAVE: DWORD = 0x00000002;
    pub const TRACKMOUSEEVENT = extern struct {
        cbSize: DWORD = @sizeOf(TRACKMOUSEEVENT),
        dwFlags: DWORD,
        hwndTrack: HWND,
        dwHoverTime: DWORD = 0,
    };

    pub extern "gdi32" fn ChoosePixelFormat(HDC, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
    pub extern "gdi32" fn SetPixelFormat(HDC, c_int, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
    pub extern "gdi32" fn SwapBuffers(HDC) callconv(.winapi) BOOL;
    pub extern "gdi32" fn CreateSolidBrush(COLORREF) callconv(.winapi) ?HBRUSH;
    pub extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.winapi) BOOL;
    pub extern "gdi32" fn SetBkMode(HDC, c_int) callconv(.winapi) c_int;
    pub extern "gdi32" fn SetTextColor(HDC, COLORREF) callconv(.winapi) DWORD;
    pub extern "gdi32" fn RoundRect(HDC, i32, i32, i32, i32, i32, i32) callconv(.winapi) BOOL;
    pub extern "gdi32" fn SelectObject(HDC, HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
    pub extern "gdi32" fn GetStockObject(c_int) callconv(.winapi) ?HGDIOBJ;
    pub const NULL_PEN: c_int = 8;

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

    // Fixed-function entry points, used only to dim unfocused panes. They
    // are available because the context comes from wglCreateContext, which
    // is a compatibility context -- the alternative would be compiling a
    // shader and managing a VAO just to draw one rectangle.
    pub const GL_BLEND: u32 = 0x0BE2;
    pub const GL_DEPTH_TEST: u32 = 0x0B71;
    pub const GL_TEXTURE_2D: u32 = 0x0DE1;
    pub const GL_SRC_ALPHA: u32 = 0x0302;
    pub const GL_ONE_MINUS_SRC_ALPHA: u32 = 0x0303;
    pub const GL_QUADS: u32 = 0x0007;
    pub const GL_PROJECTION: u32 = 0x1701;
    pub const GL_MODELVIEW: u32 = 0x1700;
    pub extern "opengl32" fn glBlendFunc(sfactor: u32, dfactor: u32) callconv(.winapi) void;
    pub extern "opengl32" fn glBegin(mode: u32) callconv(.winapi) void;
    pub extern "opengl32" fn glEnd() callconv(.winapi) void;
    pub extern "opengl32" fn glVertex2f(x: f32, y: f32) callconv(.winapi) void;
    pub extern "opengl32" fn glColor4f(r: f32, g: f32, b: f32, a: f32) callconv(.winapi) void;
    pub extern "opengl32" fn glMatrixMode(mode: u32) callconv(.winapi) void;
    pub extern "opengl32" fn glPushMatrix() callconv(.winapi) void;
    pub extern "opengl32" fn glPopMatrix() callconv(.winapi) void;
    pub extern "opengl32" fn glLoadIdentity() callconv(.winapi) void;
    pub extern "opengl32" fn glOrtho(l: f64, r: f64, b: f64, t: f64, n: f64, f: f64) callconv(.winapi) void;

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
const label_class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyOverviewLabel");

/// How often the config file's timestamp is looked at, in milliseconds.
const config_poll_ms: w32.UINT = 1000;

/// This is the main entrypoint to the apprt for Ghostty on Windows.
pub const App = @This();

/// Entry point for the GUI subsystem, which is what keeps Windows from
/// giving this process a console at all.
///
/// MSVC's GUI-subsystem CRT startup (`wWinMainCRTStartup`) calls
/// `wWinMain`. Zig's std start code does not provide one: with libc linked
/// and a `main` in the root module -- which main.zig always has, being
/// shared across every platform -- it exports a C `main` and stops there.
/// So the two halves never met, and the build stayed on the console
/// subsystem. This is the bridge.
///
/// The CRT has already parsed the command line into `__argc`/`__argv` by
/// the time this runs, whatever the subsystem, so the arguments are simply
/// forwarded on.
const gui_entry = struct {
    extern fn main(argc: c_int, argv: [*][*:0]u8) c_int;
    extern var __argc: c_int;
    extern var __argv: [*][*:0]u8;

    fn wWinMain(
        hInstance: ?*anyopaque,
        hPrevInstance: ?*anyopaque,
        lpCmdLine: ?[*:0]const u16,
        nCmdShow: c_int,
    ) callconv(.winapi) c_int {
        _ = hInstance;
        _ = hPrevInstance;
        _ = lpCmdLine;
        _ = nCmdShow;
        return main(__argc, __argv);
    }
};

comptime {
    if (builtin.abi == .msvc) {
        @export(&gui_entry.wWinMain, .{ .name = "wWinMain" });
    }
}

core_app: *CoreApp,
config: Config,
hinstance: w32.HINSTANCE,
main_thread_id: w32.DWORD,
quitting: bool = false,

/// The root of the GL share group. Each pane's renderer draws on its own
/// thread, in its own context, and leaves its finished frame in a
/// texture; each window composites those textures in its own context on
/// the main thread. Sharing with this one context is what puts them all
/// in one group, so that the textures cross over. It is never made
/// current and never draws.
gl_root: wgl.Context,
/// Whether the main thread's GL function pointers have been loaded,
/// which takes a current context and so waits for the first window.
gl_loaded: bool = false,

/// Every open window. The core only knows surfaces, and a window is more
/// than its surfaces: it has a strip to re-theme and a frame to redraw
/// when the config changes.
windows: std.ArrayListUnmanaged(*Window) = .empty,

/// The config file whose changes are picked up while running, as a wide
/// path, and the write time it had when it was last loaded. Null when the
/// path could not be worked out, in which case nothing is watched.
config_path: ?[:0]u16 = null,
config_mtime: u64 = 0,

/// The font the overview's labels are drawn in, made on first use.
ui_font: ?w32.HFONT = null,

/// The quick terminal's window, once it has been asked for.
quick_window: ?*Window = null,

/// While a saved session is being reopened: the name of the profile the
/// window being created should open its first tab with.
restore_profile: ?[]const u8 = null,

/// Started by COM to take a console session as the default terminal
/// (handoff.zig): no window of its own until the session arrives.
embedding: bool = false,
/// The thread timer that ends an embedding process no session ever came to.
embedding_timer: usize = 0,
/// Handed-off sessions on their way to a window: queued inside the COM
/// call, opened from the message loop (`wm_handoff`).
handoffs: std.ArrayListUnmanaged(termio.Exec.WindowsHandoff) = .empty,
/// The session the pane being created takes instead of starting a shell;
/// `newPane` consumes it.
pending_handoff: ?termio.Exec.WindowsHandoff = null,

pub fn init(
    self: *App,
    core_app: *CoreApp,

    // Required by the apprt interface but we don't use it.
    opts: struct {},
) !void {
    _ = opts;

    // Whether Ctrl+C is ignored is inherited, through process creation,
    // from whoever started us, and every shell would inherit it from us in
    // turn: Ctrl+C would then stop nothing. A GUI has no console of its
    // own to take Ctrl+C for, so clear it once before any shell starts, as
    // Windows Terminal does.
    _ = w32.SetConsoleCtrlHandler(null, w32.FALSE);

    // Without a package (the setup.exe install) Windows knows the process
    // by no ID of its own: its windows would not group with the Start menu
    // shortcut the installer pins, and its notifications would be dropped.
    // Claim the ID that shortcut carries (dist/windows/installer/ghostty.iss).
    // A packaged process already has one, which this must not override.
    var name_len: u32 = 0;
    const APPMODEL_ERROR_NO_PACKAGE = 15700;
    if (w32.GetCurrentPackageFullName(&name_len, null) == APPMODEL_ERROR_NO_PACKAGE) {
        _ = w32.SetCurrentProcessExplicitAppUserModelID(
            std.unicode.utf8ToUtf16LeStringLiteral("Ghostty.Terminal"),
        );
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

    const label_wc: w32.WNDCLASSEXW = .{
        .lpfnWndProc = &labelWndProc,
        .hInstance = hinstance,
        .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
        .lpszClassName = label_class_name,
    };
    if (w32.RegisterClassExW(&label_wc) == 0) return error.Unexpected;

    // Before the config is loaded, so that a first run already loads the
    // file it just wrote.
    self.core_app = core_app;
    self.writeDefaultConfig();

    var config = try Config.load(core_app.alloc);
    errdefer config.deinit();

    const gl_root = try wgl.Context.create(null);
    errdefer gl_root.destroy();

    self.* = .{
        .core_app = core_app,
        .config = config,
        .hinstance = hinstance,
        .main_thread_id = w32.GetCurrentThreadId(),
        .gl_root = gl_root,
        .embedding = handoff.isEmbedding(),
    };

    self.watchConfig();
}

pub fn terminate(self: *App) void {
    if (self.config_path) |p| self.core_app.alloc.free(p);
    self.windows.deinit(self.core_app.alloc);
    self.gl_root.destroy();
    self.config.deinit();
}

/// Starts watching the config file, so that saving it re-themes every open
/// window the way Windows Terminal follows its settings.json.
///
/// A timer that compares timestamps rather than a directory watch: the
/// file is tiny, once a second is as live as a theme switch needs, and a
/// timer has no handle to wait on and no thread to coordinate with. It is a
/// thread timer, so its WM_TIMER arrives with no window and is picked out
/// in `run`.
fn watchConfig(self: *App) void {
    const alloc = self.core_app.alloc;
    const path = file_load.defaultXdgPath(alloc) catch |err| {
        log.warn("config will not be watched, no path err={}", .{err});
        return;
    };
    defer alloc.free(path);

    self.config_path = std.unicode.utf8ToUtf16LeAllocZ(alloc, path) catch return;
    self.config_mtime = self.configWriteTime();
    _ = w32.SetTimer(null, 0, config_poll_ms, null);
}

/// Gives a fresh install a config file, with the default shell chosen.
///
/// Without one, a new window runs whatever `command` falls back to, which
/// on Windows is cmd.exe -- hardly anyone's shell of choice -- and there is
/// no file to show the user where that is decided. So the first run writes
/// one, naming the best shell this machine has, in the order Windows
/// Terminal prefers them. An existing config, in either file name, is left
/// exactly as it is.
fn writeDefaultConfig(self: *App) void {
    const alloc = self.core_app.alloc;
    const path = file_load.defaultXdgPath(alloc) catch return;
    defer alloc.free(path);
    const legacy = file_load.legacyDefaultXdgPath(alloc) catch return;
    defer alloc.free(legacy);

    var probe: [1]u8 = undefined;
    if (tabbar.readFileHead(path, &probe) != null) return;
    if (tabbar.readFileHead(legacy, &probe) != null) return;

    const profiles = tabbar.detectProfiles(alloc, &.{}) catch return;
    defer tabbar.freeProfiles(alloc, profiles);
    const shell: []const u8 = shell: {
        for ([_][]const u8{ "PowerShell 7", "Windows PowerShell", "Command Prompt" }) |want| {
            for (profiles) |p| {
                if (std.mem.eql(u8, p.name, want)) break :shell want;
            }
        }
        return;
    };

    const text = std.fmt.allocPrint(alloc,
        \\# Ghostty configuration.
        \\#
        \\# Every option is described at https://ghostty.org/docs/config, and
        \\# `ghostty +show-config --default --docs` prints them all. Saving
        \\# this file applies it to the windows that are open.
        \\
        \\# The shell new windows, tabs and splits open with: any name from the
        \\# new-tab dropdown. It can also be changed from the command palette
        \\# (Ctrl+Shift+P, "Set Default Shell").
        \\windows-default-shell = {s}
        \\
    , .{shell}) catch return;
    defer alloc.free(text);

    if (std.fs.path.dirname(path)) |dir| createDir(dir);
    if (!tabbar.writeWholeFile(path, text)) {
        log.warn("failed to write the default config", .{});
    }
}

fn createDir(path: []const u8) void {
    var wide: [1024:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wide[0..1023], path) catch return;
    wide[n] = 0;
    // Fails if it is already there, which is the usual case and fine.
    _ = w32.CreateDirectoryW(wide[0..n :0], null);
}

/// Makes `name` the shell new terminals open with, or with null goes back
/// to following the current tab, by rewriting that one line of the config
/// file and loading it again.
///
/// The file is edited as text, a line at a time, so everything else in it
/// -- comments, order, spacing -- stays as the user wrote it.
fn setDefaultShell(self: *App, name: ?[]const u8) void {
    const alloc = self.core_app.alloc;
    const path = file_load.defaultXdgPath(alloc) catch return;
    defer alloc.free(path);

    const buf = alloc.alloc(u8, 1024 * 1024) catch return;
    defer alloc.free(buf);
    const old: []const u8 = tabbar.readFileHead(path, buf) orelse "";
    // A file too big to have been read whole is not one to rewrite from
    // what was read of it.
    if (old.len == buf.len) return;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    var written = false;
    var lines = std.mem.splitScalar(u8, old, '\n');
    var first = true;
    while (lines.next()) |line| {
        const key = std.mem.trim(
            u8,
            line[0 .. std.mem.indexOfScalar(u8, line, '=') orelse line.len],
            " \t\r",
        );
        const ours = std.mem.eql(u8, key, "windows-default-shell");
        // The first such line is replaced in place; any later ones would
        // override it, so they go.
        if (ours and (written or name == null)) continue;

        if (!first) out.append(alloc, '\n') catch return;
        first = false;
        if (ours) {
            const cr = if (std.mem.endsWith(u8, line, "\r")) "\r" else "";
            out.print(alloc, "windows-default-shell = {s}{s}", .{ name.?, cr }) catch return;
            written = true;
        } else {
            out.appendSlice(alloc, line) catch return;
        }
    }
    if (name) |n| if (!written) {
        if (out.items.len > 0 and !std.mem.endsWith(u8, out.items, "\n")) {
            out.append(alloc, '\n') catch return;
        }
        out.print(alloc, "windows-default-shell = {s}\n", .{n}) catch return;
    };

    if (std.fs.path.dirname(path)) |dir| createDir(dir);
    if (!tabbar.writeWholeFile(path, out.items)) {
        log.warn("failed to save the default shell", .{});
        return;
    }
    self.reloadConfig(false) catch |err| {
        log.warn("failed to reload config err={}", .{err});
    };
}

/// The config file's last write time, or zero if it is not there.
fn configWriteTime(self: *App) u64 {
    const path = self.config_path orelse return 0;
    var data: w32.WIN32_FILE_ATTRIBUTE_DATA = undefined;
    // 0 is GetFileExInfoStandard.
    if (w32.GetFileAttributesExW(path.ptr, 0, &data) == w32.FALSE) return 0;
    return (@as(u64, data.ftLastWriteTime.high) << 32) | data.ftLastWriteTime.low;
}

fn checkConfigChanged(self: *App) void {
    const mtime = self.configWriteTime();
    if (mtime == self.config_mtime) return;
    self.config_mtime = mtime;
    // A file that went away is not a reason to drop to defaults: editors
    // and theme switchers replace the file by deleting and renaming, and
    // the next tick sees the new one.
    if (mtime == 0) return;
    log.info("config file changed, reloading", .{});
    self.reloadConfig(false) catch |err| {
        log.warn("failed to reload config err={}", .{err});
    };
}

/// Loads the config again and hands it to every surface and window.
fn reloadConfig(self: *App, soft: bool) !void {
    if (soft) {
        // Nothing to read: the core wants the same config back so it can
        // apply conditional state to it.
        try self.core_app.updateConfig(self, &self.config);
    } else {
        var config = try Config.load(self.core_app.alloc);
        errdefer config.deinit();
        try self.core_app.updateConfig(self, &config);
        self.config.deinit();
        self.config = config;
        // Whatever triggered this, the file as it is now is what is loaded.
        self.config_mtime = self.configWriteTime();
        // The quick terminal's key may be a different one now.
        self.registerHotkeys();
    }

    // The strip and the frame take their colours from the config too, and
    // only the surfaces heard about it above.
    for (self.windows.items) |window| {
        applyTabBarTheme(window);
        // `window-decoration` and `window-show-tab-bar` may have changed:
        // a reload of the file wins over a toggle, as on Linux.
        if (!soft) window.decorated = self.config.@"window-decoration" != .none;
        refreshFrame(window);
        if (!window.customFrame()) applyTitlebarTheme(window.hwnd, &self.config);
        for (window.overview_labels.items) |label| {
            _ = w32.InvalidateRect(label, null, w32.TRUE);
        }
        reflow(window);
    }
}

/// The id the quick terminal's hotkey is registered under.
const hotkey_quick_terminal: c_int = 1;

/// Makes the `toggle_quick_terminal` binding work from anywhere.
///
/// A quick terminal that can only be summoned while Ghostty already has
/// focus is not one, so whatever key is bound to it is registered with the
/// system. That takes the key away from every other program for as long as
/// Ghostty runs, which is the point and is why nothing else is registered
/// this way.
fn registerHotkeys(self: *App) void {
    _ = w32.UnregisterHotKey(null, hotkey_quick_terminal);
    const trigger = self.config.keybind.set.getTrigger(.toggle_quick_terminal) orelse return;

    const vk: u32 = switch (trigger.key) {
        // Whatever key types that character on this layout.
        .unicode => |cp| vk: {
            if (cp > 0xFFFF) return;
            const scan = w32.VkKeyScanW(@intCast(cp));
            if (scan == -1) return;
            break :vk @as(u32, @intCast(scan & 0xFF));
        },
        .physical => |key| vk: {
            var candidate: u32 = 0;
            while (candidate < 256) : (candidate += 1) {
                if (vkToKey(candidate) == key) break :vk candidate;
            }
            return;
        },
        else => return,
    };

    var mods: w32.UINT = 0x4000; // MOD_NOREPEAT
    if (trigger.mods.alt) mods |= 0x1;
    if (trigger.mods.ctrl) mods |= 0x2;
    if (trigger.mods.shift) mods |= 0x4;
    if (trigger.mods.super) mods |= 0x8;
    if (w32.RegisterHotKey(null, hotkey_quick_terminal, mods, vk) == w32.FALSE) {
        log.warn("quick terminal hotkey is taken by another program", .{});
    }
}

/// Shows the quick terminal, or hides it if it is what the user is in.
fn toggleQuickTerminal(self: *App) void {
    if (self.quick_window) |window| {
        const hwnd = window.hwnd;
        // By visibility alone. "Hide it only if it has the focus" sounds
        // more careful and is not: Windows can decline to give a window
        // the focus, and then a key that should hide it shows it again,
        // for ever.
        if (w32.IsWindowVisible(hwnd) != 0) {
            _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
        } else {
            _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
            forceForeground(hwnd);
        }
        return;
    }

    const window = self.newWindow(null) catch |err| {
        log.warn("failed to create quick terminal err={}", .{err});
        return;
    };
    window.quick = true;
    self.quick_window = window;

    // Across the top of the monitor, a little under half its height, above
    // everything else. `quick-terminal-position` and `-size` are not
    // honoured yet: this is the default of both.
    const monitor = w32.MonitorFromWindow(window.hwnd, w32.MONITOR_DEFAULTTONEAREST) orelse return;
    var info: w32.MONITORINFO = .{};
    if (w32.GetMonitorInfoW(monitor, &info) == w32.FALSE) return;
    const work = info.rcWork;
    window.floating = true;
    _ = w32.SetWindowPos(
        window.hwnd,
        w32.hwndTopmost(),
        work.left,
        work.top,
        work.right - work.left,
        @divTrunc((work.bottom - work.top) * 45, 100),
        w32.SWP_SHOWWINDOW,
    );
    forceForeground(window.hwnd);
}

/// Brings a window to the foreground even when this process is not the
/// one the user is in.
///
/// Windows only lets the foreground process hand the foreground on, and a
/// quick terminal is by definition summoned from somewhere else. A hotkey
/// does carry that right, but it has lapsed by the time a window has been
/// created. Pressing and releasing Alt is the long-standing way round: the
/// system counts it as input from the user to this thread, and input is
/// what the rule is really about.
fn forceForeground(hwnd: w32.HWND) void {
    if (w32.SetForegroundWindow(hwnd) != w32.FALSE and
        w32.GetForegroundWindow() == hwnd) return;
    w32.keybd_event(@intCast(w32.VK_MENU), 0, 0, 0);
    w32.keybd_event(@intCast(w32.VK_MENU), 0, 2, 0); // KEYEVENTF_KEYUP
    _ = w32.SetForegroundWindow(hwnd);
}

/// Where the session is kept: beside the config file.
fn sessionPath(self: *App, buf: []u8) ?[]const u8 {
    const alloc = self.core_app.alloc;
    const config_path = file_load.defaultXdgPath(alloc) catch return null;
    defer alloc.free(config_path);
    const dir = std.fs.path.dirname(config_path) orelse return null;
    return std.fmt.bufPrint(buf, "{s}\\session.win32", .{dir}) catch null;
}

/// Writes down the tabs of the last window as it closes, for
/// `window-save-state = always` to reopen next time.
///
/// One profile name per line, in tab order; an empty line is a tab that
/// just ran the configured command. That is all that can be brought back:
/// the shells themselves end with the window.
fn saveSession(self: *App, window: *Window) void {
    if (self.config.@"window-save-state" != .always) return;
    // The last ordinary window. The quick terminal is not a session.
    if (window.quick) return;
    for (self.windows.items) |other| {
        if (other != window and !other.quick) return;
    }

    var path_buf: [1024]u8 = undefined;
    const path = self.sessionPath(&path_buf) orelse return;

    const alloc = self.core_app.alloc;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    for (window.tabs.items) |tab| {
        if (tab.profile) |p| out.appendSlice(alloc, p.name) catch return;
        out.append(alloc, '\n') catch return;
    }
    if (!tabbar.writeWholeFile(path, out.items)) {
        log.warn("failed to save the session", .{});
    }
}

/// Thread message: `handoffs` has sessions waiting for a window.
const wm_handoff: w32.UINT = w32.WM_APP + 12;

/// handoff.zig's callback, inside the COM call. Only queues: opening a
/// window pumps messages, and the console host is still waiting for the
/// call to return.
fn onHandoff(ctx: *anyopaque, session: termio.Exec.WindowsHandoff) void {
    const self: *App = @ptrCast(@alignCast(ctx));
    self.handoffs.append(self.core_app.alloc, session) catch {
        log.err("out of memory queueing a console handoff", .{});
        var dropped = session;
        dropped.pty.deinit();
        _ = internal_os.windows.exp.kernel32.CloseHandle(session.client);
        return;
    };
    _ = w32.PostThreadMessageW(self.main_thread_id, wm_handoff, 0, 0);
}

/// One window per handed-off session, its only tab attached to it.
fn openHandoffs(self: *App) void {
    while (self.handoffs.items.len > 0) {
        const session = self.handoffs.orderedRemove(0);
        self.pending_handoff = session;
        _ = self.newWindow(null) catch |err| {
            log.err("failed to open a window for a console handoff err={}", .{err});
        };
        // Not taken by a pane: nothing else will close it.
        if (self.pending_handoff) |left| {
            self.pending_handoff = null;
            var dropped = left;
            dropped.pty.deinit();
            _ = internal_os.windows.exp.kernel32.CloseHandle(left.client);
        }
    }
    // The first window is up: the process now ends with its last window.
}

/// Opens the first window, with the tabs the last session ended with if
/// the config asks for that.
fn openInitialWindow(self: *App) !void {
    restore: {
        if (self.config.@"window-save-state" != .always) break :restore;
        var path_buf: [1024]u8 = undefined;
        const path = self.sessionPath(&path_buf) orelse break :restore;
        var data_buf: [16 * 1024]u8 = undefined;
        const data = tabbar.readFileHead(path, &data_buf) orelse break :restore;
        if (data.len == 0) break :restore;

        // Splitting on the newline that ends each line leaves one empty
        // piece after the last, which is not a tab.
        const body = std.mem.trimEnd(u8, data, "\n");
        var lines = std.mem.splitScalar(u8, body, '\n');
        const first = lines.next() orelse break :restore;

        self.restore_profile = std.mem.trim(u8, first, "\r");
        const window = self.newWindow(null) catch |err| {
            self.restore_profile = null;
            return err;
        };
        self.restore_profile = null;

        while (lines.next()) |line| {
            const name = std.mem.trim(u8, line, "\r");
            const profile = profileByName(window, name);
            _ = self.newTab(window, .tab, profile) catch |err| {
                log.warn("failed to restore tab err={}", .{err});
            };
        }
        // Back on the first tab, as a fresh window would be.
        switchTab(window, 0);
        return;
    }

    _ = try self.newWindow(null);
}

fn profileByName(window: *Window, name: []const u8) ?*const tabbar.Profile {
    if (name.len == 0) return null;
    for (window.profiles) |*p| {
        if (std.mem.eql(u8, p.name, name)) return p;
    }
    return null;
}

/// The profile a new window's first tab opens with.
fn firstTabProfile(self: *App, window: *Window) ?*const tabbar.Profile {
    // A handed-off session runs whatever program was started, not a shell
    // of ours: no profile to name the tab after or to open new tabs with.
    if (self.pending_handoff != null) return null;
    if (self.restore_profile) |name| return profileByName(window, name);
    return newTabProfile(self, window);
}

pub fn run(self: *App) !void {
    if (self.embedding) {
        // Started by COM for a console handoff: the window is the
        // session's, opened when it arrives. A process it never reaches
        // (the caller gave up) must not linger with nothing on screen.
        handoff.register(self, onHandoff) catch |err| {
            log.err("could not serve the console handoff err={}", .{err});
            return err;
        };
        self.embedding_timer = w32.SetTimer(null, 0, 30_000, null);
    } else {
        self.registerHotkeys();

        // Open our first window with one tab. Further windows/tabs can be
        // opened via the `new_window`/`new_tab` actions (keybindings).
        self.openInitialWindow() catch |err| {
            log.err("failed to create initial window err={}", .{err});
            return err;
        };
    }

    var msg: w32.MSG = undefined;
    while (!self.quitting) {
        const ret = w32.GetMessageW(&msg, null, 0, 0);
        if (ret == 0 or ret == -1) break;

        if (msg.hwnd == null and msg.message == w32.WM_TIMER and
            self.embedding_timer != 0 and msg.wParam == self.embedding_timer)
        {
            _ = w32.KillTimer(null, self.embedding_timer);
            self.embedding_timer = 0;
            if (self.windows.items.len == 0 and self.handoffs.items.len == 0) {
                log.warn("started for a console handoff that never came, quitting", .{});
                break;
            }
            continue;
        }

        // The config watcher's tick. A thread timer belongs to no window,
        // so nothing would dispatch it.
        if (msg.hwnd == null and msg.message == w32.WM_TIMER) {
            self.checkConfigChanged();
            continue;
        }

        // A handed-off console session, queued by the COM call.
        if (msg.hwnd == null and msg.message == wm_handoff) {
            self.openHandoffs();
            continue;
        }
        // The quick terminal's hotkey, which is likewise the thread's.
        if (msg.hwnd == null and msg.message == w32.WM_HOTKEY) {
            if (msg.wParam == hotkey_quick_terminal) self.toggleQuickTerminal();
            continue;
        }

        // The XAML island gets first refusal, or it never sees keyboard
        // input (tab navigation, accelerators). It reports back whether it
        // consumed the message, in which case we must not dispatch it.
        if (self.pretranslate(&msg)) continue;

        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);

        self.core_app.tick(self) catch |err| {
            log.warn("app tick failed err={}", .{err});
        };
    }
}

/// Offers a message to every window's native tab strip. Returns true if
/// one of them consumed it.
///
/// This walks the window list because the strip lives in a child HWND per
/// window and only that window's island knows whether the message was
/// meant for it.
fn pretranslate(self: *App, msg: *w32.MSG) bool {
    // Surfaces are panes, so many of them share a window; offering the
    // same island the same message repeatedly would be wrong as well as
    // wasteful. Windows are few, so a small stack set is enough.
    var seen: [16]*Window = undefined;
    var seen_len: usize = 0;

    outer: for (self.core_app.surfaces.items) |surf| {
        const window = surf.tab.window;
        const bar = window.tab_bar orelse continue;
        for (seen[0..seen_len]) |w| {
            if (w == window) continue :outer;
        }
        if (seen_len < seen.len) {
            seen[seen_len] = window;
            seen_len += 1;
        }
        if (tabbar.ghostty_tabbar_pretranslate(bar, @ptrCast(msg)) != 0) return true;
    }
    return false;
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
            _ = try self.newWindow(null);
            return true;
        },

        .new_tab => {
            switch (target) {
                .app => _ = try self.newWindow(null),
                .surface => |core| _ = try self.newTab(
                    core.rt_surface.tab.window,
                    .tab,
                    newTabProfile(self, core.rt_surface.tab.window),
                ),
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
                    const before = switch (value) {
                        .left, .up => true,
                        .right, .down => false,
                    };
                    _ = self.newSplit(core.rt_surface, dir, before) catch |err| {
                        log.warn("failed to create split err={}", .{err});
                    };
                },
            }
            return true;
        },

        .close_tab => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            const tab = core.rt_surface.tab;
            const window = tab.window;
            const index = window.indexOfTab(tab) orelse return true;
            switch (value) {
                .this => closeTabAt(window, index),
                // Back to front, so that closing one does not move the
                // ones still to be closed.
                .other => {
                    var i = window.tabs.items.len;
                    while (i > 0) {
                        i -= 1;
                        if (i != index) closeTabAt(window, i);
                    }
                },
                .right => {
                    var i = window.tabs.items.len;
                    while (i > index + 1) {
                        i -= 1;
                        closeTabAt(window, i);
                    }
                },
            }
            return true;
        },

        .goto_tab => {
            const window = targetWindow(target) orelse return false;
            const count = window.tabs.items.len;
            if (count == 0) return false;
            const index: usize = switch (value) {
                .previous => (window.active + count - 1) % count,
                .next => (window.active + 1) % count,
                .last => count - 1,
                // Counted from one, whatever the action's own doc comment
                // says: the core passes the binding's number straight
                // through, and `goto_tab:1` is the first tab.
                else => index: {
                    const n = @backingInt(value);
                    if (n < 1 or n > count) return false;
                    break :index @intCast(n - 1);
                },
            };
            setOverview(window, false);
            switchTab(window, index);
            return true;
        },

        .move_tab => {
            const window = targetWindow(target) orelse return false;
            const count: isize = @intCast(window.tabs.items.len);
            if (count < 2) return false;
            const from: isize = @intCast(window.active);
            const to = @mod(from + value.amount, count);
            moveTab(window, window.active, @intCast(to), true);
            return true;
        },

        .goto_split => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            return gotoSplit(core.rt_surface, value);
        },

        .resize_split => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            return resizeSplit(core.rt_surface, value);
        },

        .equalize_splits => {
            const window = targetWindow(target) orelse return false;
            const tab = window.activeTabPtr() orelse return false;
            const root = tab.root orelse return false;
            equalizeNode(root);
            tab.zoomed = null;
            reflow(window);
            return true;
        },

        .toggle_split_zoom => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            const surf: *Surface = core.rt_surface;
            const tab = surf.tab;
            if (tab.panes.items.len < 2) return false;
            tab.zoomed = if (tab.zoomed == surf) null else surf;
            reflow(tab.window);
            return true;
        },

        .toggle_tab_overview => {
            const window = targetWindow(target) orelse return false;
            setOverview(window, !window.overview);
            return true;
        },

        .toggle_fullscreen => {
            const window = targetWindow(target) orelse return false;
            setFullscreen(window, !window.fullscreen);
            return true;
        },

        .toggle_window_decorations => {
            const window = targetWindow(target) orelse return false;
            setDecorated(window, !window.decorated);
            return true;
        },

        .toggle_maximize => {
            const window = targetWindow(target) orelse return false;
            if (window.fullscreen) return false;
            _ = w32.ShowWindow(
                window.hwnd,
                if (w32.IsZoomed(window.hwnd) != 0) w32.SW_RESTORE else w32.SW_MAXIMIZE,
            );
            return true;
        },

        .float_window => {
            const window = targetWindow(target) orelse return false;
            window.floating = switch (value) {
                .on => true,
                .off => false,
                .toggle => !window.floating,
            };
            const ok = w32.SetWindowPos(
                window.hwnd,
                if (window.floating) w32.hwndTopmost() else w32.hwndNoTopmost(),
                0,
                0,
                0,
                0,
                w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOACTIVATE,
            );
            if (ok == w32.FALSE) log.warn("float_window: SetWindowPos failed", .{});
            return true;
        },

        .present_terminal => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            const surf: *Surface = core.rt_surface;
            const tab = surf.tab;
            const window = tab.window;
            if (tab.indexOfPane(surf)) |i| tab.focused = i;
            if (window.indexOfTab(tab)) |i| switchTab(window, i);
            if (w32.IsIconic(window.hwnd) != 0) _ = w32.ShowWindow(window.hwnd, w32.SW_RESTORE);
            _ = w32.SetForegroundWindow(window.hwnd);
            reflow(window);
            return true;
        },

        .start_search => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            return showSearch(core.rt_surface, value.needle);
        },

        .end_search => {
            const window = targetWindow(target) orelse return false;
            if (window.input_mode != .search) return true;
            window.input_mode = .none;
            window.input_surface = null;
            if (window.tab_bar) |bar| tabbar.ghostty_tabbar_input_hide(bar);
            return true;
        },

        .search_total => {
            const window = targetWindow(target) orelse return false;
            window.search_total = value.total;
            syncSearchStatus(window);
            return true;
        },

        .search_selected => {
            const window = targetWindow(target) orelse return false;
            window.search_selected = value.selected;
            syncSearchStatus(window);
            return true;
        },

        .toggle_command_palette => {
            const window = targetWindow(target) orelse return false;
            showPalette(window);
            return true;
        },

        // Whichever title is asked about, the tab's is the one there is
        // somewhere to show: a pane has no caption of its own and the
        // window's is the active tab's.
        .prompt_title => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            showRename(core.rt_surface.tab);
            return true;
        },

        .set_tab_title => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            setTabTitleOverride(core.rt_surface.tab, value.title);
            return true;
        },

        .move_tab_to_new_window => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            try moveTabToNewWindow(self, core.rt_surface.tab);
            return true;
        },

        .toggle_quick_terminal => {
            self.toggleQuickTerminal();
            return true;
        },

        .desktop_notification => {
            var title: [256:0]u16 = undefined;
            const title_len = std.unicode.utf8ToUtf16Le(title[0..255], value.title) catch 0;
            title[title_len] = 0;
            var body: [1024:0]u16 = undefined;
            const body_len = std.unicode.utf8ToUtf16Le(body[0..1023], value.body) catch 0;
            body[body_len] = 0;
            tabbar.ghostty_tabbar_notify(title[0..title_len :0], body[0..body_len :0]);
            return true;
        },

        .progress_report => {
            const window = targetWindow(target) orelse return false;
            const state: tabbar.Progress = switch (value.state) {
                .remove => .none,
                .set => .normal,
                .@"error" => .@"error",
                .indeterminate => .indeterminate,
                .pause => .paused,
            };
            tabbar.ghostty_tabbar_set_progress(
                window.hwnd,
                state,
                if (value.progress) |p| @intCast(p) else 0,
            );
            return true;
        },

        .reload_config => {
            try self.reloadConfig(value.soft);
            return true;
        },

        // Everything config-dependent this apprt holds is refreshed by
        // reloadConfig itself, once the new config has been stored: the
        // pointer here is only good for the length of this call.
        .config_change => return true,

        .open_config => {
            const alloc = self.core_app.alloc;
            const path = configpkg.edit.openPath(alloc) catch |err| {
                log.warn("no config file to open err={}", .{err});
                return false;
            };
            defer alloc.free(path);
            // Notepad by name rather than "whatever opens this file": the
            // config has no extension anything is registered for, so the
            // shell's answer would be the "how do you want to open this?"
            // dialog.
            shellOpen(alloc, "notepad.exe", path);
            return true;
        },

        .open_url => {
            self.openUrl(value);
            return true;
        },

        .ring_bell => {
            const window = targetWindow(target) orelse return false;
            // Only when the user is elsewhere: flashing the taskbar button
            // of the window they are typing into tells them nothing.
            if (w32.GetForegroundWindow() == window.hwnd) return true;
            const info: w32.FLASHWINFO = .{
                .hwnd = window.hwnd,
                .dwFlags = w32.FLASHW_TRAY | w32.FLASHW_TIMERNOFG,
                .uCount = 3,
                .dwTimeout = 0,
            };
            _ = w32.FlashWindowEx(&info);
            return true;
        },

        .mouse_shape => {
            const core = switch (target) {
                .app => return false,
                .surface => |core| core,
            };
            const surf: *Surface = core.rt_surface;
            surf.cursor = w32.LoadCursorW(null, switch (value) {
                .text, .vertical_text, .cell => w32.IDC_IBEAM,
                .pointer, .grab, .grabbing => w32.IDC_HAND,
                .crosshair => w32.IDC_CROSS,
                .wait => w32.IDC_WAIT,
                .progress => w32.IDC_APPSTARTING,
                .help => w32.IDC_HELP,
                .not_allowed, .no_drop => w32.IDC_NO,
                .move, .all_scroll => w32.IDC_SIZEALL,
                .col_resize, .ew_resize, .e_resize, .w_resize => w32.IDC_SIZEWE,
                .row_resize, .ns_resize, .n_resize, .s_resize => w32.IDC_SIZENS,
                .nesw_resize, .ne_resize, .sw_resize => w32.IDC_SIZENESW,
                .nwse_resize, .nw_resize, .se_resize => w32.IDC_SIZENWSE,
                else => w32.IDC_ARROW,
            });
            // WM_SETCURSOR only comes with mouse movement, and the shape
            // changes under a mouse that is standing still -- when a
            // program turns mouse reporting on, say.
            if (surf.tab.window.focusedSurface() == surf and
                !surf.tab.window.overview)
            {
                _ = w32.SetCursor(surf.cursor);
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
                    const window = surf.tab.window;
                    // The overview shows every tab, so every tab's frames
                    // are worth a redraw while it is up.
                    if (window.overview or window.activeTabPtr() == surf.tab) {
                        reflow(window);
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
    switch (action) {
        // `ghostty +new-window`: hand the request to a Ghostty that is
        // already running, if there is one, instead of starting another.
        // Its frame class is how it is found, and a posted message is all
        // the transport a request with no arguments needs. Whatever the
        // caller wanted the window to run is not carried over yet.
        .new_window => {
            const existing = w32.FindWindowW(frame_class_name, null) orelse return false;
            return w32.PostMessageW(existing, wm_ipc_new_window, 0, 0) != w32.FALSE;
        },
        else => return false,
    }
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
    /// What a pane's frame is attached to in order to be copied into the
    /// window. Framebuffer objects are per context, hence per window.
    read_fbo: ?gl.Framebuffer = null,
    tabs: std.ArrayListUnmanaged(*Tab) = .empty,
    active: usize = 0,
    /// What the mouse is currently hovering in the tab strip, if anything.
    /// Only meaningful when `tab_bar` is null (the GDI fallback).
    hover: HoverTarget = .none,

    /// The native WinUI tab strip, or null when it could not be created --
    /// which is the normal case for an unpackaged build, since WinUI 2
    /// only activates for a process with MSIX package identity. When null
    /// we fall back to the hand-drawn GDI strip.
    tab_bar: ?*tabbar.TabBar = null,
    /// Shells offered in the new-tab dropdown.
    profiles: []tabbar.Profile = &.{},

    /// Whether the OS gives this window keyboard focus. A pane is only
    /// really focused when this is true, which is what stops background
    /// windows from blinking their cursors.
    has_focus: bool = false,

    /// The title last given to SetWindowTextW, so that reflow, which runs
    /// on every frame, only sets it when it changes. Each set notifies the
    /// shell, the taskbar and any window manager watching title changes.
    shown_title: [512]u16 = undefined,
    shown_title_len: usize = std.math.maxInt(usize),

    /// Set once the window has been shown and has been given the chance to
    /// settle at its final size. Until then `reflow` lays panes out but
    /// does not start them, because the size it is laying them out at is
    /// not yet the size they will keep. See `Surface.pending`.
    settled: bool = false,

    /// The split whose divider is being dragged, between the button going
    /// down on it and coming back up.
    drag_split: ?*SplitNode = null,

    /// Covering the whole monitor, with the frame and the strip put away.
    /// The style and placement the window had before are kept so that
    /// leaving fullscreen puts it back exactly.
    fullscreen: bool = false,
    saved_style: isize = 0,
    saved_rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },

    /// Kept above other windows (`float_window`).
    floating: bool = false,

    /// Showing every tab as a thumbnail instead of the active tab.
    overview: bool = false,
    /// The thumbnail the pointer or the arrow keys are on.
    overview_sel: usize = 0,
    /// One caption per thumbnail, reused across openings. Plain child
    /// windows drawn with GDI: the terminal area is a GL surface, which
    /// has no way to draw text of its own.
    overview_labels: std.ArrayListUnmanaged(w32.HWND) = .empty,

    /// What the input popup is up as, and what it is about: the pane
    /// being searched, or the tab being renamed.
    input_mode: InputMode = .none,
    input_surface: ?*Surface = null,
    input_tab: ?*Tab = null,
    /// For each row the palette is showing, which command it is.
    palette_map: std.ArrayListUnmanaged(usize) = .empty,
    /// The search's match count and current match, as last reported.
    search_total: ?usize = null,
    search_selected: ?usize = null,

    /// The quick terminal: the one window that a hotkey shows and hides
    /// rather than opening anew.
    quick: bool = false,

    /// Whether the window has its title bar and tab strip at all
    /// (`window-decoration`, flipped at runtime by
    /// `toggle_window_decorations`). Without them it is the terminal and a
    /// resizable border, like Windows Terminal's focus mode.
    decorated: bool = true,

    /// True while the system caption is gone from the window: the native
    /// tab strip is standing in for it, or the window has no decorations.
    /// The GDI fallback strip keeps the system title bar, because it has no
    /// caption buttons of its own.
    fn customFrame(self: *const Window) bool {
        if (!self.decorated) return true;
        return self.tab_bar != null and self.stripShown();
    }

    /// Whether the tab strip is on screen. `window-show-tab-bar = auto` is
    /// the same as `always` here: the strip is also the title bar, with the
    /// caption buttons and the drag area, so hiding it for a single tab
    /// would change what the window looks like every time a tab opens.
    /// `never` gives the window the system title bar instead.
    fn stripShown(self: *const Window) bool {
        if (self.fullscreen or !self.decorated) return false;
        return self.app.config.@"window-show-tab-bar" != .never;
    }

    /// The strip's height whether or not it is shown: where it is put
    /// when it is out of sight, and what it needs when it comes back.
    fn stripHeight(self: *Window) i32 {
        if (self.tab_bar) |bar| return tabbar.ghostty_tabbar_height(bar);
        return tab_bar_height;
    }

    /// The height the strip takes from the terminal: none when hidden.
    fn shownStripHeight(self: *Window) i32 {
        return if (self.stripShown()) self.stripHeight() else 0;
    }

    fn indexOfTab(self: *Window, tab: *const Tab) ?usize {
        for (self.tabs.items, 0..) |t, i| {
            if (t == tab) return i;
        }
        return null;
    }

    /// Finds the tab the native strip knows by `id`.
    fn tabById(self: *Window, id: tabbar.TabId) ?usize {
        for (self.tabs.items, 0..) |t, i| {
            if (t.bar_id == id) return i;
        }
        return null;
    }

    /// Rect of the "+" (new tab) button, in frame client coordinates.
    fn addButtonRect(self: *Window) w32.RECT {
        const left: i32 = @as(i32, @intCast(self.tabs.items.len)) * tab_width;
        return .{ .left = left, .top = 0, .right = left + add_btn_width, .bottom = tab_bar_height };
    }

    /// Hit-tests a point in frame client coordinates against the tab strip,
    /// returning what it landed on (a tab, a tab's close button, the add
    /// button, or nothing).
    fn hitTestTabBar(self: *Window, x: i32, y: i32) HoverTarget {
        if (y < 0 or y >= tab_bar_height or x < 0) return .none;

        const add_rect = self.addButtonRect();
        if (x >= add_rect.left and x < add_rect.right) return .add;

        const index: usize = @intCast(@divTrunc(x, tab_width));
        if (index >= self.tabs.items.len) return .none;

        const tab_left = @as(i32, @intCast(index)) * tab_width;
        const close_left = tab_left + tab_width - close_btn_margin - close_btn_size;
        const close_top = @divTrunc(tab_bar_height - close_btn_size, 2);
        if (x >= close_left and x < close_left + close_btn_size and
            y >= close_top and y < close_top + close_btn_size)
        {
            return .{ .close = index };
        }

        return .{ .tab = index };
    }

    fn activeTabPtr(self: *Window) ?*Tab {
        if (self.active >= self.tabs.items.len) return null;
        return self.tabs.items[self.active];
    }

    fn focusedSurface(self: *Window) ?*Surface {
        const tab = self.activeTabPtr() orelse return null;
        return tab.focusedPane();
    }
};

/// Drains any pending messages, routing them the same way the main loop
/// does. Used while waiting for the tab strip's first frame, before the
/// real loop has started.
fn pumpOnce(self: *App) void {
    var msg: w32.MSG = undefined;
    while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != w32.FALSE) {
        if (self.pretranslate(&msg)) continue;
        _ = w32.TranslateMessage(&msg);
        _ = w32.DispatchMessageW(&msg);
    }
}

/// Tells every surface in `window` whether it currently has focus.
///
/// Exactly one surface can be focused: the focused pane of the active tab,
/// and then only while the window itself holds OS focus. Everything else is
/// unfocused. Without this the core never learns a surface lost focus, so
/// every pane in every tab keeps blinking its cursor -- including whole
/// windows sitting in the background.
///
/// Idempotent: each surface remembers its last reported state, so this is
/// safe to call on any event that might have moved focus.
fn syncFocus(window: *Window) void {
    const focused = if (window.has_focus) window.focusedSurface() else null;
    for (window.tabs.items) |tab| {
        for (tab.panes.items) |surf| {
            const want = surf == focused;
            if (surf.focused == want) continue;
            surf.focused = want;
            if (!surf.core_ready) continue;
            surf.core_surface.focusCallback(want) catch |err| {
                log.warn("focusCallback failed err={}", .{err});
            };
        }
    }
}

/// One node of a tab's layout: a pane, or a divider with a node on either
/// side of it. Splitting a pane turns its leaf into a split holding the old
/// pane and the new one, so panes nest to any depth.
///
/// A small mutable tree of its own rather than the core's SplitTree, which
/// is immutable and reference-counted for the sake of undo in the other
/// apprts. Nothing here keeps old layouts, and dragging a divider wants to
/// change one ratio in place sixty times a second.
const SplitNode = struct {
    parent: ?*SplitNode = null,
    /// Where this node was last laid out, in the GL window's client
    /// coordinates. For a split that is both children and the divider.
    rect: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    data: Data,

    const Data = union(enum) {
        leaf: *Surface,
        split: Split,
    };

    const Split = struct {
        dir: SplitDir,
        /// The share of the space that goes to `a`.
        ratio: f32 = 0.5,
        /// Left or top.
        a: *SplitNode,
        /// Right or bottom.
        b: *SplitNode,
    };

    fn leafCount(self: *const SplitNode) usize {
        return switch (self.data) {
            .leaf => 1,
            .split => |s| s.a.leafCount() + s.b.leafCount(),
        };
    }

    fn firstLeaf(self: *SplitNode) *Surface {
        return switch (self.data) {
            .leaf => |s| s,
            .split => |s| s.a.firstLeaf(),
        };
    }
};

/// How far a split's ratio may go, so that neither side can be dragged or
/// resized out of existence.
const split_ratio_min: f32 = 0.1;
const split_ratio_max: f32 = 0.9;
/// How close to a divider, in pixels either side, a press still grabs it.
/// The divider itself is too thin to aim at.
const split_grab: i32 = 3;

/// Gives `node` the area `rect` and divides it among whatever is below.
fn layoutNode(node: *SplitNode, rect: w32.RECT) void {
    node.rect = rect;
    switch (node.data) {
        .leaf => |surf| surf.last_rect = rect,
        .split => |s| {
            const half = @divTrunc(split_divider, 2);
            switch (s.dir) {
                .vertical => {
                    const span: f32 = @floatFromInt(rect.right - rect.left);
                    const mid = rect.left + @as(i32, @intFromFloat(span * s.ratio));
                    layoutNode(s.a, .{
                        .left = rect.left,
                        .top = rect.top,
                        .right = @max(rect.left, mid - half),
                        .bottom = rect.bottom,
                    });
                    layoutNode(s.b, .{
                        .left = @min(rect.right, mid + half),
                        .top = rect.top,
                        .right = rect.right,
                        .bottom = rect.bottom,
                    });
                },
                .horizontal => {
                    const span: f32 = @floatFromInt(rect.bottom - rect.top);
                    const mid = rect.top + @as(i32, @intFromFloat(span * s.ratio));
                    layoutNode(s.a, .{
                        .left = rect.left,
                        .top = rect.top,
                        .right = rect.right,
                        .bottom = @max(rect.top, mid - half),
                    });
                    layoutNode(s.b, .{
                        .left = rect.left,
                        .top = @min(rect.bottom, mid + half),
                        .right = rect.right,
                        .bottom = rect.bottom,
                    });
                },
            }
        },
    }
}

/// The split whose divider is at this point, if any.
fn dividerAt(node: *SplitNode, x: i32, y: i32) ?*SplitNode {
    const s = switch (node.data) {
        .leaf => return null,
        .split => |s| s,
    };
    const r = node.rect;
    const hit = switch (s.dir) {
        .vertical => x >= s.a.rect.right - split_grab and
            x < s.b.rect.left + split_grab and
            y >= r.top and y < r.bottom,
        .horizontal => y >= s.a.rect.bottom - split_grab and
            y < s.b.rect.top + split_grab and
            x >= r.left and x < r.right,
    };
    if (hit) return node;
    return dividerAt(s.a, x, y) orelse dividerAt(s.b, x, y);
}

/// Sizes every split by how many panes are on each side of it, which is
/// what makes three panes in a row come out as thirds rather than a half
/// and two quarters.
fn equalizeNode(node: *SplitNode) void {
    switch (node.data) {
        .leaf => {},
        .split => |*s| {
            const a: f32 = @floatFromInt(s.a.leafCount());
            const b: f32 = @floatFromInt(s.b.leafCount());
            s.ratio = a / (a + b);
            equalizeNode(s.a);
            equalizeNode(s.b);
        },
    }
}

fn freeTree(alloc: Allocator, node: *SplitNode) void {
    switch (node.data) {
        .leaf => {},
        .split => |s| {
            freeTree(alloc, s.a);
            freeTree(alloc, s.b);
        },
    }
    alloc.destroy(node);
}

/// Appends the panes below `node` to `out`, left to right and top to
/// bottom, which is the order "next split" walks them in.
fn collectLeaves(node: *SplitNode, out: []*Surface, len: *usize) void {
    switch (node.data) {
        .leaf => |surf| if (len.* < out.len) {
            out[len.*] = surf;
            len.* += 1;
        },
        .split => |s| {
            collectLeaves(s.a, out, len);
            collectLeaves(s.b, out, len);
        },
    }
}

/// One entry in a window's tab strip. Holds one or more panes
/// (CoreSurfaces), arranged by the tree at `root`.
pub const Tab = struct {
    window: *Window,
    /// Every pane in the tab, in the order they were opened. The tree
    /// says where each one is; this is for everything that just needs
    /// all of them.
    panes: std.ArrayListUnmanaged(*Surface) = .empty,
    /// The layout. Null only for a tab with no panes, which is one that is
    /// on its way out.
    root: ?*SplitNode = null,
    /// The pane given the whole tab to itself, if one is zoomed.
    zoomed: ?*Surface = null,
    /// A name the user gave the tab, shown instead of what its shell
    /// reports. Owned.
    title_override: ?[]u8 = null,
    focused: usize = 0,
    /// This tab's identity in the native strip, or 0 when running on the
    /// GDI fallback.
    bar_id: tabbar.TabId = 0,
    /// The shell this tab was opened with, or null when it just ran what
    /// the config says. Names the tab when the shell's own title is not
    /// worth showing, and is what a new tab inherits when
    /// `windows-default-shell` is unset. Borrowed from `window.profiles`,
    /// which outlives every tab in the window.
    profile: ?*const tabbar.Profile = null,

    fn focusedPane(self: *Tab) ?*Surface {
        if (self.focused >= self.panes.items.len) return null;
        return self.panes.items[self.focused];
    }

    fn indexOfPane(self: *Tab, surf: *const Surface) ?usize {
        for (self.panes.items, 0..) |p, i| {
            if (p == surf) return i;
        }
        return null;
    }

    /// Gives every pane its rect within `total`. A zoomed pane takes all
    /// of it and the others get an empty rect, which is what everything
    /// downstream reads as "not on screen": nothing is drawn for it, it is
    /// not resized, and no click can land in it.
    fn layout(self: *Tab, total: w32.RECT) void {
        const root = self.root orelse return;
        if (self.zoomed) |zoomed| {
            for (self.panes.items) |pane| {
                pane.last_rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
            }
            // Kept for when the zoom ends, and so the divider hit-test has
            // nothing to find in the meantime.
            root.rect = total;
            zoomed.last_rect = total;
            return;
        }
        layoutNode(root, total);
    }

    /// The divider under this point, or null -- always null while zoomed,
    /// when there are no dividers on screen.
    fn dividerHit(self: *Tab, x: i32, y: i32) ?*SplitNode {
        if (self.zoomed != null) return null;
        return dividerAt(self.root orelse return null, x, y);
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

/// Callbacks from the native tab strip. Each one carries the *Window as
/// its context and does nothing the keyboard shortcuts don't already do --
/// they funnel into the same switchTab/closeTabAt/newTab used elsewhere,
/// so the strip cannot drift out of sync with the rest of the app.
const bar_callbacks = struct {
    fn window(ctx: ?*anyopaque) ?*Window {
        return @ptrCast(@alignCast(ctx orelse return null));
    }

    fn onSelected(ctx: ?*anyopaque, id: tabbar.TabId) callconv(.c) void {
        const win = window(ctx) orelse return;
        const index = win.tabById(id) orelse return;
        switchTab(win, index);
    }

    fn onCloseRequested(ctx: ?*anyopaque, id: tabbar.TabId) callconv(.c) void {
        const win = window(ctx) orelse return;
        const index = win.tabById(id) orelse return;
        closeTabAt(win, index);
    }

    fn onNewTab(ctx: ?*anyopaque, profile: tabbar.ProfileId) callconv(.c) void {
        const win = window(ctx) orelse return;

        // The dropdown's rows that are commands rather than shells.
        if (profile == tabbar.menu_settings) {
            _ = win.app.performAction(.app, .open_config, .os_open) catch {};
            return;
        }
        if (profile == tabbar.menu_palette) {
            showPalette(win);
            return;
        }

        // Picked with Ctrl held: that shell, elevated, which has to be a
        // process of its own -- a tab cannot have more rights than the
        // window it is in.
        if (profile != tabbar.profile_default and
            profile & tabbar.profile_elevated != 0)
        {
            const id = profile & ~tabbar.profile_elevated;
            for (win.profiles) |*p| {
                if (p.id == id) {
                    launchElevated(win.app, p);
                    break;
                }
            }
            return;
        }

        // The plain "+" sends profile_default, which matches nothing, and
        // then it is newTabProfile's business what a tab opens with.
        const picked: ?*const tabbar.Profile = for (win.profiles) |*p| {
            if (p.id == profile) break p;
        } else newTabProfile(win.app, win);
        _ = win.app.newTab(win, .tab, picked) catch |err| {
            log.warn("failed to create tab err={}", .{err});
        };
    }

    fn onCaptionButton(ctx: ?*anyopaque, button: tabbar.CaptionButton) callconv(.c) void {
        const win = window(ctx) orelse return;
        switch (button) {
            .minimize => _ = w32.ShowWindow(win.hwnd, w32.SW_MINIMIZE),
            .maximize_restore => _ = w32.ShowWindow(
                win.hwnd,
                if (w32.IsZoomed(win.hwnd) != 0) w32.SW_RESTORE else w32.SW_MAXIMIZE,
            ),
            .close => _ = w32.PostMessageW(win.hwnd, w32.WM_CLOSE, 0, 0),
        }
    }

    /// Hand the drag to the system's move loop. The strip is a child HWND
    /// and swallows the mouse, so WM_NCHITTEST on the frame never sees
    /// these points and cannot report HTCAPTION for them.
    ///
    /// The system's move loop gives up at once unless this thread's key
    /// state has the left button down, and here it never does: the press
    /// went to the XAML island, which takes mouse input through its own
    /// input site, so the thread never saw a WM_LBUTTONDOWN. Measured: the
    /// loop saw the button up and returned in 0 ms, so dragging the title
    /// bar did nothing. The button is therefore marked down in the thread's
    /// key state first, but only when it really is down, after which the
    /// loop runs as for a native title bar: until the button is released,
    /// with snapping and the move events window managers listen for.
    ///
    /// Posted, not sent, so that the loop starts once the island has
    /// finished with the press rather than inside its PointerPressed.
    fn onDragStart(ctx: ?*anyopaque) callconv(.c) void {
        const win = window(ctx) orelse return;
        if (w32.GetAsyncKeyState(w32.VK_LBUTTON) < 0) {
            var keys: [256]u8 = undefined;
            if (w32.GetKeyboardState(&keys) != w32.FALSE) {
                keys[w32.VK_LBUTTON] |= 0x80;
                _ = w32.SetKeyboardState(&keys);
            }
        }
        _ = w32.ReleaseCapture();
        _ = w32.PostMessageW(
            win.hwnd,
            w32.WM_SYSCOMMAND,
            w32.SC_MOVE | @as(w32.WPARAM, @intCast(w32.HTCAPTION)),
            0,
        );
    }

    fn onDragDoubleClick(ctx: ?*anyopaque) callconv(.c) void {
        const win = window(ctx) orelse return;
        _ = w32.ShowWindow(
            win.hwnd,
            if (w32.IsZoomed(win.hwnd) != 0) w32.SW_RESTORE else w32.SW_MAXIMIZE,
        );
    }

    /// The strip has already moved the tab; this only brings our list
    /// into the same order.
    fn onTabMoved(ctx: ?*anyopaque, id: tabbar.TabId, index: i32) callconv(.c) void {
        const win = window(ctx) orelse return;
        const from = win.tabById(id) orelse return;
        if (index < 0) return;
        moveTab(win, from, @intCast(index), false);
    }

    fn onOverview(ctx: ?*anyopaque) callconv(.c) void {
        const win = window(ctx) orelse return;
        setOverview(win, !win.overview);
    }

    /// Posted on rather than answered here: the menu runs a message loop
    /// of its own, and this is being called from inside a XAML event.
    fn onTabContext(ctx: ?*anyopaque, id: tabbar.TabId) callconv(.c) void {
        const win = window(ctx) orelse return;
        _ = w32.PostMessageW(win.hwnd, wm_tab_menu, 0, @bitCast(@as(usize, @intCast(id))));
    }
};

/// Posted to a frame window to open the context menu of the tab whose
/// strip id is in lparam.
const wm_tab_menu: w32.UINT = w32.WM_APP + 10;
/// Posted to a frame window by another Ghostty process (`+new-window`) to
/// ask this one for a new window.
const wm_ipc_new_window: w32.UINT = w32.WM_APP + 11;

/// What the input popup is being at the moment.
const InputMode = enum { none, search, palette, rename };

/// UTF-16 from the DLL, as UTF-8 in `buf`. Empty if it does not fit.
fn fromWide(text: [*:0]const u16, buf: []u8) []const u8 {
    const len = std.mem.len(text);
    const n = std.unicode.utf16LeToUtf8(buf, text[0..len]) catch return "";
    return buf[0..n];
}

/// Where the input popup goes: over the top of the terminal area, centred
/// for the palette and the rename prompt, at the right for search, which
/// is where every other program puts its find box.
fn inputPlacement(window: *Window, mode: InputMode) struct { x: i32, y: i32, width: i32 } {
    var r: w32.RECT = undefined;
    _ = w32.GetWindowRect(window.gl_hwnd, &r);
    const avail = r.right - r.left;
    const width = @max(160, @min(avail - 32, @as(i32, switch (mode) {
        .search => 360,
        else => 560,
    })));
    return .{
        .x = switch (mode) {
            .search => r.right - width - 16,
            else => r.left + @divTrunc(avail - width, 2),
        },
        .y = r.top + 10,
        .width = width,
    };
}

const input_callbacks = struct {
    fn window(ctx: ?*anyopaque) ?*Window {
        return @ptrCast(@alignCast(ctx orelse return null));
    }

    fn onText(ctx: ?*anyopaque, text: [*:0]const u16) callconv(.c) void {
        const win = window(ctx) orelse return;
        var buf: [1024]u8 = undefined;
        const utf8 = fromWide(text, &buf);
        switch (win.input_mode) {
            .search => if (win.input_surface) |surf| {
                if (!surf.core_ready) return;
                _ = surf.core_surface.performBindingAction(.{ .search = utf8 }) catch {};
            },
            .palette => fillPalette(win, utf8),
            .rename, .none => {},
        }
    }

    fn onSubmit(ctx: ?*anyopaque, index: i32, text: [*:0]const u16, shift: i32) callconv(.c) void {
        const win = window(ctx) orelse return;
        switch (win.input_mode) {
            // Enter is "next", Shift+Enter "previous"; the box stays up.
            .search => if (win.input_surface) |surf| {
                if (!surf.core_ready) return;
                _ = surf.core_surface.performBindingAction(.{
                    .navigate_search = if (shift != 0) .previous else .next,
                }) catch {};
            },
            .palette => {
                win.input_mode = .none;
                if (index < 0 or index >= win.palette_map.items.len) return;
                const entry = win.palette_map.items[@intCast(index)];
                // Past the core's commands come this apprt's own: one per
                // shell to make it the default, then one to have none.
                if (entry >= input.command.defaults.len) {
                    const shell = entry - input.command.defaults.len;
                    win.app.setDefaultShell(
                        if (shell < win.profiles.len) win.profiles[shell].name else null,
                    );
                    return;
                }
                const command = input.command.defaults[entry];
                const surf = win.focusedSurface() orelse return;
                if (!surf.core_ready) return;
                _ = surf.core_surface.performBindingAction(command.action) catch |err| {
                    log.warn("command failed err={}", .{err});
                };
            },
            .rename => {
                win.input_mode = .none;
                const tab = win.input_tab orelse return;
                win.input_tab = null;
                // The tab may have closed while the prompt was up.
                if (win.indexOfTab(tab) == null) return;
                var buf: [512]u8 = undefined;
                setTabTitleOverride(tab, std.mem.trim(u8, fromWide(text, &buf), " "));
            },
            .none => {},
        }
    }

    fn onCancel(ctx: ?*anyopaque) callconv(.c) void {
        const win = window(ctx) orelse return;
        const mode = win.input_mode;
        win.input_mode = .none;
        win.input_tab = null;
        if (mode == .search) {
            if (win.input_surface) |surf| {
                if (surf.core_ready) {
                    _ = surf.core_surface.performBindingAction(.end_search) catch {};
                }
            }
        }
        win.input_surface = null;
    }
};

fn showInput(
    window: *Window,
    mode: InputMode,
    placeholder: [*:0]const u16,
    text: ?[*:0]const u16,
) bool {
    const bar = window.tab_bar orelse return false;
    setOverview(window, false);
    window.input_mode = mode;
    const at = inputPlacement(window, mode);
    tabbar.ghostty_tabbar_input_show(
        bar,
        at.x,
        at.y,
        at.width,
        placeholder,
        text,
        if (mode == .search) 1 else 0,
        .{
            .ctx = window,
            .on_text = input_callbacks.onText,
            .on_submit = input_callbacks.onSubmit,
            .on_cancel = input_callbacks.onCancel,
        },
    );
    return true;
}

/// Opens the search box on a pane, with `needle` already typed if given.
fn showSearch(surf: *Surface, needle: []const u8) bool {
    const window = surf.tab.window;
    var wide: [512:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wide[0..511], needle) catch 0;
    wide[n] = 0;

    // Already searching this pane: with nothing new to look for there is
    // nothing to do but leave the box where it is.
    if (window.input_mode == .search and window.input_surface == surf and n == 0) {
        return true;
    }

    window.input_surface = surf;
    window.search_total = null;
    window.search_selected = null;
    return showInput(
        window,
        .search,
        std.unicode.utf8ToUtf16LeStringLiteral("Find"),
        wide[0..n :0],
    );
}

/// Puts "3/17" beside the search text, or clears it.
fn syncSearchStatus(window: *Window) void {
    const bar = window.tab_bar orelse return;
    if (window.input_mode != .search) return;
    var buf: [64]u8 = undefined;
    const text: []const u8 = if (window.search_total) |total| blk: {
        if (window.search_selected) |sel| {
            break :blk std.fmt.bufPrint(&buf, "{d}/{d}", .{ sel, total }) catch "";
        }
        break :blk std.fmt.bufPrint(&buf, "{d}", .{total}) catch "";
    } else "";
    var wide: [64:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(wide[0..63], text) catch 0;
    wide[n] = 0;
    tabbar.ghostty_tabbar_input_set_status(bar, wide[0..n :0]);
}

/// Opens the command palette: every command the core offers, narrowed as
/// the user types.
fn showPalette(window: *Window) void {
    if (window.input_mode == .palette) {
        if (window.tab_bar) |bar| tabbar.ghostty_tabbar_input_hide(bar);
        window.input_mode = .none;
        return;
    }
    if (!showInput(
        window,
        .palette,
        std.unicode.utf8ToUtf16LeStringLiteral("Type a command"),
        null,
    )) return;
    fillPalette(window, "");
}

/// True if `haystack` contains `needle`, ignoring ASCII case.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Lists the commands whose title contains `filter`, ignoring case.
fn fillPalette(window: *Window, filter: []const u8) void {
    const bar = window.tab_bar orelse return;
    const alloc = window.app.core_app.alloc;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    window.palette_map.clearRetainingCapacity();
    var items: std.ArrayListUnmanaged(?[*:0]const u16) = .empty;
    for (input.command.defaults, 0..) |command, i| {
        if (filter.len > 0 and
            !containsIgnoreCase(command.title, filter)) continue;
        const wide = std.unicode.utf8ToUtf16LeAllocZ(arena, command.title) catch continue;
        items.append(arena, wide.ptr) catch return;
        window.palette_map.append(alloc, i) catch return;
    }

    // Choosing the default shell, which the core knows nothing about: one
    // entry per shell in the dropdown, the current one marked, and a last
    // one to go back to having none. They are numbered on from the core's
    // commands.
    const current = window.app.config.@"windows-default-shell";
    const base = input.command.defaults.len;
    for (window.profiles, 0..) |p, i| {
        const is_current = if (current) |c| std.ascii.eqlIgnoreCase(c, p.name) else false;
        const title = std.fmt.allocPrint(
            arena,
            "Set Default Shell: {s}{s}",
            .{ p.name, if (is_current) "  (current)" else "" },
        ) catch continue;
        if (filter.len > 0 and !containsIgnoreCase(title, filter)) continue;
        const wide = std.unicode.utf8ToUtf16LeAllocZ(arena, title) catch continue;
        items.append(arena, wide.ptr) catch return;
        window.palette_map.append(alloc, base + i) catch return;
    }
    unset: {
        const title = if (current == null)
            "Set Default Shell: Same as Current Tab  (current)"
        else
            "Set Default Shell: Same as Current Tab";
        if (filter.len > 0 and !containsIgnoreCase(title, filter)) break :unset;
        const wide = std.unicode.utf8ToUtf16LeAllocZ(arena, title) catch break :unset;
        items.append(arena, wide.ptr) catch return;
        window.palette_map.append(alloc, base + window.profiles.len) catch return;
    }

    tabbar.ghostty_tabbar_input_set_items(bar, items.items.ptr, @intCast(items.items.len));
}

/// Asks for a new name for a tab.
fn showRename(tab: *Tab) void {
    const window = tab.window;
    var current: [256:0]u16 = undefined;
    const n = tabTitle(tab, current[0..255]);
    current[n] = 0;
    window.input_tab = tab;
    if (!showInput(
        window,
        .rename,
        std.unicode.utf8ToUtf16LeStringLiteral("Tab name (empty to reset)"),
        current[0..n :0],
    )) window.input_tab = null;
}

/// Gives a tab a fixed name, or with an empty one goes back to showing
/// what its shell reports.
fn setTabTitleOverride(tab: *Tab, title: []const u8) void {
    const alloc = tab.window.app.core_app.alloc;
    if (tab.title_override) |old| alloc.free(old);
    tab.title_override = if (title.len == 0) null else (alloc.dupe(u8, title) catch null);
    syncTabTitle(tab);
    if (tab.window.overview) reflow(tab.window);
}

/// One row of a context menu: its id and its label, or a null label for a
/// separator.
const MenuEntry = struct { u32, ?[]const u8 };

/// Runs a context menu and returns the id picked, or 0.
fn popupMenu(window: *Window, comptime entries: []const MenuEntry) u32 {
    const bar = window.tab_bar orelse return 0;
    const labels = comptime labels: {
        var out: [entries.len]?[*:0]const u16 = undefined;
        for (entries, 0..) |e, i| {
            out[i] = if (e[1]) |text|
                std.unicode.utf8ToUtf16LeStringLiteral(text).ptr
            else
                null;
        }
        const final = out;
        break :labels final;
    };
    const ids = comptime ids: {
        var out: [entries.len]u32 = undefined;
        for (entries, 0..) |e, i| out[i] = e[0];
        const final = out;
        break :ids final;
    };
    return tabbar.ghostty_tabbar_popup_menu(bar, -1, -1, &labels, &ids, entries.len);
}

/// The terminal's right-click menu.
fn showSurfaceMenu(surf: *Surface) void {
    const window = surf.tab.window;
    const picked = popupMenu(window, &.{
        .{ 1, "Copy" },
        .{ 2, "Paste" },
        .{ 3, "Select all" },
        .{ 0, null },
        .{ 4, "Split right" },
        .{ 5, "Split down" },
        .{ 6, "New tab" },
        .{ 0, null },
        .{ 7, "Find..." },
        .{ 8, "Command palette" },
        .{ 0, null },
        .{ 9, "Close pane" },
    });
    // The pane can have closed while the menu was up: its shell exiting
    // does not wait for a menu.
    if (surf.tab.window != window or surf.tab.indexOfPane(surf) == null) return;
    if (!surf.core_ready) return;
    const action: input.Binding.Action = switch (picked) {
        1 => .{ .copy_to_clipboard = .mixed },
        2 => .paste_from_clipboard,
        3 => .select_all,
        4 => .{ .new_split = .right },
        5 => .{ .new_split = .down },
        6 => .new_tab,
        7 => .start_search,
        8 => .toggle_command_palette,
        9 => .close_surface,
        else => return,
    };
    _ = surf.core_surface.performBindingAction(action) catch |err| {
        log.warn("menu action failed err={}", .{err});
    };
}

/// A tab's right-click menu.
fn showTabMenu(window: *Window, id: tabbar.TabId) void {
    const picked = popupMenu(window, &.{
        .{ 1, "Rename tab..." },
        .{ 2, "Move to new window" },
        .{ 0, null },
        .{ 3, "Close tab" },
        .{ 4, "Close other tabs" },
        .{ 5, "Close tabs to the right" },
    });
    // Found again after the menu, which is the only moment its index is
    // known to be current.
    const index = window.tabById(id) orelse return;
    const tab = window.tabs.items[index];
    switch (picked) {
        1 => showRename(tab),
        2 => moveTabToNewWindow(window.app, tab) catch |err| {
            log.warn("failed to move tab err={}", .{err});
        },
        3 => closeTabAt(window, index),
        4 => {
            var i = window.tabs.items.len;
            while (i > 0) {
                i -= 1;
                if (window.tabs.items[i] != tab) closeTabAt(window, i);
            }
        },
        5 => {
            var i = window.tabs.items.len;
            while (i > index + 1) {
                i -= 1;
                closeTabAt(window, i);
            }
        },
        else => {},
    }
}

/// Takes a tab out of its window and gives it a window of its own. The
/// panes keep running: only what draws them changes.
fn moveTabToNewWindow(self: *App, tab: *Tab) !void {
    const old = tab.window;
    // A window's only tab is already in a window of its own.
    if (old.tabs.items.len < 2) return;
    const index = old.indexOfTab(tab) orelse return;

    setOverview(old, false);
    if (old.tab_bar) |bar| {
        if (tab.bar_id != 0) tabbar.ghostty_tabbar_remove_tab(bar, tab.bar_id);
    }
    tab.bar_id = 0;
    _ = old.tabs.orderedRemove(index);
    if (old.active >= old.tabs.items.len) old.active = old.tabs.items.len - 1;
    if (old.input_tab == tab) old.input_tab = null;
    for (tab.panes.items) |pane| {
        if (old.input_surface == pane) old.input_surface = null;
    }
    old.drag_split = null;
    if (old.tab_bar) |bar| {
        const now = old.tabs.items[old.active];
        if (now.bar_id != 0) tabbar.ghostty_tabbar_set_selected(bar, now.bar_id);
    }
    reflow(old);
    invalidateTabBar(old);

    _ = self.newWindow(tab) catch |err| {
        // Nowhere to put it: back where it came from.
        try old.tabs.insert(self.core_app.alloc, @min(index, old.tabs.items.len), tab);
        attachTab(self, old, tab);
        return err;
    };
}

/// Makes `tab` a tab of `window`: its strip entry, its icon, its selection.
/// The tab must already be in `window.tabs`.
fn attachTab(self: *App, window: *Window, tab: *Tab) void {
    tab.window = window;
    // A profile pointer is borrowed from the window's list, and this may
    // be a different window. The lists are detected the same way, so the
    // same name is the same shell.
    if (tab.profile) |p| {
        tab.profile = for (window.profiles) |*mine| {
            if (std.mem.eql(u8, mine.name, p.name)) break mine;
        } else null;
    }
    if (window.indexOfTab(tab)) |i| window.active = i;
    if (window.tab_bar) |bar| {
        const title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
        tab.bar_id = tabbar.ghostty_tabbar_add_tab(bar, title);
        if (tab.bar_id != 0) {
            setTabIcon(self, window, tab, tab.profile);
            tabbar.ghostty_tabbar_set_selected(bar, tab.bar_id);
        }
    }
    reflow(window);
    invalidateTabBar(window);
}

/// Starts another Ghostty, elevated, running `profile`. Windows asks the
/// user to approve it.
fn launchElevated(self: *App, profile: *const tabbar.Profile) void {
    const alloc = self.core_app.alloc;
    var exe: [1024:0]u16 = undefined;
    const exe_len = w32.GetModuleFileNameW(null, &exe, exe.len);
    if (exe_len == 0 or exe_len >= exe.len) return;

    // `-e` and then the command, each argument quoted so a path with
    // spaces stays one argument.
    var params: std.ArrayListUnmanaged(u8) = .empty;
    defer params.deinit(alloc);
    params.appendSlice(alloc, "-e") catch return;
    for (profile.argv) |arg| {
        params.appendSlice(alloc, " \"") catch return;
        params.appendSlice(alloc, arg) catch return;
        params.append(alloc, '"') catch return;
    }
    const wparams = std.unicode.utf8ToUtf16LeAllocZ(alloc, params.items) catch return;
    defer alloc.free(wparams);

    _ = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("runas"),
        exe[0..exe_len :0].ptr,
        wparams.ptr,
        null,
        w32.SW_SHOWNORMAL,
    );
}

/// The window an action is aimed at, or null for one aimed at the app.
fn targetWindow(target: apprt.Target) ?*Window {
    return switch (target) {
        .app => null,
        .surface => |core| core.rt_surface.tab.window,
    };
}

/// Moves the tab at `from` to `to`. `tell_strip` is false when the strip is
/// what did the moving and is only reporting it.
fn moveTab(window: *Window, from: usize, to_: usize, tell_strip: bool) void {
    const count = window.tabs.items.len;
    if (from >= count) return;
    const to = @min(to_, count - 1);
    if (from == to) return;

    // The active tab is tracked by position, and positions are about to
    // shift under it.
    const active = window.activeTabPtr();
    const tab = window.tabs.orderedRemove(from);
    // Cannot fail: the list just gave up the slot this takes.
    window.tabs.insertAssumeCapacity(to, tab);
    if (active) |a| {
        if (window.indexOfTab(a)) |i| window.active = i;
    }

    if (tell_strip) if (window.tab_bar) |bar| {
        if (tab.bar_id != 0) {
            tabbar.ghostty_tabbar_move_tab(bar, tab.bar_id, @intCast(to));
        }
    };
    invalidateTabBar(window);
    if (window.overview) reflow(window);
}

/// Opens a file or URL with whatever the shell has registered for it, or
/// `file` as a program given `param`.
fn shellOpen(alloc: Allocator, file: []const u8, param: ?[]const u8) void {
    const wfile = std.unicode.utf8ToUtf16LeAllocZ(alloc, file) catch return;
    defer alloc.free(wfile);
    const wparam: ?[:0]u16 = if (param) |p|
        (std.unicode.utf8ToUtf16LeAllocZ(alloc, p) catch return)
    else
        null;
    defer if (wparam) |p| alloc.free(p);

    _ = w32.ShellExecuteW(
        null,
        std.unicode.utf8ToUtf16LeStringLiteral("open"),
        wfile.ptr,
        if (wparam) |p| p.ptr else null,
        null,
        w32.SW_SHOWNORMAL,
    );
}

/// True for the schemes that are safe to hand to the shell whatever the
/// text came from: they open a browser or a mail client, never a program.
fn isWebUrl(url: []const u8) bool {
    for ([_][]const u8{ "http://", "https://", "mailto:" }) |scheme| {
        if (url.len >= scheme.len and
            std.ascii.eqlIgnoreCase(url[0..scheme.len], scheme)) return true;
    }
    return false;
}

fn openUrl(self: *App, value: apprt.action.OpenUrl) void {
    // Text matched in terminal output and OSC 8 links are whatever the
    // program on the other end wants them to be. ShellExecute "opens" an
    // .exe by running it and a .lnk by following it, so for those only a
    // web address goes through; a path a program printed does not get to
    // be launched by a click. What Ghostty itself asks to open -- its own
    // config, a file it wrote -- is trusted.
    const trusted = switch (value.kind) {
        .text, .html => true,
        else => false,
    };
    if (!trusted and !isWebUrl(value.url)) {
        log.info("not opening untrusted non-web link", .{});
        return;
    }
    shellOpen(self.core_app.alloc, value.url, null);
}

/// Gives the window its title bar and tab strip, or takes them away.
fn setDecorated(window: *Window, on: bool) void {
    if (window.decorated == on) return;
    window.decorated = on;
    refreshFrame(window);
}

/// Has Windows ask for the frame again (WM_NCCALCSIZE) and lays the strip
/// and the terminal out for it, after something `customFrame` or
/// `stripShown` depend on changed. Fullscreen sets its own frame and puts
/// this one back when it ends.
fn refreshFrame(window: *Window) void {
    if (window.fullscreen) return;
    const flags = w32.SWP_NOMOVE | w32.SWP_NOSIZE | w32.SWP_NOZORDER |
        w32.SWP_NOACTIVATE | w32.SWP_FRAMECHANGED;
    _ = w32.SetWindowPos(window.hwnd, null, 0, 0, 0, 0, flags);
    // The client area may keep its size (the strip only moves out of the
    // way), and then no WM_SIZE comes: send one so the terminal grows into
    // the strip's space or gives it back.
    var rect: w32.RECT = undefined;
    if (w32.GetClientRect(window.hwnd, &rect) != w32.FALSE) {
        const kind: w32.WPARAM = if (w32.IsZoomed(window.hwnd) != 0) w32.SIZE_MAXIMIZED else 0;
        const size: u32 = (@as(u32, @intCast(@max(0, rect.bottom))) << 16) |
            @as(u32, @intCast(@max(0, rect.right) & 0xFFFF));
        _ = w32.SendMessageW(window.hwnd, w32.WM_SIZE, kind, @intCast(size));
    }
    if (!window.customFrame()) applyTitlebarTheme(window.hwnd, &window.app.config);
    reflow(window);
}

/// Puts the window into fullscreen or takes it back out.
fn setFullscreen(window: *Window, on: bool) void {
    if (window.fullscreen == on) return;
    const hwnd = window.hwnd;

    if (on) {
        const monitor = w32.MonitorFromWindow(hwnd, w32.MONITOR_DEFAULTTONEAREST) orelse return;
        var info: w32.MONITORINFO = .{};
        if (w32.GetMonitorInfoW(monitor, &info) == w32.FALSE) return;

        window.saved_style = w32.GetWindowLongPtrW(hwnd, w32.GWL_STYLE);
        _ = w32.GetWindowRect(hwnd, &window.saved_rect);
        window.fullscreen = true;

        // A popup has no caption and no sizing border, so the client area
        // is the whole window and the window can be exactly the monitor.
        const overlapped: isize = @intCast(w32.WS_OVERLAPPEDWINDOW);
        const popup: isize = @bitCast(@as(usize, w32.WS_POPUP));
        _ = w32.SetWindowLongPtrW(
            hwnd,
            w32.GWL_STYLE,
            (window.saved_style & ~overlapped) | popup,
        );
        const r = info.rcMonitor;
        _ = w32.SetWindowPos(
            hwnd,
            null,
            r.left,
            r.top,
            r.right - r.left,
            r.bottom - r.top,
            w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED,
        );
    } else {
        window.fullscreen = false;
        _ = w32.SetWindowLongPtrW(hwnd, w32.GWL_STYLE, window.saved_style);
        const r = window.saved_rect;
        _ = w32.SetWindowPos(
            hwnd,
            null,
            r.left,
            r.top,
            r.right - r.left,
            r.bottom - r.top,
            w32.SWP_NOZORDER | w32.SWP_FRAMECHANGED,
        );
    }
}

/// Moves focus to another pane of the same tab.
fn gotoSplit(surf: *Surface, to: apprt.action.GotoSplit) bool {
    const tab = surf.tab;
    const root = tab.root orelse return false;
    if (tab.panes.items.len < 2) return false;

    // Directions are judged from where the panes are on screen, and a
    // zoomed tab has only one of them on screen. Leaving the zoom is what
    // moving to another pane means anyway.
    if (tab.zoomed != null) {
        tab.zoomed = null;
        layoutNode(root, root.rect);
    }

    const target: *Surface = switch (to) {
        .previous, .next => target: {
            var buf: [128]*Surface = undefined;
            var len: usize = 0;
            collectLeaves(root, &buf, &len);
            const at = std.mem.indexOfScalar(*Surface, buf[0..len], surf) orelse return false;
            break :target switch (to) {
                .previous => buf[(at + len - 1) % len],
                else => buf[(at + 1) % len],
            };
        },
        .up, .down, .left, .right => neighbour(tab, surf, to) orelse return false,
    };

    tab.focused = tab.indexOfPane(target) orelse return false;
    reflow(tab.window);
    return true;
}

/// The pane nearest to `surf` in a direction: the closest one that starts
/// beyond that edge and shares some of its extent along it. Among equally
/// close ones, the one sharing the most.
fn neighbour(tab: *Tab, surf: *Surface, to: apprt.action.GotoSplit) ?*Surface {
    const cur = surf.last_rect;
    var best: ?*Surface = null;
    var best_score: i64 = std.math.maxInt(i64);

    for (tab.panes.items) |pane| {
        if (pane == surf) continue;
        const r = pane.last_rect;
        if (r.right <= r.left or r.bottom <= r.top) continue;

        const distance: i32 = switch (to) {
            .right => r.left - cur.right,
            .left => cur.left - r.right,
            .down => r.top - cur.bottom,
            .up => cur.top - r.bottom,
            else => unreachable,
        };
        if (distance < 0) continue;

        const overlap: i32 = switch (to) {
            .left, .right => @min(r.bottom, cur.bottom) - @max(r.top, cur.top),
            else => @min(r.right, cur.right) - @max(r.left, cur.left),
        };
        if (overlap <= 0) continue;

        const score = @as(i64, distance) * 100_000 - overlap;
        if (score < best_score) {
            best_score = score;
            best = pane;
        }
    }
    return best;
}

/// Moves the nearest divider of the right orientation by `amount` pixels.
fn resizeSplit(surf: *Surface, value: apprt.action.ResizeSplit) bool {
    const tab = surf.tab;
    const want: SplitDir = switch (value.direction) {
        .left, .right => .vertical,
        .up, .down => .horizontal,
    };

    // The nearest enclosing split that divides along the right axis: in a
    // column of panes beside another pane, "left" has to find the divider
    // between the column and its neighbour, not one inside the column.
    var node = surf.node orelse return false;
    const split_node: *SplitNode = while (node.parent) |parent| : (node = parent) {
        if (parent.data.split.dir == want) break parent;
    } else return false;

    const r = split_node.rect;
    const extent: f32 = @floatFromInt(switch (want) {
        .vertical => r.right - r.left,
        .horizontal => r.bottom - r.top,
    });
    if (extent <= 0) return false;

    const amount: f32 = @floatFromInt(value.amount);
    const delta = switch (value.direction) {
        .left, .up => -amount / extent,
        .right, .down => amount / extent,
    };
    const s = &split_node.data.split;
    s.ratio = std.math.clamp(s.ratio + delta, split_ratio_min, split_ratio_max);

    tab.zoomed = null;
    reflow(tab.window);
    return true;
}

/// Finds the shells this machine has, which is what the new-tab dropdown
/// offers and what `windows-default-shell` names.
///
/// Kept out of initTabBar because the list is not the strip's: detection is
/// plain Win32 and registry work, and `windows-default-shell` has to keep
/// working on the GDI fallback, where no strip exists to have a dropdown.
fn detectProfiles(self: *App, window: *Window) void {
    window.profiles = tabbar.detectProfiles(
        self.core_app.alloc,
        self.config.@"windows-profile".list.items,
    ) catch |err| blk: {
        log.warn("shell detection failed err={}", .{err});
        break :blk &.{};
    };
}

/// Brings up the native tab strip for `window`, leaving `tab_bar` null if
/// it can't be created (see the field's doc comment).
fn initTabBar(window: *Window) void {
    const bar = tabbar.ghostty_tabbar_create(@ptrCast(window.hwnd), .{
        .ctx = window,
        .on_selected = bar_callbacks.onSelected,
        .on_close_requested = bar_callbacks.onCloseRequested,
        .on_new_tab = bar_callbacks.onNewTab,
        .on_caption_button = bar_callbacks.onCaptionButton,
        .on_drag_start = bar_callbacks.onDragStart,
        .on_drag_double_click = bar_callbacks.onDragDoubleClick,
        .on_tab_moved = bar_callbacks.onTabMoved,
        .on_overview = bar_callbacks.onOverview,
        .on_tab_context = bar_callbacks.onTabContext,
    }) orelse {
        log.info(
            "native tab strip unavailable, using the GDI strip " ++
                "(WinUI needs an MSIX-packaged build)",
            .{},
        );
        return;
    };
    window.tab_bar = bar;

    for (window.profiles) |p| {
        var buf: [256:0]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(buf[0..255], p.name) catch continue;
        buf[n] = 0;

        var icon_buf: [512:0]u16 = undefined;
        const icon: ?[*:0]const u16 = if (p.icon.len == 0) null else icon: {
            const in = std.unicode.utf8ToUtf16Le(icon_buf[0..511], p.icon) catch
                break :icon null;
            icon_buf[in] = 0;
            break :icon icon_buf[0..in :0].ptr;
        };
        tabbar.ghostty_tabbar_add_profile(bar, p.id, buf[0..n :0], icon);
    }

    applyTabBarTheme(window);

    // The strip only becomes the title bar once it actually exists, so the
    // frame style has to be recomputed here rather than at creation.
    _ = w32.SetWindowPos(
        window.hwnd,
        null,
        0,
        0,
        0,
        0,
        w32.SWP_FRAMECHANGED | w32.SWP_NOMOVE | w32.SWP_NOSIZE |
            w32.SWP_NOZORDER | w32.SWP_NOACTIVATE,
    );
}

/// Matches the strip to the configured theme, picking light or dark chrome
/// from the background's perceived luminance.
fn applyTabBarTheme(window: *Window) void {
    const bar = window.tab_bar orelse return;
    const bg = window.app.config.background;
    const luminance =
        (@as(u32, bg.r) * 299 + @as(u32, bg.g) * 587 + @as(u32, bg.b) * 114) / 1000;
    tabbar.ghostty_tabbar_set_theme(bar, bg.r, bg.g, bg.b, if (luminance < 128) 1 else 0);
}

/// True if a shell-reported title is just the path of the executable
/// running in it.
///
/// cmd.exe and powershell.exe both set their title to their own full path
/// and never update it, so honouring it fills the strip with
/// "C:\WINDOWS\system32\cmd.exe". Windows Terminal shows the profile name
/// for exactly these and the reported title for everything else -- WSL
/// shells and nushell report their working directory, which is worth
/// showing. Rather than special-casing those two shells, this rejects any
/// title that looks like a Windows executable path, which is the property
/// that actually makes a title useless.
fn titleIsExePath(title: []const u8) bool {
    if (!std.mem.endsWith(u8, title, ".exe")) return false;
    // A drive letter or a UNC prefix; anything else is a shell that
    // happens to be showing a bare program name, which is fine to show.
    if (std.mem.startsWith(u8, title, "\\\\")) return true;
    return title.len >= 3 and title[1] == ':' and title[2] == '\\';
}

/// Whether `title` is just the file name of the program `profile` runs,
/// such as "wsl.exe" for a WSL distribution's profile.
fn titleIsProfileProgram(profile: ?*const tabbar.Profile, title: []const u8) bool {
    const p = profile orelse return false;
    if (p.argv.len == 0) return false;
    return std.ascii.eqlIgnoreCase(fileName(p.argv[0]), title);
}

/// Finds a detected profile whose executable matches `exe_path`, so a tab
/// that was not opened from the dropdown -- the window's first tab, or one
/// from the plain "+" -- still gets a readable name instead of a path.
fn profileNameForExe(window: *Window, exe_path: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(exe_path);
    if (base.len == 0) return null;
    for (window.profiles) |p| {
        if (p.argv.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(std.fs.path.basename(p.argv[0]), base)) {
            return p.name;
        }
    }
    return null;
}

/// Pushes a tab's current title into the native strip.
fn syncTabTitle(tab: *Tab) void {
    const window = tab.window;
    const bar = window.tab_bar orelse return;
    if (tab.bar_id == 0) return;

    var buf: [513:0]u16 = undefined;
    const n = tabTitle(tab, buf[0..512]);
    buf[n] = 0;
    tabbar.ghostty_tabbar_set_title(bar, tab.bar_id, buf[0..n :0]);
}

fn newWindow(self: *App, adopt: ?*Tab) !*Window {
    const alloc = self.core_app.alloc;
    const window = try alloc.create(Window);
    errdefer alloc.destroy(window);
    window.* = .{
        .app = self,
        .hwnd = undefined,
        .gl_hwnd = undefined,
        .hdc = undefined,
        .hglrc = undefined,
        .decorated = self.config.@"window-decoration" != .none,
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

    // Before the strip, which fills its dropdown from this, and before the
    // first tab, which may be opened into one of these by
    // `windows-default-shell`.
    self.detectProfiles(window);

    // Before the first tab exists, so the strip is ready to receive it and
    // so the frame style is settled before the window is shown.
    initTabBar(window);

    var client_rect: w32.RECT = undefined;
    _ = w32.GetClientRect(hwnd, &client_rect);

    const gl_hwnd = w32.CreateWindowExW(
        0,
        gl_class_name,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        // Clipped against its siblings so that the overview's captions,
        // which sit on top of it, are not painted over by every swap.
        w32.WS_CHILD | w32.WS_VISIBLE | w32.WS_CLIPSIBLINGS,
        0,
        window.shownStripHeight(),
        client_rect.right - client_rect.left,
        @max(0, (client_rect.bottom - client_rect.top) - window.shownStripHeight()),
        hwnd,
        null,
        self.hinstance,
        window,
    ) orelse return error.Unexpected;
    window.gl_hwnd = gl_hwnd;
    // Dropping files on the terminal types their paths.
    w32.DragAcceptFiles(gl_hwnd, w32.TRUE);
    try self.windows.append(alloc, window);

    const hdc = w32.GetDC(gl_hwnd) orelse return error.Unexpected;
    window.hdc = hdc;

    // The renderers' pixel format, which sharing with them requires.
    try wgl.setPixelFormat(@ptrCast(hdc));

    const hglrc = w32.wglCreateContext(hdc) orelse return error.Unexpected;
    window.hglrc = hglrc;
    // Before the context has any objects of its own, as it must be.
    try wgl.share(self.gl_root.hglrc, @ptrCast(hglrc));
    if (w32.wglMakeCurrent(hdc, hglrc) == w32.FALSE) return error.Unexpected;

    if (!self.gl_loaded) {
        _ = try wgl.loadGlad();
        self.gl_loaded = true;
    }
    window.read_fbo = try gl.Framebuffer.create();

    if (adopt) |tab| {
        // A tab moved out of another window: it arrives with its panes
        // running, so there is nothing to start, only somewhere to draw.
        try window.tabs.append(alloc, tab);
        attachTab(self, window, tab);
    } else {
        _ = try self.newTab(window, .window, firstTabProfile(self, window));
    }

    // Show off-screen first, let the strip compose, then bring the window
    // to where it belongs.
    //
    // A XAML island paints white until it has a frame to present, so
    // showing the window straight away puts a white title bar on screen
    // for a few hundred milliseconds before the theme snaps in. Waiting
    // while hidden is not an option: XAML does not compose at all for a
    // hidden window, so the wait would never end. Off-screen is visible as
    // far as XAML is concerned and invisible as far as the user is.
    if (window.tab_bar) |bar| {
        var rect: w32.RECT = undefined;
        if (w32.GetWindowRect(hwnd, &rect) != w32.FALSE) {
            const flags = w32.SWP_NOSIZE | w32.SWP_NOZORDER | w32.SWP_NOACTIVATE;
            _ = w32.SetWindowPos(hwnd, null, -32000, -32000, 0, 0, flags);
            _ = w32.ShowWindow(hwnd, w32.SW_SHOWNOACTIVATE);

            // Bounded: a strip that never reports a frame must not keep
            // the window off-screen forever.
            var waited: u32 = 0;
            while (tabbar.ghostty_tabbar_rendered(bar) == 0 and waited < 1000) {
                pumpOnce(self);
                w32.Sleep(4);
                waited += 4;
            }

            // And the terminal area, for the same reason as the strip: a
            // GL window that has never swapped is white. The panes are not
            // started yet, so this draws their background and nothing else.
            reflow(window);

            _ = w32.SetWindowPos(hwnd, null, rect.left, rect.top, 0, 0, flags);
        }
    }

    _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
    _ = w32.UpdateWindow(hwnd);
    _ = w32.SetFocus(gl_hwnd);

    // The window is on screen and has been through everything that resizes
    // it on the way there, so panes may now be started at the size they
    // will keep. Drain what is queued first: the geometry a shell-launched
    // packaged build is restored to arrives as a posted resize, and taking
    // it now is the difference between starting the shell at the right size
    // and starting it at the size the window merely opened with.
    pumpOnce(self);
    window.settled = true;
    reflow(window);
    // Only meaningful on the GDI fallback: with the native strip there is
    // no system title bar left to theme.
    if (!window.customFrame()) applyTitlebarTheme(hwnd, &self.config);

    return window;
}

/// Allocates a pane, but does not start it: the CoreSurface (and with it
/// the pty and the shell) is created later by `startPane`, once `reflow`
/// has given the pane the rect it will actually keep. See `Surface.Pending`
/// for why that has to wait.
fn newPane(
    self: *App,
    tab: *Tab,
    context: apprt.surface.NewSurfaceContext,
    /// Overrides the configured command for this surface only. Used by the
    /// new-tab dropdown, where each entry is a different shell.
    argv: ?[]const []const u8,
) !*Surface {
    const alloc = self.core_app.alloc;
    const surf = try alloc.create(Surface);
    errdefer alloc.destroy(surf);
    surf.* = .{
        .tab = tab,
        .core_surface = undefined,
        .core_ready = false,
        .pending = .{ .context = context, .argv = argv, .handoff = self.pending_handoff },
        .title_buf = undefined,
        .title_len = 0,
        .cursor_pos = .{ .x = 0, .y = 0 },
        .last_rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    };

    // Its place in the layout. Detached for now: whoever asked for the
    // pane decides whether it is a tab's root or one side of a split.
    const node = try alloc.create(SplitNode);
    node.* = .{ .data = .{ .leaf = surf } };
    surf.node = node;

    // The pane owns it now.
    self.pending_handoff = null;
    return surf;
}

/// Starts a pane's core at whatever size `last_rect` currently says, which
/// is the size the pty is created with. Only `reflow` calls this, so that
/// size is always one it just computed. Does nothing for a pane that is
/// already running, or for one whose start already failed.
fn startPane(self: *App, surf: *Surface) !void {
    const pending = surf.pending orelse return;
    const alloc = self.core_app.alloc;

    // Consume the pending start *before* bringing the core up, not after.
    //
    // CoreSurface.init performs actions as it goes, and this apprt answers
    // several of them by calling reflow -- set_title does, and a tab opened
    // from the shell dropdown always fires one, because a `direct` command
    // titles the surface after its argv[0]. That reflow re-enters this
    // function for a pane whose init is still in flight, and starting it a
    // second time on top of itself gave the window two IO threads and two
    // renderer threads over one surface. It took the process down a few
    // seconds later, which is why it read as "picking a shell closes
    // Ghostty" rather than as a crash at the click.
    //
    // Clearing it here makes the token a one-shot: a reentrant reflow sees
    // nothing pending and skips the pane, which is not yet drawable anyway.
    surf.pending = null;

    try self.core_app.addSurface(surf);
    errdefer self.core_app.deleteSurface(surf);

    var config = try apprt.surface.newConfig(
        self.core_app,
        &self.config,
        pending.context,
    );
    defer config.deinit();

    // The strings are copied into the config's arena because `argv` is
    // owned by the window's profile list, which outlives this call but is
    // not what the config's lifetime is tied to. `.direct` rather than
    // `.shell` so paths with spaces ("C:\Program Files\Git\...") survive:
    // the shell form is split on whitespace on Windows.
    if (pending.argv) |a| if (a.len > 0) {
        const arena = config._arena.?.allocator();
        const owned = try arena.alloc([:0]const u8, a.len);
        for (a, owned) |src, *dst| dst.* = try arena.dupeSentinel(u8, src, 0);
        config.command = .{ .direct = owned };
    };

    // A handed-off console session: the core's exec backend takes it in
    // place of starting the configured command (termio.Exec.WindowsHandoff).
    termio.Exec.windows_handoff = pending.handoff;
    defer if (termio.Exec.windows_handoff) |left| {
        // The core failed before it took it.
        termio.Exec.windows_handoff = null;
        var dropped = left;
        dropped.pty.deinit();
        _ = internal_os.windows.exp.kernel32.CloseHandle(left.client);
    };

    try CoreSurface.init(
        &surf.core_surface,
        alloc,
        &config,
        self.core_app,
        self,
        surf,
    );
    surf.core_ready = true;

    // syncFocus runs while the pane is still pending and records the state
    // it could not deliver, so hand it over now. The core assumes it is
    // focused until told otherwise, which is wrong for the pane that isn't.
    surf.core_surface.focusCallback(surf.focused) catch |err| {
        log.warn("focusCallback failed err={}", .{err});
    };
}

/// The shell a new terminal opens with when the user did not name one --
/// the "+" button, the new-tab binding, a split, and the first window.
///
/// `windows-default-shell` wins when it is set: the whole point of naming a
/// shell is that Ghostty opens it, and a tab opened from the dropdown is
/// the way to ask for something else. With nothing configured the new tab
/// follows whatever is in focus, so splitting or duplicating a PowerShell
/// tab does not drop the user back into cmd.
///
/// Null means "leave the configured command alone", which is what a fresh
/// install gets.
fn newTabProfile(self: *App, window: *Window) ?*const tabbar.Profile {
    if (configuredProfile(self, window)) |p| return p;
    const tab = window.activeTabPtr() orelse return null;
    return tab.profile;
}

/// Resolves `windows-default-shell` against the shells actually found on
/// this machine. Null when unset, or when it names one that isn't here --
/// a config that cannot be honoured should not stop a window from opening.
fn configuredProfile(self: *App, window: *Window) ?*const tabbar.Profile {
    const want = self.config.@"windows-default-shell" orelse return null;
    if (want.len == 0) return null;

    for (window.profiles) |*p| {
        if (std.ascii.eqlIgnoreCase(p.name, want)) return p;
    }

    // Fall back to the executable, so `pwsh` and `pwsh.exe` reach
    // "PowerShell 7" without the user having to know the display name.
    for (window.profiles) |*p| {
        if (p.argv.len == 0) continue;
        const exe = fileName(p.argv[0]);
        if (std.ascii.eqlIgnoreCase(exe, want)) return p;
        if (exe.len > 4 and std.ascii.eqlIgnoreCase(exe[exe.len - 4 ..], ".exe") and
            std.ascii.eqlIgnoreCase(exe[0 .. exe.len - 4], want))
        {
            return p;
        }
    }

    log.warn(
        "windows-default-shell={s} matches no shell found on this machine, ignoring",
        .{want},
    );
    return null;
}

/// Gives a tab the icon of the shell it is running, which is how Windows
/// Terminal makes a row of tabs readable at a glance. Best-effort: a tab
/// whose shell we cannot put a face to simply shows none, and the strip
/// collapses the icon column for it.
fn setTabIcon(
    self: *App,
    window: *Window,
    tab: *Tab,
    profile: ?*const tabbar.Profile,
) void {
    const bar = window.tab_bar orelse return;
    const path = if (profile) |p| p.icon else defaultIconPath(self, window);
    if (path.len == 0) return;

    var buf: [512:0]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(buf[0..511], path) catch return;
    buf[n] = 0;
    tabbar.ghostty_tabbar_set_tab_icon(bar, tab.bar_id, buf[0..n :0].ptr);
}

/// The icon for a tab opened without a profile -- the first tab, and the
/// plain "+" -- which runs whatever the config's `command` says.
///
/// Answered by matching that command against the detected profiles rather
/// than resolving it again: they already carry an absolute path, and
/// SHGetFileInfo needs one. A bare "cmd.exe" yields the generic
/// unknown-file icon, which is worse than no icon at all.
fn defaultIconPath(self: *App, window: *Window) []const u8 {
    // What Ghostty falls back to on Windows when nothing is configured.
    var argv0: []const u8 = "cmd.exe";
    if (self.config.command) |cmd| argv0 = switch (cmd) {
        .direct => |a| if (a.len > 0) a[0] else return "",
        // A shell command is one string for the shell to expand, so the
        // executable is its first word -- which is also how this apprt
        // splits it when it runs it.
        .shell => |s| std.mem.sliceTo(s, ' '),
    };

    for (window.profiles) |p| {
        if (p.argv.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(fileName(p.argv[0]), fileName(argv0))) {
            return p.icon;
        }
    }
    return "";
}

/// The file name part of a path. What identifies a shell across the two
/// forms in play here: the config may name it bare ("cmd.exe") where the
/// profile carries the absolute path it resolved to.
fn fileName(path: []const u8) []const u8 {
    const i = std.mem.lastIndexOfAny(u8, path, "\\/") orelse return path;
    return path[i + 1 ..];
}

fn newTab(
    self: *App,
    window: *Window,
    context: apprt.surface.NewSurfaceContext,
    /// The profile this tab was opened from, or null to use the
    /// configured command. Supplies both the command and the name the
    /// strip falls back to.
    profile: ?*const tabbar.Profile,
) !*Surface {
    const alloc = self.core_app.alloc;
    const tab = try alloc.create(Tab);
    errdefer alloc.destroy(tab);
    tab.* = .{
        .window = window,
        .profile = profile,
    };

    const surf = try self.newPane(
        tab,
        context,
        if (profile) |p| p.argv else null,
    );
    errdefer {
        self.core_app.deleteSurface(surf);
        if (surf.core_ready) surf.core_surface.deinit();
        if (surf.node) |node| alloc.destroy(node);
        alloc.destroy(surf);
    }
    try tab.panes.append(alloc, surf);
    tab.root = surf.node;

    // A new tab is something to look at, not something to find among
    // thumbnails.
    setOverview(window, false);

    try window.tabs.append(alloc, tab);
    window.active = window.tabs.items.len - 1;

    if (window.tab_bar) |bar| {
        const title = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
        tab.bar_id = tabbar.ghostty_tabbar_add_tab(bar, title);
        if (tab.bar_id != 0) {
            // A handed-off program is not the configured command, whose
            // icon this would be.
            const handed_off = if (surf.pending) |p| p.handoff != null else false;
            if (!handed_off) setTabIcon(self, window, tab, profile);
            tabbar.ghostty_tabbar_set_selected(bar, tab.bar_id);
        }
    }

    reflow(window);
    invalidateTabBar(window);

    return surf;
}

/// Splits `pane` in two, giving half of its space to a new pane. `before`
/// puts the new pane on the left or top rather than the right or bottom.
fn newSplit(self: *App, pane: *Surface, dir: SplitDir, before: bool) !*Surface {
    const tab = pane.tab;
    const window = tab.window;
    const alloc = self.core_app.alloc;
    const node = pane.node orelse return error.Unexpected;

    // Too small to halve. A pane that cannot hold a prompt is not worth
    // having, and the ratio limits could not be honoured in it anyway.
    const r = pane.last_rect;
    const extent = switch (dir) {
        .vertical => r.right - r.left,
        .horizontal => r.bottom - r.top,
    };
    if (extent < 120) return error.TooSmall;

    // A split opens the same shell a new tab would, which with nothing
    // configured means the one it is splitting away from.
    const split_profile = newTabProfile(self, window);
    const new_pane = try self.newPane(
        tab,
        .split,
        if (split_profile) |p| p.argv else null,
    );
    errdefer {
        if (new_pane.node) |n| alloc.destroy(n);
        alloc.destroy(new_pane);
    }
    const new_leaf = new_pane.node orelse return error.Unexpected;

    // The pane being split keeps its node's place in the tree, so that
    // node becomes the split and the pane moves down into a leaf of its
    // own beside the new one.
    const old_leaf = try alloc.create(SplitNode);
    errdefer alloc.destroy(old_leaf);
    try tab.panes.append(alloc, new_pane);

    old_leaf.* = .{ .parent = node, .data = .{ .leaf = pane } };
    pane.node = old_leaf;
    new_leaf.parent = node;
    node.data = .{ .split = .{
        .dir = dir,
        .a = if (before) new_leaf else old_leaf,
        .b = if (before) old_leaf else new_leaf,
    } };

    tab.zoomed = null;
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

    // Take the pane out of the layout: the pane beside it inherits the
    // space, by moving up into the split that held the two of them.
    var heir: ?*Surface = null;
    window.drag_split = null;
    tab.zoomed = null;
    // A search box over a pane that is going away has nothing left to
    // search.
    if (window.input_surface == surf) {
        window.input_surface = null;
        if (window.input_mode == .search) {
            window.input_mode = .none;
            if (window.tab_bar) |bar| tabbar.ghostty_tabbar_input_hide(bar);
        }
    }
    if (surf.node) |node| {
        if (node.parent) |parent| {
            const s = parent.data.split;
            const sibling = if (s.a == node) s.b else s.a;
            parent.data = sibling.data;
            switch (parent.data) {
                .leaf => |leaf| leaf.node = parent,
                .split => |moved| {
                    moved.a.parent = parent;
                    moved.b.parent = parent;
                },
            }
            alloc.destroy(sibling);
            heir = parent.firstLeaf();
        } else {
            tab.root = null;
        }
        alloc.destroy(node);
    }

    app.core_app.deleteSurface(surf);
    if (surf.core_ready) surf.core_surface.deinit();
    alloc.destroy(surf);
    _ = tab.panes.orderedRemove(i);

    if (tab.panes.items.len == 0) {
        closeTabStruct(tab);
        return;
    }

    // Focus goes to whatever took the closed pane's place, which is where
    // the user was just looking.
    if (heir) |h| {
        if (tab.indexOfPane(h)) |at| tab.focused = at;
    }
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
    if (window.tab_bar) |bar| {
        if (tab.bar_id != 0) tabbar.ghostty_tabbar_remove_tab(bar, tab.bar_id);
    }
    if (window.input_tab == tab) window.input_tab = null;
    if (tab.title_override) |name| alloc.free(name);
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

/// Closes every pane of the tab at `index` (e.g. from clicking its close
/// button), which in turn closes the tab itself once its last pane is
/// gone. Unlike `closeTabStruct`, this is safe to call on a tab that still
/// has panes.
fn closeTabAt(window: *Window, index: usize) void {
    if (index >= window.tabs.items.len) return;
    const tab = window.tabs.items[index];
    var n = tab.panes.items.len;
    while (n > 0) : (n -= 1) {
        // Once `n` reaches 1, this call closes the last pane and cascades
        // into closeTabStruct, freeing `tab` -- so we never touch `tab`
        // again after that point.
        closePane(tab.panes.items[0]);
    }
}

fn switchTab(window: *Window, index: usize) void {
    if (index >= window.tabs.items.len) return;
    if (window.active == index) return;
    window.active = index;

    // Harmless when the strip is what asked for this switch: the DLL
    // suppresses the selection event it would otherwise echo back.
    if (window.tab_bar) |bar| {
        const tab = window.tabs.items[index];
        if (tab.bar_id != 0) tabbar.ghostty_tabbar_set_selected(bar, tab.bar_id);
    }

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

/// Sync the active tab's (focused pane's) title to the OS window title,
/// lay out and resize every pane of the active tab to its rect, and
/// redraw all of them into the shared GL framebuffer before presenting
/// with a single SwapBuffers. All panes are always redrawn together
/// (rather than just whichever pane's renderer asked for a redraw)
/// because they share one double-buffered framebuffer -- swapping after
/// only one pane's content is updated would show a torn/incomplete frame.
fn reflow(window: *Window) void {
    const tab = window.activeTabPtr() orelse return;

    // Keep keyboard focus on the terminal, but never take it. reflow also
    // draws, so it runs on every frame: grabbing focus unconditionally
    // here yanked it back ~60 times a second, which is why the profile
    // menu -- a window of ours on the same thread -- was deactivated the
    // instant it appeared. GetActiveWindow is per-thread, so this reads as
    // "only when nothing else of ours is up".
    if (w32.GetActiveWindow() == window.hwnd and
        w32.GetFocus() != window.gl_hwnd)
    {
        _ = w32.SetFocus(window.gl_hwnd);
    }

    // Every path that moves focus between tabs or panes ends up here, so
    // this is the one place that catches all of them. It is idempotent,
    // so the layout-only callers (a plain resize) cost nothing.
    syncFocus(window);

    {
        // The tab's title, not the pane's raw one, so that the window reads
        // the same as its tab: the profile name in place of a bare
        // "wsl.exe" or a path to cmd.exe, and a title the user renamed the
        // tab to. Still worth setting with a custom frame: it is what the
        // task bar and Alt-Tab show, even though no title bar displays it.
        var zbuf: [513:0]u16 = undefined;
        const wn = tabTitle(tab, zbuf[0..512]);
        zbuf[wn] = 0;
        if (wn != window.shown_title_len or
            !std.mem.eql(u16, zbuf[0..wn], window.shown_title[0..wn]))
        {
            _ = w32.SetWindowTextW(window.hwnd, zbuf[0..wn :0]);
            @memcpy(window.shown_title[0..wn], zbuf[0..wn]);
            window.shown_title_len = wn;
        }
    }
    syncTabTitle(tab);

    var client_rect: w32.RECT = undefined;
    if (w32.GetClientRect(window.gl_hwnd, &client_rect) == w32.FALSE) return;
    if (w32.wglMakeCurrent(window.hdc, window.hglrc) == w32.FALSE) return;

    const win_width = client_rect.right - client_rect.left;
    const win_height = client_rect.bottom - client_rect.top;
    if (win_width <= 0 or win_height <= 0) return;

    // The overview draws every tab and lays none of them out: the panes
    // keep the rects they had, which is what their frames were drawn for.
    if (window.overview) {
        presentOverview(window, win_width, win_height);
        return;
    }

    // Lay out first. Every pane's rect is settled before anything is
    // drawn or started, so that both can rely on `last_rect`.
    tab.layout(client_rect);
    var starting = false;
    for (tab.panes.items) |pane| {
        const rect = pane.last_rect;
        if (pane.pending != null and window.settled and
            rect.right > rect.left and rect.bottom > rect.top)
        {
            starting = true;
        }
    }

    if (starting) {
        // Starting a pane brings up a whole terminal -- fonts, the pty, the
        // shell -- on this thread, which is the one that paints. Without a
        // frame on screen first, the window sits unpainted for as long as
        // that takes, and an unpainted GL window is white: that was the
        // white flash a new window opened with. So put the background up
        // before going quiet.
        present(window, tab, win_width, win_height);

        for (tab.panes.items) |pane| {
            if (pane.pending == null) continue;
            const rect = pane.last_rect;
            if (rect.right <= rect.left or rect.bottom <= rect.top) continue;
            // The pane's rect is settled as of the loop above, so this is
            // the first moment its shell can be started at a size it will
            // keep. Any earlier and the pty is created at a guess and
            // resized under a shell that has already started printing. See
            // `Surface.pending`.
            window.app.startPane(pane) catch |err| {
                log.err("failed to start pane err={}", .{err});
            };
        }

        // Starting a pane performs actions, and several of them land back
        // in reflow, which makes its own context current on the way.
        if (w32.wglMakeCurrent(window.hdc, window.hglrc) == w32.FALSE) return;
    }

    for (tab.panes.items) |pane| {
        if (!pane.core_ready) continue;
        const rect = pane.last_rect;
        const w: i32 = @max(0, rect.right - rect.left);
        const h: i32 = @max(0, rect.bottom - rect.top);
        if (w == 0 or h == 0) continue;
        pane.core_surface.sizeCallback(.{
            .width = @intCast(w),
            .height = @intCast(h),
        }) catch |err| log.warn("sizeCallback failed err={}", .{err});
    }

    present(window, tab, win_width, win_height);
}

/// Draws the active tab into the window and swaps: the divider shade
/// everywhere, then each pane's background, then each pane's latest frame
/// over that. Expects the window's context to be current and every pane's
/// `last_rect` to be up to date.
fn present(window: *Window, tab: *Tab, win_width: i32, win_height: i32) void {
    // Clear the whole window first so the gap between two split panes
    // isn't left with garbage from a previous frame. Each pane's own
    // drawFrame renders into (and clears) its own offscreen target, not
    // the default framebuffer directly, so this clear only affects the
    // parts *outside* of what gets drawn below.
    w32.glBindFramebuffer(w32.GL_FRAMEBUFFER, 0);
    w32.glDisable(w32.GL_SCISSOR_TEST);
    w32.glViewport(0, 0, win_width, win_height);
    // What is left of this clear once the panes are drawn is the divider
    // between them, so it is the strip's shade: a step darker than the
    // terminal. The factor matches the one the tab strip derives its own
    // background with, so the two agree.
    const bg = window.app.config.background;
    const bg_r = @as(f32, @floatFromInt(bg.r)) / 255.0;
    const bg_g = @as(f32, @floatFromInt(bg.g)) / 255.0;
    const bg_b = @as(f32, @floatFromInt(bg.b)) / 255.0;
    const strip_factor: f32 = 0.62;
    w32.glClearColor(bg_r * strip_factor, bg_g * strip_factor, bg_b * strip_factor, 1);
    w32.glClear(w32.GL_COLOR_BUFFER_BIT);

    for (tab.panes.items) |pane| {
        const rect = pane.last_rect;
        const w: i32 = @max(0, rect.right - rect.left);
        const h: i32 = @max(0, rect.bottom - rect.top);
        if (w == 0 or h == 0) continue;

        // A pane is the terminal's background colour before it is anything
        // else. Its first frame takes a second or so to arrive -- the
        // renderer has fonts to load and the shell has to start -- and
        // until then this is all there is to show, so it has to already be
        // the right colour. This used to be left at the divider's shade,
        // which made every new window and tab open dark and then light up.
        // It also covers what a frame does not: one drawn for a smaller
        // size than the pane now has leaves the bottom and right edges to
        // this.
        w32.glEnable(w32.GL_SCISSOR_TEST);
        w32.glScissor(rect.left, win_height - rect.bottom, w, h);
        w32.glClearColor(bg_r, bg_g, bg_b, 1);
        w32.glClear(w32.GL_COLOR_BUFFER_BIT);
        // A blit is clipped by the scissor too.
        w32.glDisable(w32.GL_SCISSOR_TEST);

        if (!pane.core_ready) continue;

        // The pane's renderer draws on its own thread and leaves each
        // finished frame in a texture this context shares. All that is
        // left to do here is copy the latest one into place.
        _ = pane.core_surface.renderer.takeFrame();
        blitPane(window, pane, rect, win_height) catch |err| {
            log.warn("failed to present pane err={}", .{err});
        };
    }

    dimUnfocusedPanes(window, tab, win_width, win_height);

    _ = w32.SwapBuffers(window.hdc);
}

/// Copy a pane's latest frame into the window's back buffer.
///
/// The frame is whatever size the pane was when the renderer drew it,
/// which trails the pane's current rect by a frame or two during a
/// resize. It is copied unscaled and anchored to the top left, where a
/// terminal's content starts, so that a resize uncovers or crops the
/// bottom and right edges rather than stretching the text.
fn blitPane(
    window: *Window,
    pane: *Surface,
    rect: w32.RECT,
    win_height: i32,
) !void {
    const fbo = window.read_fbo orelse return;
    const front = &pane.core_surface.renderer.api.front;
    const frame = front.lock() orelse return;
    defer front.unlock();

    const w: i32 = @min(@as(i32, @intCast(frame.width)), rect.right - rect.left);
    const h: i32 = @min(@as(i32, @intCast(frame.height)), rect.bottom - rect.top);
    if (w <= 0 or h <= 0) return;

    const bound = try fbo.bind(.read);
    defer bound.unbind();
    // Attached anew every time: the renderer reallocates the texture
    // when the pane is resized, and an attachment made before that
    // would go on referring to the old storage.
    try bound.texture2D(.color0, .@"2d", frame.texture, 0);

    // GL's origin is the bottom left, of the window and of the frame
    // alike, so "top left" is the top `h` rows of each.
    const src_y: i32 = @as(i32, @intCast(frame.height)) - h;
    const dst_y: i32 = win_height - rect.top - h;
    try gl.blitFramebuffer(
        0,
        src_y,
        w,
        src_y + h,
        rect.left,
        dst_y,
        rect.left + w,
        dst_y + h,
        .{ .color_buffer_bit = true },
        .nearest,
    );
}

/// Darkens every pane of a split except the focused one.
///
/// This is the apprt's job, not the renderer's: macOS and GTK both draw
/// the dim in their UI layer (a SwiftUI view, a GTK overlay) rather than
/// asking the renderer for it, so there is nothing to inherit here.
///
/// Drawn after every pane has presented and before the buffer swap, as one
/// translucent quad per unfocused pane in window coordinates. Fixed
/// function rather than a shader: the context is a compatibility one, and
/// the alternative is compiling a program and managing a VAO to draw a
/// rectangle.
fn dimUnfocusedPanes(
    window: *Window,
    tab: *Tab,
    win_width: i32,
    win_height: i32,
) void {
    // Nothing to distinguish when there is only one pane.
    if (tab.panes.items.len < 2) return;

    const opacity = window.app.config.@"unfocused-split-opacity";
    if (opacity >= 1.0) return;
    const alpha: f32 = @floatCast(1.0 - opacity);

    // The renderer leaves its own program bound. Immediate mode ignores
    // it only if nothing is bound, so it has to go -- glUseProgram is a
    // GL 2.0 entry point and opengl32.dll only exports GL 1.1, hence the
    // lookup.
    const use_program: *const fn (u32) callconv(.winapi) void = @ptrCast(
        w32.wglGetProcAddress("glUseProgram") orelse return,
    );
    use_program(0);

    w32.glViewport(0, 0, win_width, win_height);
    w32.glMatrixMode(w32.GL_PROJECTION);
    w32.glPushMatrix();
    w32.glLoadIdentity();
    // Y grows downward, matching the RECTs below.
    w32.glOrtho(0, @floatFromInt(win_width), @floatFromInt(win_height), 0, -1, 1);
    w32.glMatrixMode(w32.GL_MODELVIEW);
    w32.glPushMatrix();
    w32.glLoadIdentity();

    w32.glDisable(w32.GL_DEPTH_TEST);
    w32.glDisable(w32.GL_TEXTURE_2D);
    w32.glEnable(w32.GL_BLEND);
    w32.glBlendFunc(w32.GL_SRC_ALPHA, w32.GL_ONE_MINUS_SRC_ALPHA);

    // The terminal's background unless the user named a fill colour, as
    // on GTK and macOS: the pane's own background stays put and its text
    // and colours fade toward it, rather than the whole pane going dark.
    const fill = window.app.config.@"unfocused-split-fill" orelse
        window.app.config.background;
    w32.glColor4f(
        @as(f32, @floatFromInt(fill.r)) / 255.0,
        @as(f32, @floatFromInt(fill.g)) / 255.0,
        @as(f32, @floatFromInt(fill.b)) / 255.0,
        alpha,
    );

    w32.glBegin(w32.GL_QUADS);
    for (tab.panes.items, 0..) |pane, i| {
        if (i == tab.focused) continue;
        const r = pane.last_rect;
        const l: f32 = @floatFromInt(r.left);
        const t: f32 = @floatFromInt(r.top);
        const rr: f32 = @floatFromInt(r.right);
        const b: f32 = @floatFromInt(r.bottom);
        w32.glVertex2f(l, t);
        w32.glVertex2f(rr, t);
        w32.glVertex2f(rr, b);
        w32.glVertex2f(l, b);
    }
    w32.glEnd();

    w32.glDisable(w32.GL_BLEND);
    w32.glPopMatrix();
    w32.glMatrixMode(w32.GL_PROJECTION);
    w32.glPopMatrix();
    w32.glMatrixMode(w32.GL_MODELVIEW);
}

/// Turns the tab overview on or off.
///
/// The overview is what GTK's AdwTabOverview and the macOS "Show All Tabs"
/// are: every tab of the window as a live thumbnail, to pick one from. It
/// takes over the terminal area, so while it is up the keyboard and mouse
/// drive it rather than the terminal.
fn setOverview(window: *Window, on: bool) void {
    if (window.overview == on) return;
    window.overview = on;
    window.drag_split = null;
    if (on) {
        window.overview_sel = window.active;
        // Any text-shaped cursor the terminal left behind is wrong here.
        _ = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_ARROW));
    } else {
        for (window.overview_labels.items) |label| {
            _ = w32.ShowWindow(label, w32.SW_HIDE);
        }
    }
    reflow(window);
}

/// Space around and between thumbnails, and the height of the caption
/// under each, in pixels.
const overview_gap: i32 = 28;
const overview_label_height: i32 = 24;
/// A thumbnail is never more than this share of the terminal area, so a
/// window with one or two tabs shows thumbnails rather than near-full-size
/// copies.
const overview_max_scale: f32 = 0.6;

/// Where the thumbnail for tab `index` goes, in the GL window's client
/// coordinates. The grid is as square as the tab count allows and every
/// thumbnail has the terminal area's own proportions.
fn overviewRect(window: *Window, index: usize, width: i32, height: i32) w32.RECT {
    const count: i32 = @intCast(@max(1, window.tabs.items.len));
    var cols: i32 = 1;
    while (cols * cols < count) cols += 1;
    const rows = @divTrunc(count + cols - 1, cols);

    const cell_w = @divTrunc(width - overview_gap * (cols + 1), cols);
    const cell_h = @divTrunc(height - overview_gap * (rows + 1), rows) - overview_label_height;
    if (cell_w <= 0 or cell_h <= 0 or width <= 0 or height <= 0) {
        return .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    }

    const aspect = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    var tw: f32 = @min(
        @as(f32, @floatFromInt(cell_w)),
        @as(f32, @floatFromInt(width)) * overview_max_scale,
    );
    var th = tw / aspect;
    if (th > @as(f32, @floatFromInt(cell_h))) {
        th = @floatFromInt(cell_h);
        tw = th * aspect;
    }
    const w: i32 = @intFromFloat(tw);
    const h: i32 = @intFromFloat(th);

    // The grid as a whole is centred, not each cell's content within a
    // stretched cell: otherwise a few small thumbnails drift apart.
    const grid_w = cols * w + (cols - 1) * overview_gap;
    const grid_h = rows * (h + overview_label_height) + (rows - 1) * overview_gap;
    const i: i32 = @intCast(index);
    const col = @mod(i, cols);
    const row = @divTrunc(i, cols);
    const left = @divTrunc(width - grid_w, 2) + col * (w + overview_gap);
    const top = @divTrunc(height - grid_h, 2) + row * (h + overview_label_height + overview_gap);
    return .{ .left = left, .top = top, .right = left + w, .bottom = top + h };
}

/// The tab whose thumbnail or caption is at this point.
fn overviewHit(window: *Window, x: i32, y: i32) ?usize {
    var client: w32.RECT = undefined;
    if (w32.GetClientRect(window.gl_hwnd, &client) == w32.FALSE) return null;
    for (window.tabs.items, 0..) |_, i| {
        const r = overviewRect(window, i, client.right, client.bottom);
        if (x >= r.left and x < r.right and
            y >= r.top and y < r.bottom + overview_label_height) return i;
    }
    return null;
}

/// Fills a rect given in top-left client coordinates with a colour.
fn fillRect(r: w32.RECT, win_height: i32, red: f32, green: f32, blue: f32) void {
    const w = r.right - r.left;
    const h = r.bottom - r.top;
    if (w <= 0 or h <= 0) return;
    w32.glEnable(w32.GL_SCISSOR_TEST);
    w32.glScissor(r.left, win_height - r.bottom, w, h);
    w32.glClearColor(red, green, blue, 1);
    w32.glClear(w32.GL_COLOR_BUFFER_BIT);
    w32.glDisable(w32.GL_SCISSOR_TEST);
}

/// Draws the overview: each tab's panes, scaled down, in a grid.
fn presentOverview(window: *Window, win_width: i32, win_height: i32) void {
    const config = &window.app.config;
    const bg = config.background;
    const fg = config.foreground;
    const bg_r = @as(f32, @floatFromInt(bg.r)) / 255.0;
    const bg_g = @as(f32, @floatFromInt(bg.g)) / 255.0;
    const bg_b = @as(f32, @floatFromInt(bg.b)) / 255.0;

    w32.glBindFramebuffer(w32.GL_FRAMEBUFFER, 0);
    w32.glDisable(w32.GL_SCISSOR_TEST);
    w32.glViewport(0, 0, win_width, win_height);
    // The strip's shade, so the thumbnails -- which are the terminal's own
    // colour -- stand out from what is behind them.
    const strip_factor: f32 = 0.62;
    w32.glClearColor(bg_r * strip_factor, bg_g * strip_factor, bg_b * strip_factor, 1);
    w32.glClear(w32.GL_COLOR_BUFFER_BIT);

    if (window.overview_sel >= window.tabs.items.len) {
        window.overview_sel = window.tabs.items.len -| 1;
    }

    for (window.tabs.items, 0..) |tab, i| {
        const r = overviewRect(window, i, win_width, win_height);
        if (r.right <= r.left) continue;

        // The frame: the foreground colour around the one that Enter or a
        // click would open, a faint line around the rest.
        const selected = i == window.overview_sel;
        const border: i32 = if (selected) 3 else 1;
        const outer: w32.RECT = .{
            .left = r.left - border,
            .top = r.top - border,
            .right = r.right + border,
            .bottom = r.bottom + border,
        };
        if (selected) {
            fillRect(
                outer,
                win_height,
                @as(f32, @floatFromInt(fg.r)) / 255.0,
                @as(f32, @floatFromInt(fg.g)) / 255.0,
                @as(f32, @floatFromInt(fg.b)) / 255.0,
            );
        } else {
            // Half way from the background to the foreground.
            fillRect(
                outer,
                win_height,
                (bg_r + @as(f32, @floatFromInt(fg.r)) / 255.0) / 2 * 0.6,
                (bg_g + @as(f32, @floatFromInt(fg.g)) / 255.0) / 2 * 0.6,
                (bg_b + @as(f32, @floatFromInt(fg.b)) / 255.0) / 2 * 0.6,
            );
        }
        fillRect(r, win_height, bg_r, bg_g, bg_b);

        // The area the tab's panes cover between them, which is what the
        // thumbnail is a scaled copy of. Taken from the panes rather than
        // from the window because a background tab was last laid out for
        // whatever size the window had then.
        var bounds: w32.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        var any = false;
        for (tab.panes.items) |pane| {
            const p = pane.last_rect;
            if (p.right <= p.left or p.bottom <= p.top) continue;
            if (!any) {
                bounds = p;
                any = true;
                continue;
            }
            bounds.left = @min(bounds.left, p.left);
            bounds.top = @min(bounds.top, p.top);
            bounds.right = @max(bounds.right, p.right);
            bounds.bottom = @max(bounds.bottom, p.bottom);
        }
        if (!any) continue;

        const sx = @as(f32, @floatFromInt(r.right - r.left)) /
            @as(f32, @floatFromInt(bounds.right - bounds.left));
        const sy = @as(f32, @floatFromInt(r.bottom - r.top)) /
            @as(f32, @floatFromInt(bounds.bottom - bounds.top));

        for (tab.panes.items) |pane| {
            if (!pane.core_ready) continue;
            const p = pane.last_rect;
            if (p.right <= p.left or p.bottom <= p.top) continue;
            const dst: w32.RECT = .{
                .left = r.left + @as(i32, @intFromFloat(@as(f32, @floatFromInt(p.left - bounds.left)) * sx)),
                .top = r.top + @as(i32, @intFromFloat(@as(f32, @floatFromInt(p.top - bounds.top)) * sy)),
                .right = r.left + @as(i32, @intFromFloat(@as(f32, @floatFromInt(p.right - bounds.left)) * sx)),
                .bottom = r.top + @as(i32, @intFromFloat(@as(f32, @floatFromInt(p.bottom - bounds.top)) * sy)),
            };
            _ = pane.core_surface.renderer.takeFrame();
            blitPaneScaled(window, pane, dst, win_height) catch |err| {
                log.warn("failed to draw thumbnail err={}", .{err});
            };
        }
    }

    _ = w32.SwapBuffers(window.hdc);
    syncOverviewLabels(window, win_width, win_height);
}

/// Copies a pane's latest frame into `dst`, scaled to fit it.
fn blitPaneScaled(
    window: *Window,
    pane: *Surface,
    dst: w32.RECT,
    win_height: i32,
) !void {
    const fbo = window.read_fbo orelse return;
    const front = &pane.core_surface.renderer.api.front;
    const frame = front.lock() orelse return;
    defer front.unlock();

    // The part of the frame that is the pane: as in blitPane, a frame can
    // trail the pane's size, and its top left is what lines up.
    const rect = pane.last_rect;
    const w: i32 = @min(@as(i32, @intCast(frame.width)), rect.right - rect.left);
    const h: i32 = @min(@as(i32, @intCast(frame.height)), rect.bottom - rect.top);
    if (w <= 0 or h <= 0) return;
    if (dst.right <= dst.left or dst.bottom <= dst.top) return;

    const bound = try fbo.bind(.read);
    defer bound.unbind();
    try bound.texture2D(.color0, .@"2d", frame.texture, 0);

    const src_y: i32 = @as(i32, @intCast(frame.height)) - h;
    try gl.blitFramebuffer(
        0,
        src_y,
        w,
        src_y + h,
        dst.left,
        win_height - dst.bottom,
        dst.right,
        win_height - dst.top,
        .{ .color_buffer_bit = true },
        .linear,
    );
}

/// The name a tab goes by: what its shell reports, or the profile's name
/// when that is missing or is only the path of the executable. Written
/// into `buf` as UTF-16; returns its length.
fn tabTitle(tab: *Tab, buf: []u16) usize {
    const window = tab.window;
    if (tab.title_override) |name| {
        const n = std.unicode.utf8ToUtf16Le(buf, name) catch 0;
        if (n > 0) return n;
    }
    const reported: []const u8 = if (tab.focusedPane()) |s|
        s.title_buf[0..s.title_len]
    else
        "";

    // Falling back to the profile name is what makes a Command Prompt tab
    // read "Command Prompt" instead of the path to cmd.exe. The console
    // host does not always report the full path: a WSL tab gets just
    // "wsl.exe", which says nothing about which distribution it is, and
    // every distribution's profile runs that same program. The tab's own
    // profile is what knows, so a title that is merely the name of the
    // program that profile runs counts as no title at all.
    const title = if (reported.len == 0 or
        titleIsExePath(reported) or
        titleIsProfileProgram(tab.profile, reported))
        (if (tab.profile) |p|
            p.name
        else
            profileNameForExe(window, reported) orelse "Ghostty")
    else
        reported;

    const n = std.unicode.utf8ToUtf16Le(buf, title) catch 0;
    if (n > 0) return n;
    const fallback = std.unicode.utf8ToUtf16LeStringLiteral("Ghostty");
    @memcpy(buf[0..fallback.len], fallback);
    return fallback.len;
}

/// Puts a caption under each thumbnail, creating the caption windows the
/// first time each is needed. Runs after every overview frame, so it only
/// touches what is out of date.
fn syncOverviewLabels(window: *Window, width: i32, height: i32) void {
    const app = window.app;
    const alloc = app.core_app.alloc;
    const strip = window.shownStripHeight();

    while (window.overview_labels.items.len < window.tabs.items.len) {
        const label = w32.CreateWindowExW(
            0,
            label_class_name,
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            w32.WS_CHILD | w32.WS_CLIPSIBLINGS,
            0,
            0,
            0,
            0,
            window.hwnd,
            null,
            app.hinstance,
            window,
        ) orelse return;
        window.overview_labels.append(alloc, label) catch {
            _ = w32.DestroyWindow(label);
            return;
        };
    }

    for (window.overview_labels.items, 0..) |label, i| {
        if (i >= window.tabs.items.len) {
            _ = w32.ShowWindow(label, w32.SW_HIDE);
            continue;
        }
        const r = overviewRect(window, i, width, height);

        var want: [256:0]u16 = undefined;
        const n = tabTitle(window.tabs.items[i], want[0..255]);
        want[n] = 0;
        var have: [256:0]u16 = undefined;
        const have_len: usize = @intCast(@max(0, w32.GetWindowTextW(label, &have, 256)));
        if (!std.mem.eql(u16, want[0..n], have[0..have_len])) {
            _ = w32.SetWindowTextW(label, want[0..n :0]);
            _ = w32.InvalidateRect(label, null, w32.TRUE);
        }

        // In the frame's coordinates, which start above the strip. Placed
        // at the top of the z-order: the caption has to be over the GL
        // window, which is its sibling.
        _ = w32.SetWindowPos(
            label,
            null,
            r.left,
            strip + r.bottom + 4,
            r.right - r.left,
            overview_label_height - 4,
            w32.SWP_NOACTIVATE | w32.SWP_SHOWWINDOW,
        );
    }
}

/// Window procedure for an overview caption: one line of centred text on
/// the overview's background. Clicks fall through to the GL window under
/// it, so a caption selects its tab just as its thumbnail does.
fn labelWndProc(
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

    switch (msg) {
        w32.WM_NCHITTEST => return w32.HTTRANSPARENT,
        w32.WM_ERASEBKGND => return 1,
        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            const window = getWindow(hwnd) orelse return 0;
            const app = window.app;
            const bg = app.config.background;
            const fg = app.config.foreground;

            var rect: w32.RECT = undefined;
            _ = w32.GetClientRect(hwnd, &rect);
            // The same shade presentOverview clears to.
            const brush = w32.CreateSolidBrush(w32.RGB(
                scaleChannel(bg.r, 0.62),
                scaleChannel(bg.g, 0.62),
                scaleChannel(bg.b, 0.62),
            )) orelse return 0;
            _ = w32.FillRect(hdc, &rect, brush);
            _ = w32.DeleteObject(@ptrCast(brush));

            if (app.ui_font == null) {
                app.ui_font = w32.CreateFontW(
                    -13,
                    0,
                    0,
                    0,
                    400,
                    0,
                    0,
                    0,
                    1, // DEFAULT_CHARSET
                    0,
                    0,
                    5, // CLEARTYPE_QUALITY
                    0,
                    std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
                );
            }
            const old = if (app.ui_font) |f| w32.SelectObject(hdc, @ptrCast(f)) else null;
            defer if (old) |o| {
                _ = w32.SelectObject(hdc, o);
            };

            var text: [256:0]u16 = undefined;
            const n = w32.GetWindowTextW(hwnd, &text, 256);
            _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
            _ = w32.SetTextColor(hdc, w32.RGB(fg.r, fg.g, fg.b));
            _ = w32.DrawTextW(
                hdc,
                &text,
                n,
                &rect,
                w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS,
            );
            return 0;
        },
        else => return w32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
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

/// Adds `amount` to a single color channel (e.g. to lighten for hover
/// feedback), clamped to a valid byte.
fn lightenChannel(c: u8, amount: u8) u8 {
    return @intCast(@min(255, @as(u16, c) + @as(u16, amount)));
}

/// Fills `rect` with `color`, rounding the top-left/top-right corners by
/// `radius` pixels and leaving the bottom edge square -- gives tabs the
/// familiar "folder tab" silhouette that sits flush against the content
/// below the active one.
fn fillTabShape(hdc: w32.HDC, rect: w32.RECT, color: w32.COLORREF, radius: i32) void {
    const brush = w32.CreateSolidBrush(color) orelse return;
    defer _ = w32.DeleteObject(@ptrCast(brush));

    const old_brush = w32.SelectObject(hdc, @ptrCast(brush));
    defer if (old_brush) |ob| {
        _ = w32.SelectObject(hdc, ob);
    };
    const null_pen = w32.GetStockObject(w32.NULL_PEN);
    const old_pen = if (null_pen) |np| w32.SelectObject(hdc, np) else null;
    defer if (old_pen) |op| {
        _ = w32.SelectObject(hdc, op);
    };

    _ = w32.RoundRect(hdc, rect.left, rect.top, rect.right, rect.bottom, radius * 2, radius * 2);
    if (radius > 0) {
        // Square off the bottom two corners that RoundRect just rounded.
        var bottom_rect = rect;
        bottom_rect.top = rect.bottom - radius;
        _ = w32.FillRect(hdc, &bottom_rect, brush);
    }
}

/// Draws a single centered glyph (used for the close "x" and add "+"
/// buttons) in `color`, optionally over a rounded highlight background
/// when `hovered`.
fn drawGlyphButton(
    hdc: w32.HDC,
    rect: w32.RECT,
    glyph: *const [1:0]u16,
    color: w32.COLORREF,
    hovered: bool,
    hover_color: w32.COLORREF,
) void {
    if (hovered) {
        const radius = @divTrunc(rect.right - rect.left, 2);
        fillTabShape(hdc, rect, hover_color, radius);
    }
    _ = w32.SetTextColor(hdc, color);
    var text_rect = rect;
    _ = w32.DrawTextW(hdc, glyph, @intCast(glyph.len), &text_rect, w32.DT_CENTER | w32.DT_VCENTER | w32.DT_SINGLELINE);
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

    const inactive_brush = w32.CreateSolidBrush(inactive_color);
    defer if (inactive_brush) |b| {
        _ = w32.DeleteObject(@ptrCast(b));
    };

    // Hover tints: a subtle lightening for inactive tabs and the add
    // button, and a Windows-style red for the close buttons (matching the
    // native title bar close control's hover color).
    const hover_color = w32.RGB(
        lightenChannel(scaleChannel(bg.r, 0.6), 18),
        lightenChannel(scaleChannel(bg.g, 0.6), 18),
        lightenChannel(scaleChannel(bg.b, 0.6), 18),
    );
    const close_hover_color = w32.RGB(196, 43, 28);

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
        const rect: w32.RECT = .{ .left = left, .top = 0, .right = left + tab_width, .bottom = tab_bar_height };

        const is_active = i == window.active;
        const is_hover_tab = window.hover.eql(.{ .tab = i });
        const is_hover_close = window.hover.eql(.{ .close = i });

        const fill_color = if (is_active)
            active_color
        else if (is_hover_tab or is_hover_close)
            hover_color
        else
            inactive_color;
        fillTabShape(hdc, rect, fill_color, tab_radius);
        _ = w32.SetTextColor(hdc, if (is_active) active_text else inactive_text);

        const title_surf = tab.focusedPane();
        var title_w: [513]u16 = undefined;
        const title_len = if (title_surf) |s|
            (std.unicode.utf8ToUtf16Le(&title_w, s.title_buf[0..s.title_len]) catch 0)
        else
            0;
        const close_left = left + tab_width - close_btn_margin - close_btn_size;
        var text_rect: w32.RECT = .{ .left = left + 10, .top = 0, .right = close_left - 4, .bottom = tab_bar_height };
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

        const close_top = @divTrunc(tab_bar_height - close_btn_size, 2);
        const close_rect: w32.RECT = .{
            .left = close_left,
            .top = close_top,
            .right = close_left + close_btn_size,
            .bottom = close_top + close_btn_size,
        };
        const close_glyph = std.unicode.utf8ToUtf16LeStringLiteral("\u{00D7}");
        drawGlyphButton(
            hdc,
            close_rect,
            close_glyph,
            if (is_hover_close) w32.RGB(255, 255, 255) else if (is_active) active_text else inactive_text,
            is_hover_close,
            close_hover_color,
        );
    }

    const add_rect = window.addButtonRect();
    const is_hover_add = window.hover.eql(.add);
    const add_glyph = std.unicode.utf8ToUtf16LeStringLiteral("+");
    drawGlyphButton(
        hdc,
        add_rect,
        add_glyph,
        if (is_hover_add) active_text else inactive_text,
        is_hover_add,
        hover_color,
    );
}

/// A single pane: owns a CoreSurface and belongs to exactly one Tab. This
/// is what `apprt.Surface` resolves to -- `CoreSurface.rt_surface` points
/// here.
pub const Surface = struct {
    tab: *Tab,
    core_surface: CoreSurface,
    core_ready: bool,
    /// What `startPane` still needs in order to bring this pane up, or null
    /// once it has.
    ///
    /// A pane is allocated before anyone knows how big it will be. Its rect
    /// depends on the split layout, which is only decided after the pane is
    /// in the tab, and on the window's size, which Windows is still free to
    /// change: a shell-launched packaged build gets its remembered geometry
    /// restored a frame or two after the window first becomes visible. The
    /// pty is created at whatever size the surface reports, so starting the
    /// shell before then means starting it at the wrong size and resizing
    /// out from under it -- and ConPTY re-wraps its buffer on resize, which
    /// mangles whatever the shell has already printed.
    pending: ?Pending,

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
    /// Last focus state handed to the core, so syncFocus can skip
    /// surfaces that haven't changed.
    focused: bool = false,
    /// This pane's leaf in its tab's layout tree.
    node: ?*SplitNode = null,
    /// The mouse cursor the terminal last asked for (`mouse_shape`), or
    /// null for the ordinary arrow.
    cursor: ?w32.HCURSOR = null,

    pub const Pending = struct {
        context: apprt.surface.NewSurfaceContext,
        /// Borrowed from the window's profile list, which outlives the pane.
        argv: ?[]const []const u8,
        /// A handed-off console session to attach to instead of starting
        /// a shell. Owned by the pane until its core takes it.
        handoff: ?termio.Exec.WindowsHandoff = null,
    };

    pub fn deinit(self: *Surface) void {
        _ = self;
    }

    pub fn renderDeviceOptions(self: *const Surface) !@import("../renderer.zig").Device.Options {
        return .{ .root = self.tab.window.app.gl_root.hglrc };
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
    ) !apprt.ClipboardReadResult {
        if (clipboard_type != .standard) return .unsupported;

        const alloc = self.tab.window.app.core_app.alloc;
        const text = readClipboardUtf8(alloc) catch |err| {
            log.warn("failed to read clipboard err={}", .{err});
            return .unavailable;
        } orelse return .unavailable;
        defer alloc.free(text);

        self.core_surface.completeClipboardRequest(state, .{
            .contents = &.{.{ .mime = "text/plain", .data = text }},
        }) catch |err| {
            log.warn("failed to complete clipboard request err={}", .{err});
        };
        return .started;
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
        .super = w32.GetKeyState(@intCast(w32.VK_LWIN)) < 0 or
            w32.GetKeyState(@intCast(w32.VK_RWIN)) < 0,
    };
}

/// Maps virtual key codes to Ghostty's layout-independent Key enum.
///
/// This covers the control keys and the printable keys alike, because
/// Ghostty's key encoder needs the physical key to produce the right
/// bytes. Relying on WM_CHAR for these is what made backspace send BS
/// (0x08) instead of DEL (0x7F) -- shells read 0x08 as ^H, which several
/// bind to "delete word", so backspace ate whole words. Ctrl+key was
/// broken the same way: WM_CHAR hands us the already-folded control
/// codepoint, which the encoder then has no way to reason about.
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
        w32.VK_BACK => .backspace,
        w32.VK_TAB => .tab,
        w32.VK_RETURN => .enter,
        w32.VK_ESCAPE => .escape,
        w32.VK_SPACE => .space,

        // Letters and digits. Win32 reuses the ASCII values for these, and
        // both enums are contiguous, so the offset carries across.
        'A'...'Z' => @fromBackingInt(@intCast(@as(c_int, @backingInt(input.Key.key_a)) + @as(c_int, @intCast(vk - 'A')))),
        '0'...'9' => @fromBackingInt(@intCast(@as(c_int, @backingInt(input.Key.digit_0)) + @as(c_int, @intCast(vk - '0')))),

        // OEM keys are positional, so these are the US layout's meanings.
        // A layout-correct mapping needs the scancode, but these only
        // matter for ctrl/alt chords, where the physical key is what
        // shells key off anyway.
        w32.VK_OEM_1 => .semicolon,
        w32.VK_OEM_PLUS => .equal,
        w32.VK_OEM_COMMA => .comma,
        w32.VK_OEM_MINUS => .minus,
        w32.VK_OEM_PERIOD => .period,
        w32.VK_OEM_2 => .slash,
        w32.VK_OEM_3 => .backquote,
        w32.VK_OEM_4 => .bracket_left,
        w32.VK_OEM_5 => .backslash,
        w32.VK_OEM_6 => .bracket_right,
        w32.VK_OEM_7 => .quote,

        w32.VK_F1...(w32.VK_F1 + 23) => @fromBackingInt(@intCast(@as(c_int, @backingInt(input.Key.f1)) + @as(c_int, @intCast(vk - w32.VK_F1)))),
        else => null,
    };
}

/// Text input. WM_CHAR is only good for text: Windows has already folded
/// the modifiers into the codepoint by this point, so a control chord
/// arrives as a bare control code with no way to recover which key
/// produced it. Those are handled in handleKey instead, and skipped here.
fn handleChar(surf: *Surface, wparam: w32.WPARAM) void {
    if (!surf.core_ready) return;

    const cu: u16 = @truncate(wparam);
    // Skip UTF-16 surrogate halves; non-BMP input isn't handled by this
    // skeleton.
    if (cu >= 0xD800 and cu <= 0xDFFF) return;

    // C0 controls and DEL. handleKey already delivered these with the
    // physical key intact; letting them through here would both duplicate
    // the event and feed the encoder a pre-folded codepoint.
    if (cu < 0x20 or cu == 0x7F) return;

    // Alt chords produce WM_SYSCHAR, not WM_CHAR, but a ctrl chord that
    // maps to a printable codepoint (ctrl+shift+2 and friends) still lands
    // here. The key event has already gone out.
    const mods = currentMods();
    if (mods.ctrl or mods.alt) return;

    var utf8_buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cu, &utf8_buf) catch return;

    const event: input.KeyEvent = .{
        .action = .press,
        .key = .unidentified,
        .mods = mods,
        .utf8 = utf8_buf[0..len],
        .unshifted_codepoint = cu,
    };
    _ = surf.core_surface.keyCallback(event) catch |err| {
        log.warn("keyCallback failed err={}", .{err});
    };
}

/// True if this key was delivered to the terminal and WM_CHAR should not
/// also fire for it.
fn handleKey(surf: *Surface, wparam: w32.WPARAM, action: input.Action) bool {
    if (!surf.core_ready) return false;

    const vk: u32 = @intCast(wparam);
    const key = vkToKey(vk) orelse return false;
    const mods = currentMods();

    // Printable keys with no ctrl/alt are left to WM_CHAR, which is the
    // only thing that knows the user's layout and any dead-key
    // composition. Everything else -- control keys, and any chord -- is
    // encoded by Ghostty from the physical key.
    //
    // "Printable" is decided by whether the key types a character on this
    // layout, not by which keys are not control keys: arrows, Home/End,
    // Page Up/Down, Insert, Delete and the function keys type nothing, so
    // they never produce a WM_CHAR. Counting them as printable, as this
    // once did, meant that pressed on their own they reached nothing at
    // all -- no history on Up, no F-keys for htop or mc.
    const printable = switch (key) {
        .backspace, .tab, .enter, .escape => false,
        else => w32.MapVirtualKeyW(vk, w32.MAPVK_VK_TO_CHAR) != 0,
    };
    if (printable and !mods.ctrl and !mods.alt) return false;

    const event: input.KeyEvent = .{
        .action = action,
        .key = key,
        .mods = mods,
        .utf8 = "",
        .unshifted_codepoint = unshiftedCodepoint(vk),
    };
    _ = surf.core_surface.keyCallback(event) catch |err| {
        log.warn("keyCallback failed err={}", .{err});
        return false;
    };
    return true;
}

/// The character this key produces with no modifiers held.
///
/// Keybindings are matched on this, not only on the physical key, so
/// leaving it zero means a chord like ctrl+shift+v never resolves to
/// paste_from_clipboard -- the binding simply does not match and the key
/// vanishes. MapVirtualKey answers for the user's actual layout rather
/// than assuming US.
fn unshiftedCodepoint(vk: u32) u21 {
    const ch = w32.MapVirtualKeyW(vk, w32.MAPVK_VK_TO_CHAR) & 0xFFFF;
    if (ch == 0) return 0;
    // Dead keys come back with the high bit set and no usable character.
    if (ch & 0x8000 != 0) return 0;
    // MapVirtualKey reports letters uppercase; unshifted means lowercase.
    if (ch < 128) return std.ascii.toLower(@intCast(ch));
    return @intCast(ch);
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

            // While the tabs are still there to be written down.
            app.saveSession(window);

            // The children outlive this message: Windows destroys them
            // after their parent's WM_DESTROY, and the GL surface can be
            // sent a resize on the way out. Each finds the Window through
            // its user data, which is about to be freed, so unhook them
            // first -- a resize arriving afterwards then finds nothing and
            // goes to DefWindowProc instead of into freed memory.
            _ = w32.SetWindowLongPtrW(window.gl_hwnd, w32.GWLP_USERDATA, 0);
            for (window.overview_labels.items) |label| {
                _ = w32.SetWindowLongPtrW(label, w32.GWLP_USERDATA, 0);
            }
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);

            for (window.tabs.items) |tab| {
                for (tab.panes.items) |surf| {
                    app.core_app.deleteSurface(surf);
                    if (surf.core_ready) surf.core_surface.deinit();
                    alloc.destroy(surf);
                }
                if (tab.root) |root| freeTree(alloc, root);
                if (tab.title_override) |name| alloc.free(name);
                tab.panes.deinit(alloc);
                alloc.destroy(tab);
            }
            window.tabs.deinit(alloc);
            window.palette_map.deinit(alloc);
            if (app.quick_window == window) app.quick_window = null;
            // The caption windows are children and go with the frame.
            window.overview_labels.deinit(alloc);
            for (app.windows.items, 0..) |w, i| {
                if (w == window) {
                    _ = app.windows.swapRemove(i);
                    break;
                }
            }

            if (window.tab_bar) |bar| tabbar.ghostty_tabbar_destroy(bar);
            if (window.profiles.len > 0) tabbar.freeProfiles(alloc, window.profiles);

            if (w32.wglMakeCurrent(window.hdc, window.hglrc) != w32.FALSE) {
                if (window.read_fbo) |fbo| fbo.destroy();
            }
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

        wm_tab_menu => {
            showTabMenu(window, @intCast(@as(usize, @bitCast(lparam))));
            return 0;
        },

        wm_ipc_new_window => {
            _ = window.app.newWindow(null) catch |err| {
                log.warn("failed to open window for another instance err={}", .{err});
            };
            return 0;
        },

        w32.WM_SIZE => {
            const width: i32 = w32.LOWORD(lparam);
            const height: i32 = w32.HIWORD(lparam);
            const full_strip = window.stripHeight();
            // Fullscreen, no decorations or `window-show-tab-bar = never`:
            // the terminal and nothing else.
            const strip: i32 = window.shownStripHeight();

            // A maximized window with a custom frame is positioned offset
            // by the frame thickness, which would push the top of the
            // strip off-screen. Pad by exactly that much.
            const maximized = wparam == w32.SIZE_MAXIMIZED;
            const pad: i32 = if (window.customFrame() and maximized and !window.fullscreen)
                w32.GetSystemMetrics(w32.SM_CYFRAME) +
                    w32.GetSystemMetrics(w32.SM_CXPADDEDBORDER)
            else
                0;

            if (window.tab_bar) |bar| {
                // Out of sight above the window rather than hidden: XAML
                // stops composing for a hidden island, and it would come
                // back white.
                const y: i32 = if (window.stripShown()) pad else -full_strip;
                tabbar.ghostty_tabbar_resize(bar, 0, y, width, full_strip);
                tabbar.ghostty_tabbar_set_maximized(bar, if (maximized) 1 else 0);
            }

            _ = w32.MoveWindow(
                window.gl_hwnd,
                0,
                pad + strip,
                width,
                @max(0, height - strip - pad),
                w32.TRUE,
            );
            return 0;
        },

        // Surrender the caption's space to the client area so the tab
        // strip can occupy it. Letting DefWindowProc compute the client
        // rect and then restoring rc.top keeps the resizable side and
        // bottom borders intact.
        w32.WM_NCCALCSIZE => {
            if (!window.customFrame() or wparam == 0)
                return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            const params: *w32.NCCALCSIZE_PARAMS =
                @ptrFromInt(@as(usize, @bitCast(lparam)));
            const top = params.rgrc[0].top;
            _ = w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            params.rgrc[0].top = top;
            return 0;
        },

        // With the caption gone the top resize edge goes with it, so it
        // has to be reported by hand or the window resizes from only three
        // sides.
        w32.WM_NCHITTEST => {
            const hit = w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            if (!window.customFrame() or hit != w32.HTCLIENT) return hit;
            // Nothing to resize by in fullscreen.
            if (window.fullscreen) return hit;

            var pt: w32.POINT = .{
                .x = @as(i16, @bitCast(w32.LOWORD(lparam))),
                .y = @as(i16, @bitCast(w32.HIWORD(lparam))),
            };
            _ = w32.ScreenToClient(hwnd, &pt);
            const border = w32.GetSystemMetrics(w32.SM_CYFRAME) +
                w32.GetSystemMetrics(w32.SM_CXPADDEDBORDER);
            if (pt.y < border) return w32.HTTOP;
            return hit;
        },

        w32.WM_PAINT => {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
            defer _ = w32.EndPaint(hwnd, &ps);
            // The native strip paints itself; only the fallback needs us.
            if (window.tab_bar == null and window.stripShown()) paintTabBar(window, hdc);
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

        w32.WM_MOUSEMOVE => {
            const x: i16 = @bitCast(w32.LOWORD(lparam));
            const y: i16 = @bitCast(w32.HIWORD(lparam));
            const target = window.hitTestTabBar(@as(i32, x), @as(i32, y));
            if (!window.hover.eql(target)) {
                window.hover = target;
                invalidateTabBar(window);
            }
            // One-shot: must be re-armed on every WM_MOUSEMOVE to keep
            // getting WM_MOUSELEAVE when the cursor exits the window.
            var tme: w32.TRACKMOUSEEVENT = .{ .dwFlags = w32.TME_LEAVE, .hwndTrack = hwnd };
            _ = w32.TrackMouseEvent(&tme);
            return 0;
        },

        w32.WM_MOUSELEAVE => {
            if (!window.hover.eql(.none)) {
                window.hover = .none;
                invalidateTabBar(window);
            }
            return 0;
        },

        w32.WM_LBUTTONDOWN => {
            const x: i16 = @bitCast(w32.LOWORD(lparam));
            const y: i16 = @bitCast(w32.HIWORD(lparam));
            switch (window.hitTestTabBar(@as(i32, x), @as(i32, y))) {
                .none => {},
                .tab => |index| switchTab(window, index),
                .close => |index| closeTabAt(window, index),
                .add => _ = window.app.newTab(
                    window,
                    .tab,
                    newTabProfile(window.app, window),
                ) catch |err| {
                    log.warn("failed to create tab err={}", .{err});
                },
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
            window.has_focus = msg == w32.WM_SETFOCUS;
            syncFocus(window);
            return 0;
        },

        w32.WM_ERASEBKGND => return 1,

        w32.WM_CHAR => {
            // The overview owns the keyboard while it is up.
            if (window.overview) return 0;
            if (window.focusedSurface()) |surf| handleChar(surf, wparam);
            return 0;
        },

        w32.WM_SETCURSOR => {
            // Only over our own client area; the frame's edges keep their
            // sizing arrows.
            if (w32.LOWORD(lparam) != @as(u16, @intCast(w32.HTCLIENT))) {
                return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            }
            const arrow = w32.LoadCursorW(null, w32.IDC_ARROW);
            if (window.overview) {
                _ = w32.SetCursor(arrow);
                return 1;
            }
            const tab = window.activeTabPtr() orelse return 1;

            var pt: w32.POINT = undefined;
            _ = w32.GetCursorPos(&pt);
            _ = w32.ScreenToClient(hwnd, &pt);
            const over_divider = window.drag_split orelse tab.dividerHit(pt.x, pt.y);
            if (over_divider) |node| {
                _ = w32.SetCursor(w32.LoadCursorW(null, switch (node.data.split.dir) {
                    .vertical => w32.IDC_SIZEWE,
                    .horizontal => w32.IDC_SIZENS,
                }));
                return 1;
            }

            // The shape belongs to the pane the pointer is over, not the
            // focused one: a program in the other pane may want a pointer
            // where this one wants an I-beam.
            // A pane that has not been told otherwise is showing text, and
            // the core only reports the shape when it changes from that.
            const surf = if (tab.paneAt(pt.x, pt.y)) |i| tab.panes.items[i] else null;
            const ibeam = w32.LoadCursorW(null, w32.IDC_IBEAM);
            _ = w32.SetCursor(if (surf) |s| (s.cursor orelse ibeam) else arrow);
            return 1;
        },

        w32.WM_DROPFILES => {
            const drop: w32.HDROP = @ptrFromInt(wparam);
            defer w32.DragFinish(drop);
            if (window.overview) return 0;
            const surf = window.focusedSurface() orelse return 0;
            if (!surf.core_ready) return 0;

            // The paths, space separated, each quoted if it needs to be --
            // what a shell wants to see where a file name goes. Sent as a
            // paste so that bracketed paste applies and nothing in a path
            // can be taken for a keystroke.
            const alloc = window.app.core_app.alloc;
            var text: std.ArrayListUnmanaged(u8) = .empty;
            defer text.deinit(alloc);
            const count = w32.DragQueryFileW(drop, 0xFFFF_FFFF, null, 0);
            var i: w32.UINT = 0;
            while (i < count) : (i += 1) {
                var wide: [1024]u16 = undefined;
                const len = w32.DragQueryFileW(drop, i, &wide, wide.len);
                if (len == 0) continue;
                var utf8: [3072]u8 = undefined;
                const n = std.unicode.utf16LeToUtf8(&utf8, wide[0..len]) catch continue;
                const path = utf8[0..n];
                const quote = std.mem.indexOfAny(u8, path, " &()^;,") != null;
                if (text.items.len > 0) text.append(alloc, ' ') catch return 0;
                if (quote) text.append(alloc, '"') catch return 0;
                text.appendSlice(alloc, path) catch return 0;
                if (quote) text.append(alloc, '"') catch return 0;
            }
            if (text.items.len == 0) return 0;
            surf.core_surface.textCallback(text.items) catch |err| {
                log.warn("failed to paste dropped files err={}", .{err});
            };
            return 0;
        },

        w32.WM_KEYDOWN, w32.WM_SYSKEYDOWN => {
            if (window.overview) {
                const count = window.tabs.items.len;
                const vk: u32 = @intCast(wparam);
                switch (vk) {
                    w32.VK_ESCAPE => setOverview(window, false),
                    w32.VK_RETURN, w32.VK_SPACE => {
                        const pick = window.overview_sel;
                        setOverview(window, false);
                        switchTab(window, pick);
                    },
                    w32.VK_RIGHT, w32.VK_DOWN, w32.VK_TAB => if (count > 0) {
                        window.overview_sel = (window.overview_sel + 1) % count;
                        reflow(window);
                    },
                    w32.VK_LEFT, w32.VK_UP => if (count > 0) {
                        window.overview_sel = (window.overview_sel + count - 1) % count;
                        reflow(window);
                    },
                    // Alt chords still reach the system, so Alt+F4 and
                    // Alt+Space keep working.
                    else => if (msg == w32.WM_SYSKEYDOWN) {
                        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
                    },
                }
                return 0;
            }
            if (window.focusedSurface()) |surf| {
                // Swallowing the key when it was handled is what keeps
                // DefWindowProc from also translating it into a WM_CHAR,
                // which would deliver the same keystroke twice.
                if (handleKey(surf, wparam, .press)) return 0;
            }
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_KEYUP, w32.WM_SYSKEYUP => {
            if (window.overview) return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            if (window.focusedSurface()) |surf| _ = handleKey(surf, wparam, .release);
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        },

        w32.WM_MOUSEMOVE => {
            if (window.overview) {
                const x: i16 = @bitCast(w32.LOWORD(lparam));
                const y: i16 = @bitCast(w32.HIWORD(lparam));
                if (overviewHit(window, x, y)) |i| {
                    if (i != window.overview_sel) {
                        window.overview_sel = i;
                        reflow(window);
                    }
                }
                return 0;
            }
            if (window.drag_split) |node| {
                // The divider follows the pointer: its ratio is simply
                // where the pointer is along the split's extent.
                const x: i16 = @bitCast(w32.LOWORD(lparam));
                const y: i16 = @bitCast(w32.HIWORD(lparam));
                const r = node.rect;
                const s = &node.data.split;
                const pos: f32, const start: f32, const extent: f32 = switch (s.dir) {
                    .vertical => .{
                        @floatFromInt(x),
                        @floatFromInt(r.left),
                        @floatFromInt(r.right - r.left),
                    },
                    .horizontal => .{
                        @floatFromInt(y),
                        @floatFromInt(r.top),
                        @floatFromInt(r.bottom - r.top),
                    },
                };
                if (extent > 0) {
                    s.ratio = std.math.clamp(
                        (pos - start) / extent,
                        split_ratio_min,
                        split_ratio_max,
                    );
                    reflow(window);
                }
                return 0;
            }
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
            if (window.overview) {
                const x: i16 = @bitCast(w32.LOWORD(lparam));
                const y: i16 = @bitCast(w32.HIWORD(lparam));
                // A click on a thumbnail opens it; a click on the empty
                // space around them just closes the overview.
                const pick = overviewHit(window, x, y);
                setOverview(window, false);
                if (pick) |i| switchTab(window, i);
                return 0;
            }
            if (window.activeTabPtr()) |tab| {
                const x: i16 = @bitCast(w32.LOWORD(lparam));
                const y: i16 = @bitCast(w32.HIWORD(lparam));
                if (tab.dividerHit(x, y)) |node| {
                    // Captured, so the drag keeps going when the pointer
                    // slips off the divider or out of the window.
                    window.drag_split = node;
                    _ = w32.SetCapture(hwnd);
                    return 0;
                }
                if (tab.paneAt(x, y)) |idx| {
                    // Clicking into a pane focuses it. This path does not
                    // reflow, so it has to sync focus itself.
                    if (tab.focused != idx) {
                        tab.focused = idx;
                        syncFocus(window);
                    }
                }
                if (tab.focusedPane()) |surf| mouseButton(surf, .press, .left);
            }
            return 0;
        },
        w32.WM_LBUTTONUP => {
            if (window.drag_split != null) {
                window.drag_split = null;
                _ = w32.ReleaseCapture();
                return 0;
            }
            if (window.overview) return 0;
            if (window.focusedSurface()) |surf| mouseButton(surf, .release, .left);
            return 0;
        },
        w32.WM_RBUTTONDOWN => {
            if (window.overview) return 0;
            if (window.focusedSurface()) |surf| mouseButton(surf, .press, .right);
            return 0;
        },
        w32.WM_RBUTTONUP => {
            if (window.overview) return 0;
            const surf = window.focusedSurface() orelse return 0;
            mouseButton(surf, .release, .right);
            // The menu, unless the right button is spoken for: a program
            // that has asked for mouse events gets them (Shift overrides,
            // as it does for selection), and the config may have given the
            // button another job.
            if (!surf.core_ready) return 0;
            if (window.app.config.@"right-click-action" != .@"context-menu") return 0;
            const shift = w32.GetKeyState(@intCast(w32.VK_SHIFT)) < 0;
            if (surf.core_surface.mouseCaptured() and !shift) return 0;
            showSurfaceMenu(surf);
            return 0;
        },
        w32.WM_MBUTTONDOWN => {
            if (window.overview) return 0;
            if (window.focusedSurface()) |surf| mouseButton(surf, .press, .middle);
            return 0;
        },
        w32.WM_MBUTTONUP => {
            if (window.overview) return 0;
            if (window.focusedSurface()) |surf| mouseButton(surf, .release, .middle);
            return 0;
        },

        w32.WM_MOUSEWHEEL => {
            if (window.overview) return 0;
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
