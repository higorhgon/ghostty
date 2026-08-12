const std = @import("std");

/// Runtime is the runtime to use for Ghostty. All runtimes do not provide
/// equivalent feature sets.
pub const Runtime = enum {
    /// Will not produce an executable at all when `zig build` is called.
    /// This is only useful if you're only interested in the lib only (macOS).
    none,

    /// GTK4. Rich windowed application. This uses a full GObject-based
    /// approach to building the application.
    gtk,

    /// Native Win32. A minimal hand-rolled Win32/WGL windowed application.
    /// This does NOT have feature parity with the GTK or macOS apps (no
    /// tabs, splits, config UI, command palette, etc.) -- it is an early
    /// skeleton implementing just enough of the apprt contract to open a
    /// window and drive the core terminal engine.
    win32,

    pub fn default(target: std.Target) Runtime {
        return switch (target.os.tag) {
            // The Linux and FreeBSD default is GTK because it is a full
            // featured application.
            .linux, .freebsd => .gtk,
            // Windows defaults to the (currently minimal) native apprt.
            .windows => .win32,
            // Otherwise, we do NONE so we don't create an exe and we create
            // libghostty. On macOS, Xcode is used to build the app that links
            // to libghostty.
            else => .none,
        };
    }
};

test {
    _ = Runtime;
}
