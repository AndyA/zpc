const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

pub fn main(_: std.process.Init) !void {
    const ints = &.{ u1, u2, u4, u8, u16, u32, u64, u128, u256, u512, u1024, f16, f32, f64 };
    inline for (ints) |int| {
        if (std.simd.suggestVectorLength(int)) |vlen| {
            print("Vector length for {s}: {d}\n", .{ @typeName(int), vlen });
        } else {
            print("No {s} vectors for you\n", .{@typeName(int)});
        }
    }
}
