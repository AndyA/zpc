//! Quantify the number of times a match may repeat. Useful constants:
//!
//! * .zeroOrMore
//! * .zeroOrOne
//! * .oneOrMore
//! * .one
//!

const std = @import("std");

const Self = @This();
const assert = std.debug.assert;

/// Match zero or more times (*)
pub const zeroOrMore: Self = .{};
/// Match zero or one times (?)
pub const zeroOrOne: Self = .{ .max = 1 };
/// Match one or more times (+)
pub const oneOrMore: Self = .{ .min = 1 };
/// Match exactly once
pub const one: Self = exactly(1);

/// Match between `min` and `max` times (inclusive)
pub fn range(min: usize, max: usize) Self {
    assert(min <= max);
    return .{ .min = min, .max = max };
}

/// Match exactly `n` times
pub fn exactly(n: usize) Self {
    return range(n, n);
}

pub fn bounded(self: Self) bool {
    return self.max != std.math.maxInt(usize);
}

/// The minimum number of times to match
min: usize = 0,
/// The maximum number of times to match
max: usize = std.math.maxInt(usize),
