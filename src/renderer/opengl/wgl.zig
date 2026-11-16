//! WGL: the Windows platform layer for the OpenGL renderer.
//!
//! Everywhere else the renderer gets its contexts from EGL and hands
//! finished frames to the apprt as DMABUFs. Windows has neither, so this
//! is the equivalent built from what it does have:
//!
//!   - Every renderer gets its own WGL context, current on its render
//!     thread, exactly as the EGL contexts are. A WGL context needs a
//!     device context to exist at all, so each one comes with a hidden
//!     1x1 window that is never shown and never drawn to -- all rendering
//!     goes to framebuffer objects.
//!
//!   - All contexts belong to one share group, rooted at a context the
//!     apprt creates (see `Device.Options`). The apprt's own presenting
//!     contexts are in that group too, so a texture the renderer draws
//!     into on its thread can be read by the apprt on the main thread.
//!     That shared texture (see `Front`) is what stands in for a DMABUF.
//!
//! The contexts are legacy `wglCreateContext` ones, i.e. compatibility
//! profile at the highest version the driver offers. That is deliberate:
//! the apprt's presenting contexts are created the same way (they use a
//! little fixed-function drawing), and sharing between contexts of
//! different profiles is implementation-defined.
const std = @import("std");
const gl = @import("opengl");
const global = @import("../../global.zig");

const log = std.log.scoped(.opengl);

pub const HWND = *opaque {};
pub const HDC = *opaque {};
pub const HGLRC = *opaque {};
const BOOL = c_int;

const PIXELFORMATDESCRIPTOR = extern struct {
    nSize: u16 = @sizeOf(PIXELFORMATDESCRIPTOR),
    nVersion: u16 = 1,
    dwFlags: u32 = 0,
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
    dwLayerMask: u32 = 0,
    dwVisibleMask: u32 = 0,
    dwDamageMask: u32 = 0,
};

const PFD_DOUBLEBUFFER: u32 = 0x00000001;
const PFD_DRAW_TO_WINDOW: u32 = 0x00000004;
const PFD_SUPPORT_OPENGL: u32 = 0x00000020;
const PFD_TYPE_RGBA: u8 = 0;
const PFD_MAIN_PLANE: u8 = 0;
const WS_POPUP: u32 = 0x80000000;

extern "user32" fn CreateWindowExW(
    dwExStyle: u32,
    lpClassName: [*:0]const u16,
    lpWindowName: ?[*:0]const u16,
    dwStyle: u32,
    x: c_int,
    y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?HWND,
    hMenu: ?*anyopaque,
    hInstance: ?*anyopaque,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
extern "user32" fn GetDC(?HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(?HWND, HDC) callconv(.winapi) c_int;
extern "gdi32" fn ChoosePixelFormat(HDC, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) c_int;
extern "gdi32" fn SetPixelFormat(HDC, c_int, *const PIXELFORMATDESCRIPTOR) callconv(.winapi) BOOL;
extern "opengl32" fn wglCreateContext(HDC) callconv(.winapi) ?HGLRC;
extern "opengl32" fn wglDeleteContext(HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglMakeCurrent(?HDC, ?HGLRC) callconv(.winapi) BOOL;
extern "opengl32" fn wglShareLists(HGLRC, HGLRC) callconv(.winapi) BOOL;

/// Set the one pixel format every context in the share group uses.
///
/// Sharing requires that all the contexts involved have the same pixel
/// format, so anything that creates a context that is to see the
/// renderer's textures -- including the apprt, for its windows -- must
/// set up its device context with this rather than choosing its own.
pub fn setPixelFormat(hdc: HDC) !void {
    const pfd: PIXELFORMATDESCRIPTOR = .{
        .dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER,
        .iPixelType = PFD_TYPE_RGBA,
        .cColorBits = 32,
        .cDepthBits = 24,
        .cStencilBits = 8,
        .iLayerType = PFD_MAIN_PLANE,
    };
    const format = ChoosePixelFormat(hdc, &pfd);
    if (format == 0) return error.WglPixelFormatUnavailable;
    if (SetPixelFormat(hdc, format, &pfd) == 0) return error.WglPixelFormatFailed;
}

/// Put `hglrc`, a context that has not created any objects yet, into the
/// share group of `root`.
pub fn share(root: HGLRC, hglrc: HGLRC) !void {
    if (wglShareLists(root, hglrc) == 0) return error.WglShareFailed;
}

/// Load the calling thread's glad function pointers from the WGL context
/// that is current on it.
pub fn loadGlad() !c_int {
    return try gl.glad.load(null);
}

/// A WGL context along with the hidden window it needs to exist.
pub const Context = struct {
    hwnd: HWND,
    hdc: HDC,
    hglrc: HGLRC,

    /// Create a context, in the share group of `root` if there is one.
    ///
    /// The hidden window belongs to the calling thread, which therefore
    /// has to be the one to call `destroy` as well. The context itself
    /// can be made current on any thread.
    pub fn create(root: ?HGLRC) !Context {
        const hwnd = CreateWindowExW(
            0,
            // A system class, which spares us registering one of our own
            // for a window that never receives a message we care about.
            std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
            null,
            WS_POPUP,
            0,
            0,
            1,
            1,
            null,
            null,
            null,
            null,
        ) orelse return error.WglWindowFailed;
        errdefer _ = DestroyWindow(hwnd);

        const hdc = GetDC(hwnd) orelse return error.WglWindowFailed;
        errdefer _ = ReleaseDC(hwnd, hdc);

        try setPixelFormat(hdc);

        const hglrc = wglCreateContext(hdc) orelse return error.WglContextFailed;
        errdefer _ = wglDeleteContext(hglrc);

        if (root) |r| try share(r, hglrc);

        return .{ .hwnd = hwnd, .hdc = hdc, .hglrc = hglrc };
    }

    pub fn destroy(self: Context) void {
        _ = wglDeleteContext(self.hglrc);
        _ = ReleaseDC(self.hwnd, self.hdc);
        _ = DestroyWindow(self.hwnd);
    }

    /// Make the context current on the calling thread.
    pub fn makeCurrent(self: Context) !void {
        if (wglMakeCurrent(self.hdc, self.hglrc) == 0) return error.WglMakeCurrentFailed;
    }

    /// Leave the calling thread with no current context.
    pub fn releaseCurrent() void {
        _ = wglMakeCurrent(null, null);
    }
};

/// The most recently completed frame, in a texture the apprt can read.
///
/// The renderer's own targets are not handed out, because they are
/// recycled by its swap chain and destroyed when the surface is resized,
/// all on the render thread and with no regard for whether the apprt is
/// in the middle of reading one. Each finished frame is copied here
/// instead, under a lock the apprt also takes while it reads.
///
/// The texture is plain RGBA8 holding sRGB-encoded, premultiplied
/// values, bottom row first -- the same contents as the CPU frames the
/// renderer exports elsewhere, just left on the GPU.
pub const Front = struct {
    mutex: std.Io.Mutex = .init,
    texture: ?gl.Texture = null,
    /// Belongs to the render context; framebuffer objects are not shared.
    framebuffer: ?gl.Framebuffer = null,
    width: usize = 0,
    height: usize = 0,
    /// False until the first frame has been copied in, and again while
    /// the texture has been reallocated but not yet drawn to.
    ready: bool = false,

    /// What the apprt needs in order to read the frame.
    pub const View = struct {
        texture: gl.Texture,
        width: usize,
        height: usize,
    };

    /// Copy a finished frame in from `source`, which is `width` by
    /// `height`. Render thread, render context current.
    pub fn update(
        self: *Front,
        source: gl.Framebuffer,
        width: usize,
        height: usize,
    ) !void {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.texture == null or self.width != width or self.height != height) {
            self.ready = false;
            try self.resize(width, height);
        }

        {
            // Bound only now, after any reallocation above, which goes
            // through the framebuffer bindings itself and does not leave
            // them as it found them.
            const read_bind = try source.bind(.read);
            defer read_bind.unbind();
            const draw_bind = try self.framebuffer.?.bind(.draw);
            defer draw_bind.unbind();
            try gl.blitFramebuffer(
                0,
                0,
                @intCast(width),
                @intCast(height),
                0,
                0,
                @intCast(width),
                @intCast(height),
                .{ .color_buffer_bit = true },
                .nearest,
            );
        }

        // The copy has to have landed before the lock is released, since
        // the moment it is the apprt may read the texture from a
        // different context.
        gl.finish();
        self.ready = true;
    }

    fn resize(self: *Front, width: usize, height: usize) !void {
        const texture = self.texture orelse texture: {
            const t = try gl.Texture.create();
            self.texture = t;
            break :texture t;
        };
        {
            const bound = try texture.bind(.@"2d");
            defer bound.unbind();
            try bound.parameter(.min_filter, .nearest);
            try bound.parameter(.mag_filter, .nearest);
            try bound.parameter(.wrap_s, .clamp_to_edge);
            try bound.parameter(.wrap_t, .clamp_to_edge);
            try bound.image2D(
                0,
                .rgba,
                @intCast(width),
                @intCast(height),
                .rgba,
                .unsigned_byte,
                null,
            );
            try bound.parameter(.base_level, 0);
            try bound.parameter(.max_level, 0);
        }

        const framebuffer = self.framebuffer orelse framebuffer: {
            const f = try gl.Framebuffer.create();
            self.framebuffer = f;
            break :framebuffer f;
        };
        {
            const bound = try framebuffer.bind(.framebuffer);
            defer bound.unbind();
            try bound.texture2D(.color0, .@"2d", texture, 0);
            switch (bound.checkStatus()) {
                .complete => {},
                else => |status| {
                    log.warn("front framebuffer incomplete status={}", .{status});
                    return error.FramebufferIncomplete;
                },
            }
        }

        self.width = width;
        self.height = height;
    }

    /// Release the GL objects. Render thread, render context current.
    pub fn deinit(self: *Front) void {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.framebuffer) |f| f.destroy();
        if (self.texture) |t| t.destroy();
        self.framebuffer = null;
        self.texture = null;
        self.ready = false;
    }

    /// Take the lock and return the frame, or null (with the lock not
    /// held) if there is none yet. Every non-null return must be paired
    /// with `unlock`. Any thread.
    pub fn lock(self: *Front) ?View {
        const io = global.io();
        self.mutex.lockUncancelable(io);
        if (self.ready) if (self.texture) |texture| return .{
            .texture = texture,
            .width = self.width,
            .height = self.height,
        };
        self.mutex.unlock(io);
        return null;
    }

    pub fn unlock(self: *Front) void {
        self.mutex.unlock(global.io());
    }
};
