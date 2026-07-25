const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

fn alloc(_: *anyopaque, _: usize, _: Alignment, _: usize) ?[*]u8 {
    unreachable;
}
fn resize(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) bool {
    unreachable;
}
fn remap(_: *anyopaque, _: []u8, _: Alignment, _: usize, _: usize) ?[*]u8 {
    unreachable;
}
fn free(_: *anyopaque, _: []u8, _: Alignment, _: usize) void {
    unreachable;
}

pub const non_allocator: Allocator = .{
    .ptr = @ptrCast(@constCast(&alloc)),
    .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free },
};

pub fn ComptimeArrayList(comptime T: type) type {
    return struct {
        const Self = @This();
        items: []const T = &[_]T{},

        pub const empty: Self = .{};

        pub fn deinit(comptime _: *Self, comptime _: Allocator) void {}

        pub fn append(
            comptime self: *Self,
            comptime _: Allocator,
            comptime item: T,
        ) error{OutOfMemory}!void {
            self.items = self.items ++ .{item};
        }

        pub fn appendSlice(
            comptime self: *Self,
            comptime _: Allocator,
            comptime items: []const T,
        ) error{OutOfMemory}!void {
            self.items = self.items ++ items;
        }

        pub fn toOwnedSlice(comptime self: *Self, comptime _: Allocator) error{OutOfMemory}![]const T {
            return self.items;
        }
    };
}
