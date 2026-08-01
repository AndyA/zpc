//! Build a line number index for a chunk of text. Newlines are
//! "\n" | "\r\n" | "\r"

const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const Allocator = std.mem.Allocator;

/// Count the number of newlines in a text. A newline is defined as LF, CR or CRLF. We
/// don't allow LFCR because we're not barbarians.
pub fn countNewlines(T: type, text: []const T) u32 {
    var lines: u32 = 0;
    var pos: u32 = 0;

    if (std.simd.suggestVectorLength(T)) |vlen| {
        const V = @Vector(vlen, T);
        const cr_splat: V = @splat('\r');
        const lf_splat: V = @splat('\n');
        const drop_last: @Vector(vlen, bool) = @as([vlen - 1]bool, @splat(true)) ++
            @as([1]bool, @splat(false));

        // Stride through the text in overlapping chunks of vlen - 1 chars
        while (pos + vlen <= text.len) : (pos += vlen - 1) {
            const chars: V = text[pos..][0..vlen].*;
            const cr_set = std.simd.shiftElementsRight(chars == cr_splat, 1, false);
            const lf_set = chars == lf_splat;
            const all_set = lf_set & drop_last | cr_set & (~lf_set | drop_last);
            lines += std.simd.countTrues(all_set);
        }
    }

    while (pos != text.len) : (pos += 1) {
        switch (text[pos]) {
            '\n' => {
                lines += 1;
            },
            '\r' => {
                if (pos + 1 != text.len and text[pos + 1] == '\n')
                    pos += 1;
                lines += 1;
            },
            else => {},
        }
    }

    return lines;
}

test countNewlines {
    @setEvalBranchQuota(std.math.maxInt(u32));
    const maxInt = std.math.maxInt;
    const cnl = countNewlines;
    try expectEqual(0, cnl(u8, "Hello, World"));
    try expectEqual(2, cnl(u8, "Hello, World\nGoodnight Berlin\n"));
    try expectEqual(3, cnl(u8, "\n\n\n"));
    try expectEqual(3, cnl(u8, "\r\r\r"));
    try expectEqual(3, cnl(u8, "\r\n\r\n\r\n"));
    try expectEqual(4, cnl(u8, "\n\r\n\r\n\r"));
    try expectEqual(6, cnl(u8, "\r \n \r \n \r \n"));

    // Permutations of padding to stress SIMD version.
    inline for (1..255) |pad_len| {
        const pad: [pad_len]u8 = @splat('X');
        inline for (.{ "", pad }) |lp| {
            inline for (.{ "", pad }) |rp| {
                try expectEqual(3, cnl(u8, lp ++ "\n" ++ pad ++ "\n" ++ pad ++ "\n" ++ rp));
                try expectEqual(3, cnl(u8, lp ++ "\r" ++ pad ++ "\r" ++ pad ++ "\r" ++ rp));
                try expectEqual(3, cnl(u8, lp ++ "\r\n" ++ pad ++ "\r\n" ++ pad ++ "\r\n" ++ rp));
                try expectEqual(6, cnl(u8, lp ++ "\n\r" ++ pad ++ "\n\r" ++ pad ++ "\n\r" ++ rp));
            }
        }
    }

    try expectEqual(3, cnl(u21, &.{ '\r', '\r', '\r' }));
    try expectEqual(3, cnl(u32, &.{ '\r', '\r', '\r' }));
    try expectEqual(3, cnl(
        u32,
        &.{ '\r', maxInt(u32), '\r', maxInt(u32), '\r' },
    ));
}

pub fn LineIndex(T: type) type {
    return struct {
        const Self = @This();

        pub const Location = struct { line: u32, column: u32 };

        index: []u32 = undefined,

        pub fn init(allocator: Allocator, text: []const T) error{OutOfMemory}!Self {
            const lines = countNewlines(T, text) + 1;
            var index = try allocator.alloc(u32, lines + 1);

            index[0] = 0;

            var index_pos: u32 = 1;
            var text_pos: u32 = 0;
            while (text_pos != text.len) : (text_pos += 1) {
                switch (text[text_pos]) {
                    '\n' => {
                        index[index_pos] = text_pos + 1;
                        index_pos += 1;
                    },
                    '\r' => {
                        if (text_pos + 1 != text.len and text[text_pos + 1] == '\n')
                            text_pos += 1;

                        index[index_pos] = text_pos + 1;
                        index_pos += 1;
                    },
                    else => {},
                }
            }

            assert(index_pos == lines);
            index[index_pos] = @intCast(text.len);

            return .{ .index = index };
        }

        pub fn lookupOffset(self: Self, offset: u32) ?Location {
            var low: usize = 0;
            var high: usize = self.index.len - 1;

            while (low < high) {
                // Avoid overflowing in the midpoint calculation
                const mid = low + (high - low) / 2;
                if (self.index[mid] < offset)
                    high = mid
                else if (self.index[mid + 1] >= offset)
                    low = mid + 1
                else
                    return .{ .line = mid, .column = offset - self.index[mid] };
            }
            return null;
        }
    };
}
