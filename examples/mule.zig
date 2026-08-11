const std = @import("std");

const assert = std.debug.assert;
const print = std.debug.print;
const expectEqualDeep = std.testing.expectEqualDeep;

pub fn main(_: std.process.Init) !void {
    const ints = &.{ u1, u2, u4, u8, u16, u32, u64, u128, u256, u512, f16, f32, f64 };
    inline for (ints) |int| {
        if (std.simd.suggestVectorLength(int)) |vlen| {
            print("Vector length for " ++ @typeName(int) ++ ": {d}\n", .{vlen});
        } else {
            print("No " ++ @typeName(int) ++ " vectors for you\n", .{});
        }
    }
}
