//! The OpenGL device context on Windows.
//!
//! The counterpart of `Device.zig`, which is EGL. All this holds is the
//! root of the WGL share group that every renderer's context joins; see
//! `wgl.zig` for why there is one.
const Device = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const wgl = @import("wgl.zig");

/// Options used when creating the OpenGL device.
pub const Options = struct {
    /// The context every renderer context is to share objects with.
    /// Caller is responsible for managing its lifetime, and it must
    /// outlive the device.
    root: wgl.HGLRC,
};

root: wgl.HGLRC,

pub fn init(alloc: Allocator, options: Options) !*Device {
    const self = try alloc.create(Device);
    self.* = .{ .root = options.root };
    return self;
}

pub fn deinit(self: *Device, alloc: Allocator) void {
    // Do not destroy the root context as it is externally managed.
    alloc.destroy(self);
}
