const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

pub fn main(_: std.process.Init) !void {
    if (std.simd.suggestVectorLength(u8)) |vlen| {
        print("Vector length for u8: {d}\n", .{vlen});
    } else {
        print("No vectors for you\n", .{});
    }
}
