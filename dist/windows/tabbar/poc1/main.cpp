// PoC 1: prove a XAML Island hosts a *system* XAML control (Windows.UI.Xaml)
// inside a plain Win32 window, from C++/WinRT, unpackaged.
//
// This deliberately uses NO NuGet packages and NO MSIX: it only exercises
// the island-hosting machinery itself (WindowsXamlManager +
// DesktopWindowXamlSource + IDesktopWindowXamlSourceNative::AttachToWindow).
// If this doesn't render, nothing further will, so it's the cheapest
// possible go/no-go. WinUI 2's TabView and MSIX packaging come in PoC 2.

#include <windows.h>
// windows.h defines GetCurrentTime as a macro, which collides with the
// XAML animation headers' GetCurrentTime method.
#undef GetCurrentTime
#include <winrt/Windows.Foundation.h>
// Collections and Controls.Primitives must be included explicitly: without
// them the `auto`-returning members they define (IVector::Append,
// ButtonBase::Click) are only forward-declared, and C++/WinRT fails with
// "a function that returns 'auto' cannot be used before it is defined".
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.Xaml.h>
#include <winrt/Windows.UI.Xaml.Hosting.h>
#include <winrt/Windows.UI.Xaml.Controls.h>
#include <winrt/Windows.UI.Xaml.Controls.Primitives.h>
#include <winrt/Windows.UI.Xaml.Media.h>
#include <winrt/Windows.UI.h>
#include <windows.ui.xaml.hosting.desktopwindowxamlsource.h>

#include <cstdio>

using namespace winrt;
using namespace Windows::UI::Xaml;
using namespace Windows::UI::Xaml::Hosting;
using namespace Windows::UI::Xaml::Controls;
using namespace Windows::UI::Xaml::Media;

namespace {

// Log to a file so we can inspect failures even though this is a GUI
// (no-console) process.
void Log(const char* fmt, ...) {
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    FILE* f = nullptr;
    fopen_s(&f, "poc1_log.txt", "a");
    if (f) {
        fprintf(f, "%s\n", buf);
        fclose(f);
    }
    OutputDebugStringA(buf);
    OutputDebugStringA("\n");
}

HWND g_island_hwnd = nullptr;
DesktopWindowXamlSource g_source{nullptr};

LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    switch (msg) {
    case WM_SIZE:
        if (g_island_hwnd) {
            // The island fills the whole client area for this PoC.
            SetWindowPos(g_island_hwnd, nullptr, 0, 0,
                         LOWORD(lparam), HIWORD(lparam), SWP_SHOWWINDOW);
        }
        return 0;
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
}

} // namespace

int WINAPI wWinMain(HINSTANCE hinstance, HINSTANCE, PWSTR, int) {
    Log("=== poc1 start ===");

    // XAML requires a single-threaded apartment.
    init_apartment(apartment_type::single_threaded);
    Log("apartment initialized");

    WNDCLASSEXW wc{};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = WndProc;
    wc.hInstance = hinstance;
    wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"Poc1Window";
    RegisterClassExW(&wc);

    HWND hwnd = CreateWindowExW(
        0, L"Poc1Window", L"XAML Island PoC 1 (system XAML)",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 900, 300,
        nullptr, nullptr, hinstance, nullptr);
    if (!hwnd) {
        Log("FATAL: CreateWindowExW failed, err=%lu", GetLastError());
        return 1;
    }
    Log("host hwnd created");

    try {
        // Boot the XAML runtime for this thread.
        auto manager = WindowsXamlManager::InitializeForCurrentThread();
        Log("WindowsXamlManager::InitializeForCurrentThread OK");

        g_source = DesktopWindowXamlSource();
        Log("DesktopWindowXamlSource constructed");

        // Parent the island into our Win32 HWND. This is the classic
        // (COM) interop path, which is what actually works for system
        // XAML -- unlike the WinUI 3 `Initialize(WindowId)` API.
        auto native = g_source.as<IDesktopWindowXamlSourceNative>();
        check_hresult(native->AttachToWindow(hwnd));
        Log("AttachToWindow OK");

        check_hresult(native->get_WindowHandle(&g_island_hwnd));
        Log("island hwnd = %p", (void*)g_island_hwnd);

        // Simple, unmistakable content: colored panel + text + a real
        // interactive Button, so we can confirm both rendering and that
        // the control is live (hover/press visuals).
        StackPanel panel;
        panel.Background(SolidColorBrush(Windows::UI::Colors::CornflowerBlue()));
        panel.Orientation(Orientation::Vertical);
        panel.Padding(ThicknessHelper::FromUniformLength(20));

        TextBlock label;
        label.Text(L"System XAML is rendering inside a Win32 HWND");
        label.FontSize(22);
        label.Foreground(SolidColorBrush(Windows::UI::Colors::White()));
        panel.Children().Append(label);

        Button button;
        button.Content(box_value(L"I am a real XAML Button"));
        button.Margin(ThicknessHelper::FromLengths(0, 16, 0, 0));
        button.Click([label](auto&&, auto&&) mutable {
            label.Text(L"Button clicked -- input routing works!");
        });
        panel.Children().Append(button);

        g_source.Content(panel);
        Log("content set");
    } catch (hresult_error const& e) {
        Log("FATAL hresult_error 0x%08X: %ls", (unsigned)e.code(), e.message().c_str());
        return 2;
    } catch (...) {
        Log("FATAL: unknown exception");
        return 3;
    }

    RECT rc{};
    GetClientRect(hwnd, &rc);
    if (g_island_hwnd) {
        SetWindowPos(g_island_hwnd, nullptr, 0, 0,
                     rc.right - rc.left, rc.bottom - rc.top, SWP_SHOWWINDOW);
    }

    ShowWindow(hwnd, SW_SHOW);
    UpdateWindow(hwnd);
    Log("window shown, entering message loop");

    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        // Give the island first crack at the message so XAML gets
        // keyboard/accelerator handling (tab navigation, etc).
        BOOL handled = FALSE;
        if (g_source) {
            if (auto native2 = g_source.try_as<IDesktopWindowXamlSourceNative2>()) {
                native2->PreTranslateMessage(&msg, &handled);
            }
        }
        if (!handled) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    Log("=== poc1 exit ===");
    return 0;
}
