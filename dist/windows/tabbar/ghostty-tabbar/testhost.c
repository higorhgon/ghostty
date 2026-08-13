// Plain-C harness for ghostty_tabbar.dll. Deliberately C, not C++: it
// proves the ABI is consumable from a language that knows nothing about
// COM/WinRT, which is exactly Zig's situation.

#include <windows.h>
#include <windowsx.h>  // GET_X_LPARAM / GET_Y_LPARAM
#include <stdio.h>
#include "ghostty_tabbar.h"

static GhosttyTabBar* g_bar = NULL;
static GhosttyTabId g_tabs[64];
static int g_tab_count = 0;

// Packaged apps can't write to their install directory, so the log has to
// live somewhere writable.
static void LogPath(char* out, size_t n) {
    char tmp[MAX_PATH];
    DWORD len = GetTempPathA(MAX_PATH, tmp);
    if (len == 0 || len > MAX_PATH) { strcpy_s(out, n, "testhost_log.txt"); return; }
    _snprintf_s(out, n, _TRUNCATE, "%sghostty_tabbar_testhost.log", tmp);
}

static void Log(const char* fmt, ...) {
    char buf[512];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    char path[MAX_PATH];
    LogPath(path, sizeof(path));
    FILE* f = NULL;
    fopen_s(&f, path, "a");
    if (f) { fprintf(f, "%s\n", buf); fclose(f); }
    OutputDebugStringA(buf);
    OutputDebugStringA("\n");
}

static void OnSelected(void* ctx, GhosttyTabId tab) {
    (void)ctx;
    Log("CALLBACK on_selected tab=%llu", (unsigned long long)tab);
}

// Mirrors what Ghostty will do: the strip asks, we decide, we remove.
static void OnCloseRequested(void* ctx, GhosttyTabId tab) {
    (void)ctx;
    Log("CALLBACK on_close_requested tab=%llu -> removing", (unsigned long long)tab);
    ghostty_tabbar_remove_tab(g_bar, tab);
}

static void OnNewTab(void* ctx, GhosttyProfileId profile) {
    (void)ctx;
    wchar_t title[64];
    if (profile == GHOSTTY_PROFILE_DEFAULT) {
        Log("CALLBACK on_new_tab profile=DEFAULT");
        wcscpy_s(title, 64, L"default shell");
    } else {
        Log("CALLBACK on_new_tab profile=%u", profile);
        swprintf_s(title, 64, L"profile %u", profile);
    }
    GhosttyTabId id = ghostty_tabbar_add_tab(g_bar, title);
    if (g_tab_count < 64) g_tabs[g_tab_count++] = id;
    ghostty_tabbar_set_selected(g_bar, id);
}

static void OnCaption(void* ctx, GhosttyCaptionButton which);
static void OnDragStart(void* ctx);
static void OnDragDoubleClick(void* ctx);

static HWND g_hwnd = NULL;

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    // Remove the system title bar while keeping a real, resizable frame.
    // Letting DefWindowProc compute the client rect and then restoring
    // rc.top gives us the caption's space as client area, which is where
    // the tab strip is drawn.
    case WM_NCCALCSIZE:
        if (wp == TRUE) {
            NCCALCSIZE_PARAMS* p = (NCCALCSIZE_PARAMS*)lp;
            LONG top = p->rgrc[0].top;
            DefWindowProcW(hwnd, msg, wp, lp);
            p->rgrc[0].top = top;
            return 0;
        }
        break;

    // With the caption gone, the top resize edge has to be restored by
    // hand or the window can only be resized from three sides.
    case WM_NCHITTEST: {
        LRESULT hit = DefWindowProcW(hwnd, msg, wp, lp);
        if (hit == HTCLIENT) {
            POINT pt = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
            ScreenToClient(hwnd, &pt);
            if (pt.y < GetSystemMetrics(SM_CYFRAME) +
                       GetSystemMetrics(SM_CXPADDEDBORDER)) {
                return HTTOP;
            }
        }
        return hit;
    }

    case WM_SIZE:
        if (g_bar) {
            // A maximized window with a custom frame is positioned offset
            // by the frame thickness, pushing the top of the client area
            // off-screen. Pad by that much or the strip gets clipped.
            int pad = (wp == SIZE_MAXIMIZED)
                ? GetSystemMetrics(SM_CYFRAME) + GetSystemMetrics(SM_CXPADDEDBORDER)
                : 0;
            // The strip spans the full width at the top -- it *is* the
            // title bar. The terminal surface would occupy everything
            // below it.
            int h = ghostty_tabbar_height(g_bar);
            ghostty_tabbar_resize(g_bar, 0, pad, LOWORD(lp), h);
            ghostty_tabbar_set_maximized(g_bar, wp == SIZE_MAXIMIZED);
        }
        return 0;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

static void OnCaption(void* ctx, GhosttyCaptionButton which) {
    (void)ctx;
    switch (which) {
    case GHOSTTY_CAPTION_MINIMIZE:
        ShowWindow(g_hwnd, SW_MINIMIZE);
        break;
    case GHOSTTY_CAPTION_MAXIMIZE_RESTORE:
        ShowWindow(g_hwnd, IsZoomed(g_hwnd) ? SW_RESTORE : SW_MAXIMIZE);
        break;
    case GHOSTTY_CAPTION_CLOSE:
        PostMessageW(g_hwnd, WM_CLOSE, 0, 0);
        break;
    }
}

// Hand the drag off to the system's own move loop.
static void OnDragStart(void* ctx) {
    (void)ctx;
    ReleaseCapture();
    SendMessageW(g_hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
}

static void OnDragDoubleClick(void* ctx) {
    (void)ctx;
    ShowWindow(g_hwnd, IsZoomed(g_hwnd) ? SW_RESTORE : SW_MAXIMIZE);
}

int WINAPI wWinMain(HINSTANCE hinst, HINSTANCE p, PWSTR c, int s) {
    (void)p; (void)c; (void)s;
    Log("=== testhost start ===");

    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hinst;
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    // Dark fill standing in for where Ghostty's terminal surface would be,
    // so the strip is judged against a realistic backdrop rather than
    // white.
    wc.hbrBackground = CreateSolidBrush(RGB(30, 30, 46));
    wc.lpszClassName = L"GhosttyTabBarTestHost";
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowExW(0, L"GhosttyTabBarTestHost",
        L"ghostty_tabbar.dll test host", WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 1100, 320, NULL, NULL, hinst, NULL);
    if (!hwnd) { Log("FATAL: CreateWindowExW failed"); return 1; }
    g_hwnd = hwnd;

    // Force a WM_NCCALCSIZE now that the frame rules changed, so the
    // caption area is surrendered before the window is first shown.
    SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
                 SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE |
                 SWP_NOZORDER | SWP_NOACTIVATE);

    GhosttyTabBarCallbacks cb = {0};
    cb.ctx = NULL;
    cb.on_selected = OnSelected;
    cb.on_close_requested = OnCloseRequested;
    cb.on_new_tab = OnNewTab;
    cb.on_caption_button = OnCaption;
    cb.on_drag_start = OnDragStart;
    cb.on_drag_double_click = OnDragDoubleClick;

    g_bar = ghostty_tabbar_create(hwnd, cb);
    if (!g_bar) { Log("FATAL: ghostty_tabbar_create returned NULL"); return 2; }
    Log("tabbar created, height=%d", ghostty_tabbar_height(g_bar));

    /* Real paths so the menu shows the shells' own icons. */
    ghostty_tabbar_add_profile(g_bar, 1, L"Command Prompt",
                               L"C:\Windows\System32\cmd.exe");
    ghostty_tabbar_add_profile(g_bar, 2, L"Windows PowerShell",
                               L"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe");
    ghostty_tabbar_add_profile(g_bar, 3, L"PowerShell 7", NULL);
    ghostty_tabbar_add_profile(g_bar, 4, L"Ubuntu (WSL)",
                               L"C:\Windows\System32\wsl.exe");
    ghostty_tabbar_add_profile(g_bar, 5, L"Git Bash",
                               L"C:\Program Files\Git\bin\bash.exe");
    Log("profiles registered");

    g_tabs[g_tab_count++] = ghostty_tabbar_add_tab(g_bar, L"C:\\WINDOWS\\system32\\cmd.exe");
    g_tabs[g_tab_count++] = ghostty_tabbar_add_tab(g_bar, L"pwsh");
    g_tabs[g_tab_count++] = ghostty_tabbar_add_tab(g_bar, L"ghostty");
    ghostty_tabbar_set_selected(g_bar, g_tabs[0]);
    Log("tabs added: %llu %llu %llu",
        (unsigned long long)g_tabs[0], (unsigned long long)g_tabs[1],
        (unsigned long long)g_tabs[2]);

    // Theme it like a dark Ghostty config would.
    ghostty_tabbar_set_theme(g_bar, 30, 30, 46, 1);

    RECT rc;
    GetClientRect(hwnd, &rc);
    ghostty_tabbar_resize(g_bar, 0, 0, rc.right - rc.left, ghostty_tabbar_height(g_bar));

    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    Log("entering message loop");

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0)) {
        if (!ghostty_tabbar_pretranslate(g_bar, &msg)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    ghostty_tabbar_destroy(g_bar);
    Log("=== testhost exit ===");
    return 0;
}
