const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const ct = @import("comptime.zig");

pub const ZpcError = error{OutOfMemory};

pub const ZpcPhase = enum { comp, run };

pub fn ZpcToken(comptime Tag: type, comptime phase: ZpcPhase) type {
    return struct {
        const Self = @This();
        pub const ArrayList = switch (phase) {
            .comp => ct.ComptimeArrayList(Self),
            .run => std.ArrayList(Self),
        };
        pub const NOP: Tag = @enumFromInt(0);

        pub const nothing: Self = .{ .tag = NOP, .value = .{ .nothing = {} } };

        pub const Formatter = struct {
            token: *const Self,
            pretty: bool = false,
            depth: usize = 0,

            fn indent(self: @This(), writer: *Io.Writer) Io.Writer.Error!void {
                if (self.pretty)
                    for (0..self.depth) |_|
                        try writer.print("    ", .{});
            }

            fn newLine(self: @This(), writer: *Io.Writer) Io.Writer.Error!void {
                if (self.pretty)
                    try writer.print("\n", .{});
            }

            pub fn format(self: @This(), writer: *Io.Writer) Io.Writer.Error!void {
                try self.indent(writer);
                try writer.print(
                    "{s}/{s}",
                    .{ @tagName(self.token.value), @tagName(self.token.tag) },
                );

                switch (self.token.value) {
                    .nothing => {},
                    .slice => |slice| try writer.print(" \"{s}\"", .{slice}),
                    .list, .flat => |list| {
                        try writer.print("(", .{});
                        if (list.len != 0) {
                            try self.newLine(writer);
                            for (list, 0..) |item, i| {
                                const child: Formatter = .{
                                    .token = &item,
                                    .pretty = self.pretty,
                                    .depth = self.depth + 1,
                                };
                                try writer.print("{f}", .{child});
                                if (!self.pretty and i != list.len - 1)
                                    try writer.print(", ", .{});
                            }
                            try self.indent(writer);
                        }
                        try writer.print(")", .{});
                    },
                }
                try self.newLine(writer);
            }
        };

        tag: Tag = NOP,
        value: union(enum(u8)) {
            nothing: void,
            slice: []const u8,
            list: []const Self,
            flat: []const Self, // Like a list but flattens into its parent
        },

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            try (Formatter{ .token = &self }).format(writer);
        }

        pub fn initSlice(tag: Tag, slice: []const u8) Self {
            return .{ .tag = tag, .value = .{ .slice = slice } };
        }

        pub fn initList(tag: Tag, list: []const Self) Self {
            return .{ .tag = tag, .value = .{ .list = list } };
        }

        pub fn initArrayList(alloc: Allocator, tag: Tag, array: *ArrayList) ZpcError!Self {
            const list = try array.toOwnedSlice(alloc);
            return initList(tag, list);
        }

        pub fn isNothing(self: Self) bool {
            return self.value == .nothing;
        }

        pub fn appendArrayList(self: Self, alloc: Allocator, array: *ArrayList) ZpcError!void {
            switch (self.value) {
                .nothing => {},
                .slice, .list => try array.append(alloc, self),
                .flat => |flat| {
                    defer self.deinitShallow(alloc);
                    try array.appendSlice(alloc, flat);
                },
            }
        }

        pub fn deinit(self: Self, alloc: Allocator) void {
            switch (self.value) {
                .list, .flat => |list| deinitList(list, alloc),
                .nothing, .slice => {},
            }
        }

        pub fn deinitShallow(self: Self, alloc: Allocator) void {
            switch (self.value) {
                .list, .flat => |list| alloc.free(list),
                .nothing, .slice => {},
            }
        }

        pub fn deinitList(list: []const Self, alloc: Allocator) void {
            for (list) |item| item.deinit(alloc);
            alloc.free(list);
        }

        pub fn deinitArrayList(list: *ArrayList, alloc: Allocator) void {
            for (list.items) |item| item.deinit(alloc);
            list.deinit(alloc);
        }

        pub fn children(self: Self) []const Self {
            return switch (self.value) {
                .flat, .list => |l| l,
                else => unreachable,
            };
        }

        pub fn head(self: Self) Self {
            return self.children()[0];
        }

        pub fn tail(self: Self) []const Self {
            return self.children()[1..];
        }

        pub fn other(self: Self) Self {
            const l = self.children();
            assert(l.len == 2);
            return l[1];
        }
    };
}

pub fn ZpcResult(comptime Token: type) type {
    return struct {
        const Self = @This();
        // const Token = ZpcToken(Tag, .run);

        pub const Formatter = struct {
            token: *const Self,
            pretty: bool = false,

            pub fn format(self: @This(), writer: *Io.Writer) Io.Writer.Error!void {
                const token = self.token;
                switch (token.tok) {
                    .ok => |ok| {
                        try (Token.Formatter{
                            .token = &ok,
                            .pretty = self.pretty,
                        }).format(writer);
                    },
                    .fail => |fail| {
                        try writer.print("FAIL at {s}", .{fail});
                        if (self.pretty)
                            try writer.print("\n", .{});
                    },
                }

                if (token.rest.len != 0) {
                    if (!self.pretty)
                        try writer.print(" ", .{});

                    if (token.rest.len > 30)
                        try writer.print("rest: \"{s}...\"", .{token.rest[0..30]})
                    else
                        try writer.print("rest: \"{s}\"", .{token.rest});
                }
            }
        };

        tok: union(enum) {
            ok: Token,
            fail: []const u8,
        },
        rest: []const u8,

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            try (Formatter{ .token = &self, .pretty = true }).format(writer);
        }

        pub fn initFail(at: []const u8, rest: []const u8) Self {
            return .{ .tok = .{ .fail = at }, .rest = rest };
        }

        pub fn initFailHere(rest: []const u8) Self {
            return initFail(rest, rest);
        }

        pub fn initOk(value: Token, rest: []const u8) Self {
            return .{ .tok = .{ .ok = value }, .rest = rest };
        }

        pub fn deinit(self: Self, alloc: Allocator) void {
            switch (self.tok) {
                .ok => |ok| ok.deinit(alloc),
                .fail => {},
            }
        }

        pub fn deinitShallow(self: Self, alloc: Allocator) void {
            switch (self.tok) {
                .ok => |ok| ok.deinitShallow(alloc),
                .fail => {},
            }
        }

        pub fn matched(self: Self) bool {
            return self.tok == .ok;
        }
    };
}

pub fn ZpcParser(comptime Context: type, comptime Result: type) type {
    return fn (ctx: Context, input: []const u8) ZpcError!Result;
}

pub fn ZpcParserForTag(
    comptime Context: type,
    comptime Tag: type,
    comptime phase: ZpcPhase,
) type {
    return ZpcParser(Context, ZpcResult(ZpcToken(Tag, phase)));
}

const TestTag = enum(u8) {
    // Don't call it NOP so we don't use it by mistake.
    NOT_NOP,
    HELLO,
    FOO,
    BAR,
    NEWLINE,
    DIGIT,
    ALPHA,
    MULTI,
    IDENT,
    PLUS,
    MINUS,
    OPEN,
    CLOSE,
    SEQ,
    NEST,
    TERM,
    MANY,
    ALNUM,
    ARRAY,
    REST,
};

const TestToken = ZpcToken(TestTag, .run);
const TestResult = ZpcResult(TestToken);

const TestContext = struct {
    allocator: Allocator,
    expr: *const ZpcParser(@This(), TestResult) = undefined,
};

fn checkAndConsume(
    ctx: TestContext,
    expected: TestResult,
    actual: TestResult,
) !void {
    defer actual.deinit(ctx.allocator);
    try expectEqualDeep(expected, actual);
}

pub const Predicate = fn (char: u8) bool;

pub fn predAny() Predicate {
    const shim = struct {
        fn pred(_: u8) bool {
            return true;
        }
    };
    return shim.pred;
}

pub fn predAnd(a: Predicate, b: Predicate) Predicate {
    const shim = struct {
        fn pred(char: u8) bool {
            return a(char) and b(char);
        }
    };
    return shim.pred;
}

pub fn predOr(a: Predicate, b: Predicate) Predicate {
    const shim = struct {
        fn pred(char: u8) bool {
            return a(char) or b(char);
        }
    };
    return shim.pred;
}

pub fn predNot(p: Predicate) Predicate {
    const shim = struct {
        fn pred(char: u8) bool {
            return !p(char);
        }
    };
    return shim.pred;
}

pub fn predEqual(want: u8) Predicate {
    const shim = struct {
        fn pred(char: u8) bool {
            return char == want;
        }
    };
    return shim.pred;
}

pub fn predSet(charset: []const u8) Predicate {
    const shim = struct {
        fn pred(char: u8) bool {
            return std.mem.containsAtLeastScalar(u8, charset, char, 1);
        }
    };
    return shim.pred;
}

pub fn Zpc(comptime Context: type, comptime Tag: type) type {
    return make_zpc(Context, Tag, .run);
}

pub fn ZpcComptime(comptime Context: type, comptime Tag: type) type {
    return make_zpc(Context, Tag, .comp);
}

fn make_zpc(comptime Context: type, comptime Tag: type, phase: ZpcPhase) type {
    if (!@hasField(Context, "allocator"))
        @compileError("Context must have an allocator field");
    return struct {
        pub const Token = ZpcToken(Tag, phase);
        pub const Result = ZpcResult(Token);
        pub const Parser = ZpcParser(Context, Result);
        pub const Mapper = fn (ctx: Context, result: Result) ZpcError!Result;

        pub const Quantifier = struct {
            const Self = @This();
            pub const zeroOrMore: Self = .{};
            pub const zeroOrOne: Self = .{ .max = 1 };
            pub const oneOrMore: Self = .{ .min = 1 };
            pub const one: Self = exactly(1);

            pub fn range(min: usize, max: usize) Self {
                assert(min <= max);
                return .{ .min = min, .max = max };
            }

            pub fn exactly(n: usize) Self {
                return range(n, n);
            }

            min: usize = 0,
            max: usize = std.math.maxInt(usize),
        };

        pub fn keyword(tag: Tag, str: []const u8) Parser {
            assert(str.len != 0);
            const shim = struct {
                fn keywordParser(_: Context, input: []const u8) ZpcError!Result {
                    if (input.len >= str.len and std.mem.eql(u8, input[0..str.len], str))
                        return .initOk(.initSlice(tag, str), input[str.len..]);
                    return .initFailHere(input);
                }
            };
            return shim.keywordParser;
        }

        pub fn literal(str: []const u8) Parser {
            return keyword(Token.NOP, str);
        }

        test keyword {
            const parseHello = keyword(.HELLO, "Hello");

            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.HELLO, "Hello"), ", World"),
                try parseHello(ctx, "Hello, World"),
            );

            try checkAndConsume(
                ctx,
                .initFailHere("H"),
                try parseHello(ctx, "H"),
            );

            try checkAndConsume(
                ctx,
                .initFailHere("Hell or bust"),
                try parseHello(ctx, "Hell or bust"),
            );
        }

        pub fn always(tag: Tag, frag: []const u8) Parser {
            const shim = struct {
                fn alwaysParser(_: Context, input: []const u8) ZpcError!Result {
                    return .initOk(.initSlice(tag, frag), input);
                }
            };
            return shim.alwaysParser;
        }

        test always {
            const parseAlways = always(.FOO, "foo");
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.FOO, "foo"), "Hello, World"),
                try parseAlways(ctx, "Hello, World"),
            );
        }

        pub fn eof() Parser {
            const shim = struct {
                fn eofParser(_: Context, input: []const u8) ZpcError!Result {
                    if (input.len == 0)
                        return .initOk(.nothing, input);
                    return .initFailHere(input);
                }
            };
            return shim.eofParser;
        }

        test eof {
            const parseEof = eof();
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.nothing, ""),
                try parseEof(ctx, ""),
            );

            try checkAndConsume(
                ctx,
                .initFailHere("X"),
                try parseEof(ctx, "X"),
            );
        }

        pub fn rest() Parser {
            const shim = struct {
                fn restParser(_: Context, input: []const u8) ZpcError!Result {
                    return .initOk(.initSlice(Token.NOP, input), "");
                }
            };
            return shim.restParser;
        }

        test rest {
            const parseAllDigits = seq(.MULTI, &.{
                takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
                rest(),
            });
            const ctx: TestContext = .{ .allocator = std.testing.allocator };
            try checkAndConsume(
                ctx,
                .initOk(.initList(.MULTI, &.{
                    .initSlice(.DIGIT, "123"),
                    .initSlice(Token.NOP, "ABC."),
                }), ""),

                try parseAllDigits(ctx, "123ABC."),
            );
        }

        pub fn takeWhile(tag: Tag, bounds: Quantifier, pred: Predicate) Parser {
            assert(bounds.min <= bounds.max);
            const shim = struct {
                fn takeWhileParser(_: Context, input: []const u8) ZpcError!Result {
                    const len = @min(input.len, bounds.max);
                    var pos: usize = 0;
                    while (pos < len and pred(input[pos]))
                        pos += 1;
                    if (pos < bounds.min)
                        return .initFail(input[pos..], input);
                    return .initOk(.initSlice(tag, input[0..pos]), input[pos..]);
                }
            };
            return shim.takeWhileParser;
        }

        test takeWhile {
            const parseDigits = takeWhile(
                .DIGIT,
                .range(1, 2),
                std.ascii.isDigit,
            );
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.DIGIT, "67"), "b"),
                try parseDigits(ctx, "67b"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.DIGIT, "67"), ""),
                try parseDigits(ctx, "67"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.DIGIT, "67"), "8"),
                try parseDigits(ctx, "678"),
            );

            try checkAndConsume(
                ctx,
                .initFailHere("X"),
                try parseDigits(ctx, "X"),
            );
        }

        pub fn alt(parsers: []const *const Parser) Parser {
            const shim = struct {
                fn furthest(a: []const u8, b: []const u8) []const u8 {
                    return if (a.len < b.len) a else b;
                }

                fn altParser(ctx: Context, input: []const u8) ZpcError!Result {
                    var hwm = input;
                    inline for (parsers) |parser| {
                        const res = try parser(ctx, input);
                        if (res.matched())
                            return res;
                        hwm = furthest(hwm, res.tok.fail);
                    }

                    return .initFail(hwm, input);
                }
            };
            return shim.altParser;
        }

        test alt {
            const parseAlt = alt(&.{
                keyword(.HELLO, "Hello"),
                keyword(.FOO, "Foo"),
            });

            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.HELLO, "Hello"), ", World"),
                try parseAlt(ctx, "Hello, World"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.FOO, "Foo"), "Bar"),
                try parseAlt(ctx, "FooBar"),
            );

            try checkAndConsume(
                ctx,
                .initFailHere("Hell or bust"),
                try parseAlt(ctx, "Hell or bust"),
            );

            // TODO check hwm
        }

        pub fn seq(tag: Tag, parsers: []const *const Parser) Parser {
            const shim = struct {
                fn seqParser(ctx: Context, input: []const u8) ZpcError!Result {
                    var list: Token.ArrayList = .empty;
                    errdefer Token.deinitArrayList(&list, ctx.allocator);
                    var tail = input;
                    inline for (parsers) |parser| {
                        const res = try parser(ctx, tail);
                        if (!res.matched()) {
                            Token.deinitArrayList(&list, ctx.allocator);
                            return .initFail(res.tok.fail, input);
                        }
                        tail = res.rest;
                        try res.tok.ok.appendArrayList(ctx.allocator, &list);
                    }

                    return .initOk(try .initArrayList(ctx.allocator, tag, &list), tail);
                }
            };
            return shim.seqParser;
        }

        test seq {
            const parseAlphaNum = seq(.MULTI, &.{
                takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
                takeWhile(.ALPHA, .oneOrMore, std.ascii.isAlphabetic),
            });
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initList(.MULTI, &.{
                    .initSlice(.DIGIT, "123"),
                    .initSlice(.ALPHA, "ABC"),
                }), "."),

                try parseAlphaNum(ctx, "123ABC."),
            );

            // TODO fail
        }

        pub fn left(lp: Parser, rp: Parser) Parser {
            const shim = struct {
                fn leftParser(ctx: Context, input: []const u8) ZpcError!Result {
                    const lres = try lp(ctx, input);
                    errdefer lres.deinit(ctx.allocator);
                    if (!lres.matched()) return .initFail(lres.tok.fail, input);
                    const rres = try rp(ctx, lres.rest);
                    defer rres.deinit(ctx.allocator);
                    if (!rres.matched()) {
                        lres.deinit(ctx.allocator);
                        return .initFail(rres.tok.fail, input);
                    }
                    return .initOk(lres.tok.ok, rres.rest);
                }
            };
            return shim.leftParser;
        }

        test left {
            const parseLeft = left(
                keyword(.FOO, "Foo"),
                keyword(.BAR, "Bar"),
            );

            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.FOO, "Foo"), "Baz"),
                try parseLeft(ctx, "FooBarBaz"),
            );

            try checkAndConsume(
                ctx,
                .initFail("Baz", "FooBaz"),
                try parseLeft(ctx, "FooBaz"),
            );

            try checkAndConsume(
                ctx,
                .initFailHere("BarFoo"),
                try parseLeft(ctx, "BarFoo"),
            );
        }

        pub fn right(lp: Parser, rp: Parser) Parser {
            const shim = struct {
                fn rightParser(ctx: Context, input: []const u8) ZpcError!Result {
                    const lres = try lp(ctx, input);
                    defer lres.deinit(ctx.allocator);
                    if (!lres.matched()) return .initFail(lres.tok.fail, input);
                    const rres = try rp(ctx, lres.rest);
                    if (!rres.matched()) return .initFail(rres.tok.fail, input);
                    return rres;
                }
            };
            return shim.rightParser;
        }

        test right {
            const parseRight = right(
                keyword(.FOO, "Foo"),
                keyword(.BAR, "Bar"),
            );

            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.BAR, "Bar"), "Baz"),
                try parseRight(ctx, "FooBarBaz"),
            );

            try checkAndConsume(
                ctx,
                .initFail("Baz", "FooBaz"),
                try parseRight(ctx, "FooBaz"),
            );

            try checkAndConsume(
                ctx,
                .initFailHere("BarFoo"),
                try parseRight(ctx, "BarFoo"),
            );
        }

        pub fn between(lp: Parser, parser: Parser, rp: Parser) Parser {
            return left(right(lp, parser), rp);
        }

        test between {
            const parseBetween = between(
                literal("("),
                takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
                literal(")"),
            );
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.DIGIT, "123"), "."),
                try parseBetween(ctx, "(123)."),
            );

            try checkAndConsume(
                ctx,
                .initFail("", "(123"),
                try parseBetween(ctx, "(123"),
            );

            try checkAndConsume(
                ctx,
                .initFail("", "("),
                try parseBetween(ctx, "("),
            );
        }

        pub fn many(tag: Tag, bounds: Quantifier, parser: Parser) Parser {
            assert(bounds.min <= bounds.max);
            const shim = struct {
                fn manyParser(ctx: Context, input: []const u8) ZpcError!Result {
                    var list: Token.ArrayList = .empty;
                    errdefer Token.deinitArrayList(&list, ctx.allocator);
                    var tail = input;
                    while (list.items.len < bounds.max) {
                        const res = try parser(ctx, tail);
                        if (!res.matched()) {
                            if (list.items.len >= bounds.min)
                                break;
                            Token.deinitArrayList(&list, ctx.allocator);
                            return .initFail(res.tok.fail, input);
                        }
                        tail = res.rest;
                        try res.tok.ok.appendArrayList(ctx.allocator, &list);
                    }
                    return .initOk(try .initArrayList(ctx.allocator, tag, &list), tail);
                }
            };
            return shim.manyParser;
        }

        test many {
            const parseFooBar = many(
                .MULTI,
                .range(2, 3),
                alt(&.{ keyword(.FOO, "Foo"), keyword(.BAR, "Bar") }),
            );
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initList(.MULTI, &.{
                    .initSlice(.FOO, "Foo"),
                    .initSlice(.FOO, "Foo"),
                    .initSlice(.BAR, "Bar"),
                }), "Baz"),
                try parseFooBar(ctx, "FooFooBarBaz"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initList(.MULTI, &.{
                    .initSlice(.FOO, "Foo"),
                    .initSlice(.FOO, "Foo"),
                    .initSlice(.BAR, "Bar"),
                }), "BarBaz"),
                try parseFooBar(ctx, "FooFooBarBarBaz"),
            );

            // We need two or more so a single Foo shouldn't be consumed.
            try checkAndConsume(
                ctx,
                .initFail(".", "Foo."),
                try parseFooBar(ctx, "Foo."),
            );
        }

        pub fn optional(parser: Parser) Parser {
            const shim = struct {
                fn optionalParser(ctx: Context, input: []const u8) ZpcError!Result {
                    const res = try parser(ctx, input);
                    if (res.matched()) return res;
                    return .initOk(.nothing, input);
                }
            };
            return shim.optionalParser;
        }

        test optional {
            const parseMaybeNumber = optional(takeWhile(
                .DIGIT,
                .oneOrMore,
                std.ascii.isDigit,
            ));
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.DIGIT, "123"), "Foo"),
                try parseMaybeNumber(ctx, "123Foo"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.nothing, "Foo"),
                try parseMaybeNumber(ctx, "Foo"),
            );
        }

        pub fn discard(parser: Parser) Parser {
            const shim = struct {
                fn discardParser(ctx: Context, input: []const u8) ZpcError!Result {
                    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
                    defer arena.deinit();
                    var tmp_ctx: Context = ctx;
                    tmp_ctx.allocator = arena.allocator();
                    const res = try parser(tmp_ctx, input);
                    if (!res.matched()) return .initFail(res.tok.fail, input);
                    return .initOk(.nothing, res.rest);
                }
            };
            return shim.discardParser;
        }

        test discard {
            const parseHello = discard(keyword(.HELLO, "Hello"));

            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.nothing, ", World"),
                try parseHello(ctx, "Hello, World"),
            );

            try checkAndConsume(
                ctx,
                .initFailHere("H"),
                try parseHello(ctx, "H"),
            );
        }

        pub fn span(tag: Tag, parser: Parser) Parser {
            const shim = struct {
                fn matchParser(ctx: Context, input: []const u8) ZpcError!Result {
                    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
                    defer arena.deinit();
                    var tmp_ctx: Context = ctx;
                    tmp_ctx.allocator = arena.allocator();
                    const res = try parser(tmp_ctx, input);
                    if (!res.matched()) return .initFail(res.tok.fail, input);
                    const consumed: usize = input.len - res.rest.len;
                    return .initOk(.initSlice(tag, input[0..consumed]), res.rest);
                }
            };
            return shim.matchParser;
        }

        test span {
            const parseAlphaNum = span(.ALNUM, seq(.MULTI, &.{
                takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
                takeWhile(.ALPHA, .oneOrMore, std.ascii.isAlphabetic),
            }));
            const ctx: TestContext = .{ .allocator = std.testing.allocator };
            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.ALNUM, "100abc"), "."),
                try parseAlphaNum(ctx, "100abc."),
            );
        }

        pub fn flat(parser: Parser) Parser {
            const shim = struct {
                fn flatParser(ctx: Context, input: []const u8) ZpcError!Result {
                    const res = try parser(ctx, input);
                    if (res.matched()) {
                        return switch (res.tok.ok.value) {
                            .list => |list| .initOk(.{
                                .tag = res.tok.ok.tag,
                                .value = .{ .flat = list },
                            }, res.rest),
                            else => res,
                        };
                    }
                    return res;
                }
            };
            return shim.flatParser;
        }

        test flat {
            const parseDigits = takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit);
            const parseFlat = seq(.ARRAY, &.{
                parseDigits,
                flat(many(
                    Token.NOP,
                    .zeroOrMore,
                    right(literal(","), parseDigits),
                )),
            });

            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            const expr = "1,2,3;";
            const want: Result = .initOk(.initList(.ARRAY, &.{
                .initSlice(.DIGIT, "1"),
                .initSlice(.DIGIT, "2"),
                .initSlice(.DIGIT, "3"),
            }), ";");

            if (false) {
                const res = try parseFlat(ctx, expr);
                defer res.deinit(std.testing.allocator);
                print("want: {f}\n", .{want});
                print("res:  {f}\n", .{res});
            }

            try checkAndConsume(
                ctx,
                want,
                try parseFlat(ctx, expr),
            );
        }

        pub fn advances(parser: Parser) Parser {
            const shim = struct {
                fn advancesParser(ctx: Context, input: []const u8) ZpcError!Result {
                    const res = try parser(ctx, input);
                    if (res.matched() and input.len == res.rest.len) {
                        res.deinit(ctx.allocator);
                        return .initFailHere(input);
                    }
                    return res;
                }
            };
            return shim.advancesParser;
        }

        test advances {
            const parseDigits = takeWhile(.DIGIT, .zeroOrMore, std.ascii.isDigit);
            const parseAdvances = advances(parseDigits);
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.DIGIT, ""), "."),
                try parseDigits(ctx, "."),
            );

            try checkAndConsume(
                ctx,
                .initFailHere("."),
                try parseAdvances(ctx, "."),
            );
        }

        // If we receive a single element list lower it to the first item
        pub fn lower(parser: Parser) Parser {
            const shim = struct {
                fn lowerParser(ctx: Context, input: []const u8) ZpcError!Result {
                    const res = try parser(ctx, input);
                    if (res.matched()) {
                        switch (res.tok.ok.value) {
                            .nothing, .slice => {},
                            .flat, .list => |list| {
                                if (list.len == 1) {
                                    defer res.deinitShallow(ctx.allocator);
                                    return .initOk(list[0], res.rest);
                                }
                            },
                        }
                    }
                    return res;
                }
            };
            return shim.lowerParser;
        }

        test lower {
            const parseLower = lower(many(.MULTI, .oneOrMore, keyword(.FOO, "Foo")));
            const parseFlatLower = flat(parseLower);
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initList(.MULTI, &.{
                    .initSlice(.FOO, "Foo"),
                    .initSlice(.FOO, "Foo"),
                    .initSlice(.FOO, "Foo"),
                }), "."),
                try parseLower(ctx, "FooFooFoo."),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.FOO, "Foo"), "."),
                try parseLower(ctx, "Foo."),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.FOO, "Foo"), "."),
                try parseFlatLower(ctx, "Foo."),
            );
        }

        pub fn refine(lower_parser: Parser, upper_parser: Parser) Parser {
            const upper_complete_parser = left(upper_parser, eof());
            const shim = struct {
                fn refineParser(ctx: Context, input: []const u8) ZpcError!Result {
                    const lres = try lower_parser(ctx, input);
                    errdefer lres.deinit(ctx.allocator);

                    if (!lres.matched())
                        return lres;

                    const consumed: usize = input.len - lres.rest.len;
                    var ures = try upper_complete_parser(ctx, input[0..consumed]);

                    if (!ures.matched())
                        return lres;

                    defer lres.deinit(ctx.allocator);
                    ures.rest = lres.rest;
                    return ures;
                }
            };
            return shim.refineParser;
        }

        test refine {
            const parseKeyword = refine(
                takeWhile(.IDENT, .oneOrMore, std.ascii.isAlphabetic),
                alt(&.{
                    keyword(.FOO, "Foo"),
                    keyword(.BAR, "Bar"),
                }),
            );
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.FOO, "Foo"), " Hello"),
                try parseKeyword(ctx, "Foo Hello"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.BAR, "Bar"), " Hello"),
                try parseKeyword(ctx, "Bar Hello"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(.IDENT, "FooBar"), " Hello"),
                try parseKeyword(ctx, "FooBar Hello"),
            );
        }

        // Call a parser that is pointed to by a field on the context.
        pub fn recurse(field_name: []const u8) Parser {
            const shim = struct {
                fn recurseParser(ctx: Context, input: []const u8) ZpcError!Result {
                    const parser = @field(ctx, field_name);
                    return parser(ctx, input);
                }
            };
            return shim.recurseParser;
        }

        test recurse {
            const parseDigits = takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit);
            const skipSpace = takeWhile(Token.NOP, .zeroOrMore, std.ascii.isWhitespace);

            const parseAtom = right(skipSpace, alt(&.{
                between(literal("("), recurse("expr"), literal(")")),
                parseDigits,
            }));

            const parseTerm =
                seq(.TERM, &.{
                    parseAtom,
                    many(.MANY, .zeroOrMore, seq(.SEQ, &.{
                        right(skipSpace, alt(&.{ keyword(.PLUS, "+"), keyword(.MINUS, "-") })),
                        parseAtom,
                    })),
                });

            const parseExpr = parseTerm;

            const ctx: TestContext = .{
                .allocator = std.testing.allocator,
                .expr = parseExpr,
            };

            try checkAndConsume(
                ctx,
                .initOk(.initList(.TERM, &.{
                    .initSlice(.DIGIT, "123"),
                    .initList(.MANY, &.{}),
                }), ";"),
                try parseExpr(ctx, "123;"),
            );

            const expr = "(123 + 7) - 2 + 700;";
            const want: Result = .initOk(.initList(.TERM, &.{
                .initList(.TERM, &.{
                    .initSlice(.DIGIT, "123"),
                    .initList(.MANY, &.{
                        .initList(.SEQ, &.{
                            .initSlice(.PLUS, "+"),
                            .initSlice(.DIGIT, "7"),
                        }),
                    }),
                }),
                .initList(.MANY, &.{
                    .initList(.SEQ, &.{
                        .initSlice(.MINUS, "-"),
                        .initSlice(.DIGIT, "2"),
                    }),
                    .initList(.SEQ, &.{
                        .initSlice(.PLUS, "+"),
                        .initSlice(.DIGIT, "700"),
                    }),
                }),
            }), ";");

            if (false) {
                const res = try parseExpr(ctx, expr);
                defer res.deinit(std.testing.allocator);
                print("want: {f}\n", .{want});
                print("res:  {f}\n", .{res});
            }

            try checkAndConsume(ctx, want, try parseExpr(ctx, expr));
        }
    };
}

test Zpc {
    _ = Zpc(TestContext, TestTag);
}

// test ZpcComptime {
//     const Context = struct {
//         allocator: Allocator,
//     };

//     const Tag = enum { NONE };

//     const zpc = Zpc(Context, Tag);
//     _ = zpc;
// }
