const std = @import("std");

const Io = std.Io;
const assert = std.debug.assert;
const print = std.debug.print;
const expectEqualDeep = std.testing.expectEqualDeep;

fn IntRep(T: type) type {
    return struct {
        pub const Bits = @typeInfo(T).int.bits;
        pub const U = @Int(.unsigned, Bits);
        pub const Shift = @Int(.unsigned, std.math.log2_int_ceil(u16, Bits));
        pub const BitCount = @Int(.unsigned, std.math.log2_int_ceil(u16, Bits) + 1);
        pub const Signed = T != U;

        fn toUnsigned(value: T) U {
            return @bitCast(value);
        }

        fn fromUnsigned(value: U) T {
            return @bitCast(value);
        }
    };
}

pub fn KnownRange(T: type) type {
    const R = IntRep(T);

    return struct {
        const Self = @This();
        pub const empty: Self = .{
            .min = std.math.minInt(T),
            .max = std.math.maxInt(T),
        };

        min: T,
        max: T,

        pub fn init(min: T, max: T) Self {
            assert(min <= max);
            return .{ .min = min, .max = max };
        }

        pub fn initExact(value: T) Self {
            return .init(value, value);
        }

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            try writer.print("{d}..{d}", .{ self.min, self.max });
        }

        pub fn isExact(self: Self) bool {
            assert(self.min <= self.max);
            return self.min == self.max;
        }

        pub fn eql(self: Self, other: Self) bool {
            assert(self.min <= self.max);
            assert(other.min <= other.max);
            return self.min == other.min and self.max == other.max;
        }

        pub fn narrow(self: Self, other: Self) Self {
            assert(self.min <= self.max);
            assert(other.min <= other.max);
            return .init(@max(self.min, other.min), @min(self.max, other.max));
        }

        pub fn widen(self: Self, other: Self) Self {
            assert(self.min <= self.max);
            assert(other.min <= other.max);
            return .init(@min(self.min, other.min), @max(self.max, other.max));
        }

        fn countLeadingSignBits(value: T) R.BitCount {
            const uv = R.toUnsigned(value);
            return (if (value < 0) @clz(~uv) else @clz(uv)) - 1;
        }

        pub fn toBits(self: Self) KnownBits(T) {
            assert(self.min <= self.max);
            if (self.isExact())
                return .initExact(self.min);

            const sign = if ((self.min < 0) == (self.max < 0)) 0 else @min(
                countLeadingSignBits(self.min),
                countLeadingSignBits(self.max),
            );

            const sign_mask = @as(R.U, std.math.maxInt(R.U)) >>
                @as(R.Shift, @intCast(sign));
            const u_min = R.toUnsigned(self.min);
            const u_max = R.toUnsigned(self.max);
            const same_msb = @clz((u_min & sign_mask) ^ (u_max & sign_mask));
            assert(same_msb < R.Bits);
            const mask: R.U = sign_mask & ~(@as(R.U, std.math.maxInt(R.U)) >>
                @as(R.Shift, @intCast(same_msb)));
            return .initSigned(u_min & mask, ~u_min & mask, sign);
        }
    };
}

test KnownRange {
    const KR = KnownRange(u32);
    try expectEqualDeep(KR.init(4, 5), KR.init(3, 5).narrow(KR.init(4, 8)));
}

pub fn KnownBits(T: type) type {
    const R = IntRep(T);

    return struct {
        const Self = @This();
        pub const empty: Self = .{ .set = 0, .clear = 0, .sign = 0 };

        /// 1 for every known 1 bit
        set: R.U,

        /// 1 for every known 0 bit
        clear: R.U,

        /// The number of sign extensions bits; for example an i16 that can be
        /// either -1 or 0 would be modelled as `sssssssssssssssx` indicating
        /// that the only significant bit is the least significant one and all
        /// bits to the left of that are populated by sign extension. In that
        /// case `sign` would be 15 and both `set` and `clear` would be 0.
        sign: R.BitCount,

        pub fn initSigned(set: R.U, clear: R.U, sign: R.BitCount) Self {
            const self: Self = .{ .set = set, .clear = clear, .sign = sign };
            self.assertValid();
            return self;
        }

        pub fn init(set: R.U, clear: R.U) Self {
            return initSigned(set, clear, 0);
        }

        pub fn initExact(value: T) Self {
            const uv = R.toUnsigned(value);
            return .init(uv, ~uv);
        }

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            var buf: [R.Bits]u8 = undefined;
            const sign_mask = self.signMask();
            for (0..R.Bits) |b| {
                const mask: R.U = @as(R.U, 1) << @as(R.Shift, @intCast(R.Bits - b - 1));
                buf[b] = if (self.clear & mask != 0) '0' // known 0
                    else if (self.set & mask != 0) '1' // known 1
                    else if (sign_mask & mask != 0) 's' // sign extension
                    else 'x'; // unknown
            }
            _ = try writer.write(&buf);
        }

        fn signMask(self: Self) R.U {
            assert(self.sign < R.Bits);
            return ~(@as(R.U, std.math.maxInt(R.U)) >>
                @as(R.Shift, @intCast(self.sign)));
        }

        fn assertValid(self: Self) void {
            if (!R.Signed)
                assert(self.sign == 0);
            const sign_mask = self.signMask();
            assert(sign_mask & self.set & self.clear == 0);

            // If we're handling sign extension it's axiomatic that we should
            // not know the value of the bit to the immediate right of the sign
            // extension bits. If we know that bit is 0 or 1 then we know the
            // sign of the value and don't need sign extension.
            assert(sign_mask >> 1 & (self.set | self.clear) == 0);
        }

        pub fn isExact(self: Self) bool {
            self.assertValid();
            return self.set == ~self.clear;
        }

        pub fn eql(self: Self, other: Self) bool {
            self.assertValid();
            other.assertValid();
            return self.set == other.set and
                self.clear == other.clear and
                self.sign == other.sign;
        }

        pub fn narrow(self: Self, other: Self) Self {
            self.assertValid();
            other.assertValid();
            return .initSigned(
                self.set | other.set,
                self.clear | other.clear,
                @max(self.sign, other.sign),
            );
        }

        pub fn widen(self: Self, other: Self) Self {
            self.assertValid();
            other.assertValid();
            return .initSigned(
                self.set & other.set,
                self.clear & other.clear,
                @min(self.sign, other.sign),
            );
        }

        fn simpleRange(set: R.U, clear: R.U) KnownRange(T) {
            if (set == ~clear) // exact?
                return .initExact(R.fromUnsigned(set));

            const known = ~(set | clear);

            const known_msbs = @clz(known);
            assert(known_msbs < R.Bits);

            const left: KnownRange(T) = blk: {
                // If we're signed and don't know the MSB the range crosses zero
                if (R.Signed and known_msbs == 0)
                    break :blk .init(std.math.minInt(T), std.math.maxInt(T));

                const mask = @as(R.U, std.math.maxInt(R.U)) >>
                    @as(R.Shift, @intCast(known_msbs));

                // This works either side of the zero line.
                break :blk .init(
                    R.fromUnsigned(set & ~mask),
                    R.fromUnsigned(set | mask),
                );
            };

            const known_lsbs = @ctz(known);
            assert(known_lsbs + known_msbs < R.Bits);

            return blk: {
                const mask = @as(R.U, std.math.maxInt(R.U)) <<
                    @as(R.Shift, @intCast(known_lsbs));
                const fill = set & ~mask;
                const min = R.fromUnsigned(R.toUnsigned(left.min) & mask | fill);
                const max = R.fromUnsigned(R.toUnsigned(left.max) & mask | fill);
                break :blk .init(min, max);
            };
        }

        pub fn toRange(self: Self) KnownRange(T) {
            self.assertValid();
            if (self.sign == 0)
                return simpleRange(self.set, self.clear);

            // print("sign={d}\n", .{self.sign});
            const sign_mask = ~(if (self.sign + 1 == R.Bits)
                0
            else
                @as(R.U, std.math.maxInt(R.U)) >>
                    @as(R.Shift, @intCast(self.sign + 1)));
            const pos_range = simpleRange(self.set, self.clear | sign_mask);
            const neg_range = simpleRange(self.set | sign_mask, self.clear);
            return .init(neg_range.min, pos_range.max);
        }
    };
}

test KnownBits {
    try expectEqualDeep(
        KnownRange(u32).initExact(123),
        KnownBits(u32).initExact(123).toRange(),
    );
}

pub fn KnownDomain(T: type) type {
    return struct {
        const Self = @This();
        const Range = KnownRange(T);
        const Bits = KnownBits(T);
        pub const empty: Self = .{};

        range: Range = .empty,
        bits: Bits = .empty,

        pub fn initRange(range: Range) Self {
            return .{ .range = range };
        }

        pub fn initBits(bits: Bits) Self {
            return .{ .bits = bits };
        }

        pub fn initExact(value: T) Self {
            return .{ .range = .initExact(value), .bits = .initExact(value) };
        }

        pub fn eql(self: Self, other: Self) bool {
            return self.range.eql(other.range) and
                self.bits.eql(other.bits);
        }

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            try writer.print(
                "range: {f} bits: {f}",
                .{ self.range, self.bits },
            );
        }

        pub fn narrowRange(self: Self, range: Range) Self {
            return .{
                .range = self.range.narrow(range),
                .bits = self.bits,
            };
        }

        pub fn narrowBits(self: Self, bits: Bits) Self {
            return .{
                .range = self.range,
                .bits = self.bits.narrow(bits),
            };
        }

        pub fn narrow(self: Self, other: Self) Self {
            return .{
                .range = self.range.narrow(other.range),
                .bits = self.bits.narrow(other.bits),
            };
        }

        pub fn widen(self: Self, other: Self) Self {
            return .{
                .range = self.range.widen(other.range),
                .bits = self.bits.widen(other.bits),
            };
        }

        pub fn refine(self: Self) Self {
            var res = self;
            while (true) {
                const prev = res;
                res.bits = res.bits.narrow(res.range.toBits());
                res.range = res.range.narrow(res.bits.toRange());
                if (prev.eql(res))
                    return res;
            }
        }
    };
}

test KnownDomain {}

pub fn main(_: std.process.Init) !void {
    const KDU = KnownDomain(u16);
    const KDS = KnownDomain(i16);

    const kdu1: KDU = .initRange(.init(64, 127));
    print("kdu1: {f} -> {f}\n", .{ kdu1, kdu1.refine() });

    const kds1: KDS = .initRange(.init(-300, -1));
    print("kds1: {f} -> {f}\n", .{ kds1, kds1.refine() });

    const kds2: KDS = .initRange(.init(-1, 0));
    print("kds2: {f} -> {f}\n", .{ kds2, kds2.refine() });

    const kds3: KDS = .initRange(.init(-32768, 32767));
    print("kds3: {f} -> {f}\n", .{ kds3, kds3.refine() });

    const kds4: KDS = .initRange(.init(-15, 15));
    print("kds4: {f} -> {f}\n", .{ kds4, kds4.refine() });

    const kds5: KDS = .initRange(.init(0, 1));
    print("kds5: {f} -> {f}\n", .{ kds5, kds5.refine() });

    const kds6: KDS = .initBits(.initSigned(0x2a, 0x55, 8));
    print("kds6: {f} -> {f}\n", .{ kds6, kds6.refine() });

    const kds7: KDS = .initExact(0x55aa);
    print("kds7: {f} -> {f}\n", .{ kds7, kds7.refine() });

    const kds8: KDS = .initRange(.initExact(0x55aa));
    print("kds8: {f} -> {f}\n", .{ kds8, kds8.refine() });
}
