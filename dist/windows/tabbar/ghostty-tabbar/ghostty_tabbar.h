// Flat C ABI over a WinUI 2 TabView hosted in a XAML Island.
//
// Zig can't host XAML directly (it would mean speaking COM/WinRT by hand),
// so this DLL owns everything XAML and exposes only plain C. The division
// of responsibility is deliberate:
//
//   * This DLL is dumb. It draws tabs and reports what the user clicked.
//     It holds no opinion about what a tab *is*.
//   * Ghostty (Zig) keeps all policy: which shells exist, what a tab maps
//     to, when one may close.
//
// Threading: every function must be called on the thread that called
// ghostty_tabbar_create, and that thread must own the message loop. The
// DLL initializes an STA apartment for it.

#ifndef GHOSTTY_TABBAR_H
#define GHOSTTY_TABBAR_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifdef GHOSTTY_TABBAR_EXPORTS
#define GHOSTTY_TABBAR_API __declspec(dllexport)
#else
#define GHOSTTY_TABBAR_API __declspec(dllimport)
#endif

typedef struct GhosttyTabBar GhosttyTabBar;

// Identifies a tab. Allocated by the DLL, opaque to the caller, never
// reused within one tab bar's lifetime.
typedef uint64_t GhosttyTabId;

// Identifies a shell profile in the new-tab dropdown. Chosen by the
// caller (Ghostty), passed back verbatim in on_new_tab.
typedef uint32_t GhosttyProfileId;

// The user clicked a tab. Ghostty should make that tab current.
typedef void (*GhosttyTabSelectedFn)(void* ctx, GhosttyTabId tab);

// The user clicked a tab's close button. The tab is NOT removed by the
// DLL -- Ghostty decides (it may want to prompt) and then calls
// ghostty_tabbar_remove_tab.
typedef void (*GhosttyTabCloseRequestedFn)(void* ctx, GhosttyTabId tab);

// The user asked for a new tab. `profile` is GHOSTTY_PROFILE_DEFAULT when
// they clicked the plain "+" rather than picking from the dropdown.
typedef void (*GhosttyNewTabFn)(void* ctx, GhosttyProfileId profile);

#define GHOSTTY_PROFILE_DEFAULT ((GhosttyProfileId)0xFFFFFFFFu)

// Which caption button was pressed. The strip doubles as the title bar
// (Windows Terminal style), so it draws these itself -- removing the
// system title bar also removes the system's buttons.
typedef enum {
    GHOSTTY_CAPTION_MINIMIZE = 0,
    GHOSTTY_CAPTION_MAXIMIZE_RESTORE = 1,
    GHOSTTY_CAPTION_CLOSE = 2,
} GhosttyCaptionButton;

typedef void (*GhosttyCaptionFn)(void* ctx, GhosttyCaptionButton button);

// The user pressed the empty part of the strip. The host should begin a
// window drag, conventionally:
//     ReleaseCapture();
//     SendMessage(hwnd, WM_NCLBUTTONDOWN, HTCAPTION, 0);
//
// This callback exists because the island is a child HWND and therefore
// consumes the mouse: WM_NCHITTEST on the parent never sees these points,
// so the strip cannot become draggable by hit-testing alone.
typedef void (*GhosttyDragStartFn)(void* ctx);

// The user double-clicked the empty strip, which by convention toggles
// maximize.
typedef void (*GhosttyDragDoubleClickFn)(void* ctx);

typedef struct {
    void* ctx;
    GhosttyTabSelectedFn on_selected;
    GhosttyTabCloseRequestedFn on_close_requested;
    GhosttyNewTabFn on_new_tab;
    GhosttyCaptionFn on_caption_button;
    GhosttyDragStartFn on_drag_start;
    GhosttyDragDoubleClickFn on_drag_double_click;
} GhosttyTabBarCallbacks;

// Creates the tab strip as a child of `parent_hwnd`. Returns NULL on
// failure. `parent_hwnd` is a HWND (void* to keep windows.h out of this
// header).
GHOSTTY_TABBAR_API GhosttyTabBar* ghostty_tabbar_create(
    void* parent_hwnd, GhosttyTabBarCallbacks callbacks);

GHOSTTY_TABBAR_API void ghostty_tabbar_destroy(GhosttyTabBar* bar);

// Natural height of the strip in physical pixels at the current DPI.
// Ghostty uses this to lay out the terminal area below it.
GHOSTTY_TABBAR_API int32_t ghostty_tabbar_height(GhosttyTabBar* bar);

GHOSTTY_TABBAR_API void ghostty_tabbar_resize(
    GhosttyTabBar* bar, int32_t x, int32_t y, int32_t width, int32_t height);

// Must be called from the message loop before TranslateMessage so the
// island receives keyboard input. Returns non-zero if the island consumed
// the message, in which case the caller must not dispatch it.
GHOSTTY_TABBAR_API int32_t ghostty_tabbar_pretranslate(
    GhosttyTabBar* bar, void* msg);

// `title` is UTF-16. Returns 0 on failure.
GHOSTTY_TABBAR_API GhosttyTabId ghostty_tabbar_add_tab(
    GhosttyTabBar* bar, const wchar_t* title);

GHOSTTY_TABBAR_API void ghostty_tabbar_remove_tab(
    GhosttyTabBar* bar, GhosttyTabId tab);

GHOSTTY_TABBAR_API void ghostty_tabbar_set_title(
    GhosttyTabBar* bar, GhosttyTabId tab, const wchar_t* title);

// Selects a tab without firing on_selected (this is Ghostty telling the
// strip about a change, not the user driving it).
GHOSTTY_TABBAR_API void ghostty_tabbar_set_selected(
    GhosttyTabBar* bar, GhosttyTabId tab);

// Adds an entry to the new-tab dropdown. Call once per available shell,
// in display order, before or after creation.
//
// `icon_path` is any file whose shell icon should represent the entry --
// the shell's own executable, or for a WSL distribution its Start Menu
// shortcut, which carries the distro logo. May be NULL for no icon.
GHOSTTY_TABBAR_API void ghostty_tabbar_add_profile(
    GhosttyTabBar* bar, GhosttyProfileId profile, const wchar_t* name,
    const wchar_t* icon_path);

GHOSTTY_TABBAR_API void ghostty_tabbar_clear_profiles(GhosttyTabBar* bar);

// Matches the strip to Ghostty's configured theme. `dark` selects the
// light/dark resource set; the RGB triple paints the strip background so
// it blends into the terminal below.
GHOSTTY_TABBAR_API void ghostty_tabbar_set_theme(
    GhosttyTabBar* bar, uint8_t r, uint8_t g, uint8_t b, int32_t dark);

// Swaps the maximize glyph for the restore glyph and back. Call from the
// host's WM_SIZE so the button reflects the real window state.
GHOSTTY_TABBAR_API void ghostty_tabbar_set_maximized(
    GhosttyTabBar* bar, int32_t maximized);

#ifdef __cplusplus
}
#endif

#endif // GHOSTTY_TABBAR_H
