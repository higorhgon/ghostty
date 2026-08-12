// Plain-C harness for ghostty_tabbar.dll. Deliberately C, not C++: it
// proves the ABI is consumable from a language that knows nothing about
// COM/WinRT, which is exactly Zig's situation.

#include <windows.h>
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

static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    switch (msg) {
    case WM_SIZE:
        if (g_bar) {
            // The island is only as tall as the strip -- matching how
            // Ghostty will lay it out, with the terminal surface below.
            // The shell picker is a Win32 menu precisely because a XAML
            // flyout would be clipped by these bounds.
            int h = ghostty_tabbar_height(g_bar);
            ghostty_tabbar_resize(g_bar, 0, 0, LOWORD(lp), h);
        }
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

int WINAPI wWinMain(HINSTANCE hinst, HINSTANCE p, PWSTR c, int s) {
    (void)p; (void)c; (void)s;
    Log("=== testhost start ===");

    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hinst;
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"GhosttyTabBarTestHost";
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowExW(0, L"GhosttyTabBarTestHost",
        L"ghostty_tabbar.dll test host", WS_OVERLAPPEDWINDOW,
        CW_USEDEFAULT, CW_USEDEFAULT, 1100, 320, NULL, NULL, hinst, NULL);
    if (!hwnd) { Log("FATAL: CreateWindowExW failed"); return 1; }

    GhosttyTabBarCallbacks cb = {0};
    cb.ctx = NULL;
    cb.on_selected = OnSelected;
    cb.on_close_requested = OnCloseRequested;
    cb.on_new_tab = OnNewTab;

    g_bar = ghostty_tabbar_create(hwnd, cb);
    if (!g_bar) { Log("FATAL: ghostty_tabbar_create returned NULL"); return 2; }
    Log("tabbar created, height=%d", ghostty_tabbar_height(g_bar));

    ghostty_tabbar_add_profile(g_bar, 1, L"Command Prompt");
    ghostty_tabbar_add_profile(g_bar, 2, L"Windows PowerShell");
    ghostty_tabbar_add_profile(g_bar, 3, L"PowerShell 7");
    ghostty_tabbar_add_profile(g_bar, 4, L"Ubuntu (WSL)");
    ghostty_tabbar_add_profile(g_bar, 5, L"Git Bash");
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
