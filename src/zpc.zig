const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const ct = @import("comptime.zig");

pub const ZpcError = error{OutOfMemory};

pub const ZpcPhase = enum { comp, run };

fn ZpcArrayList(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const empty: Self = .{};

        list: std.ArrayList(T) = .empty,

        pub fn deinit(self: *Self, ctx: anytype) void {
            self.list.deinit(ctx.allocator);
        }

        pub fn append(self: *Self, ctx: anytype, item: T) ZpcError!void {
            try self.list.append(ctx.allocator, item);
        }

        pub fn appendSlice(self: *Self, ctx: anytype, slice: []const T) ZpcError!void {
            try self.list.appendSlice(ctx.allocator, slice);
        }

        pub fn toOwnedSlice(self: *Self, ctx: anytype) ZpcError![]const T {
            return try self.list.toOwnedSlice(ctx.allocator);
        }

        pub fn freeList(ctx: anytype, list: []const T) void {
            ctx.allocator.free(list);
        }

        pub fn items(self: Self) []const T {
            return self.list.items;
        }
    };
}

fn ZpcComptimeArrayList(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const empty: Self = .{};

        list: ct.ComptimeArrayList(T) = .empty,

        pub fn deinit(self: *Self, _: anytype) void {
            self.list.deinit(ct.non_allocator);
        }

        pub fn append(self: *Self, _: anytype, item: T) ZpcError!void {
            try self.list.append(ct.non_allocator, item);
        }

        pub fn appendSlice(self: *Self, _: anytype, slice: []const T) ZpcError!void {
            try self.list.appendSlice(ct.non_allocator, slice);
        }

        pub fn toOwnedSlice(self: *Self, _: anytype) ZpcError![]const T {
            return try self.list.toOwnedSlice(ct.non_allocator);
        }

        pub fn freeList(_: anytype, _: []const T) void {}

        pub fn items(self: Self) []const T {
            return self.list.items;
        }
    };
}

pub fn ZpcToken(comptime Tag: type, comptime phase: ZpcPhase) type {
    return struct {
        const Self = @This();
        pub const ArrayList = switch (phase) {
            .comp => ZpcComptimeArrayList(Self),
            .run => ZpcArrayList(Self),
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

        pub fn initArrayList(ctx: anytype, tag: Tag, array: *ArrayList) ZpcError!Self {
            const list = try array.toOwnedSlice(ctx);
            return initList(tag, list);
        }

        pub fn isNothing(self: Self) bool {
            return self.value == .nothing;
        }

        pub fn appendArrayList(self: Self, ctx: anytype, array: *ArrayList) ZpcError!void {
            switch (self.value) {
                .nothing => {},
                .slice, .list => try array.append(ctx, self),
                .flat => |flat| {
                    defer self.deinitShallow(ctx);
                    try array.appendSlice(ctx, flat);
                },
            }
        }

        pub fn deinit(self: Self, ctx: anytype) void {
            switch (self.value) {
                .list, .flat => |list| deinitList(list, ctx),
                .nothing, .slice => {},
            }
        }

        pub fn deinitShallow(self: Self, ctx: anytype) void {
            switch (self.value) {
                .list, .flat => |list| ArrayList.freeList(ctx, list),
                .nothing, .slice => {},
            }
        }

        pub fn deinitList(list: []const Self, ctx: anytype) void {
            for (list) |item| item.deinit(ctx);
            ArrayList.freeList(ctx, list);
        }

        pub fn deinitArrayList(list: *ArrayList, ctx: anytype) void {
            for (list.items()) |item| item.deinit(ctx);
            list.deinit(ctx);
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

        pub fn deinit(self: Self, ctx: anytype) void {
            switch (self.tok) {
                .ok => |ok| ok.deinit(ctx),
                .fail => {},
            }
        }

        pub fn deinitShallow(self: Self, ctx: anytype) void {
            switch (self.tok) {
                .ok => |ok| ok.deinitShallow(ctx),
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
    if (!@hasField(Context, "allocator"))
        @compileError("Context must have an allocator field");
    return make_zpc(Context, Tag, .run);
}

pub fn ZpcComptime(comptime Context: type, comptime Tag: type) type {
    return make_zpc(Context, Tag, .comp);
}

fn make_zpc(comptime Context: type, comptime Tag: type, phase: ZpcPhase) type {
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

        pub fn always(tag: Tag, frag: []const u8) Parser {
            const shim = struct {
                fn alwaysParser(_: Context, input: []const u8) ZpcError!Result {
                    return .initOk(.initSlice(tag, frag), input);
                }
            };
            return shim.alwaysParser;
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

        pub fn rest() Parser {
            const shim = struct {
                fn restParser(_: Context, input: []const u8) ZpcError!Result {
                    return .initOk(.initSlice(Token.NOP, input), "");
                }
            };
            return shim.restParser;
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

        pub fn seq(tag: Tag, parsers: []const *const Parser) Parser {
            const shim = struct {
                fn seqParser(ctx: Context, input: []const u8) ZpcError!Result {
                    var list: Token.ArrayList = .empty;
                    errdefer Token.deinitArrayList(&list, ctx);
                    var tail = input;
                    inline for (parsers) |parser| {
                        const res = try parser(ctx, tail);
                        if (!res.matched()) {
                            Token.deinitArrayList(&list, ctx);
                            return .initFail(res.tok.fail, input);
                        }
                        tail = res.rest;
                        try res.tok.ok.appendArrayList(ctx, &list);
                    }

                    return .initOk(try .initArrayList(ctx, tag, &list), tail);
                }
            };
            return shim.seqParser;
        }

        pub fn left(lp: Parser, rp: Parser) Parser {
            const shim = struct {
                fn leftParser(ctx: Context, input: []const u8) ZpcError!Result {
                    const lres = try lp(ctx, input);
                    errdefer lres.deinit(ctx);
                    if (!lres.matched()) return .initFail(lres.tok.fail, input);
                    const rres = try rp(ctx, lres.rest);
                    defer rres.deinit(ctx);
                    if (!rres.matched()) {
                        lres.deinit(ctx);
                        return .initFail(rres.tok.fail, input);
                    }
                    return .initOk(lres.tok.ok, rres.rest);
                }
            };
            return shim.leftParser;
        }

        pub fn right(lp: Parser, rp: Parser) Parser {
            const shim = struct {
                fn rightParser(ctx: Context, input: []const u8) ZpcError!Result {
                    const lres = try lp(ctx, input);
                    defer lres.deinit(ctx);
                    if (!lres.matched()) return .initFail(lres.tok.fail, input);
                    const rres = try rp(ctx, lres.rest);
                    if (!rres.matched()) return .initFail(rres.tok.fail, input);
                    return rres;
                }
            };
            return shim.rightParser;
        }

        pub fn between(lp: Parser, parser: Parser, rp: Parser) Parser {
            return left(right(lp, parser), rp);
        }

        pub fn many(tag: Tag, bounds: Quantifier, parser: Parser) Parser {
            assert(bounds.min <= bounds.max);
            const shim = struct {
                fn manyParser(ctx: Context, input: []const u8) ZpcError!Result {
                    var list: Token.ArrayList = .empty;
                    errdefer Token.deinitArrayList(&list, ctx);
                    var tail = input;
                    while (list.items().len < bounds.max) {
                        const res = try parser(ctx, tail);
                        if (!res.matched()) {
                            if (list.items().len >= bounds.min)
                                break;
                            Token.deinitArrayList(&list, ctx);
                            return .initFail(res.tok.fail, input);
                        }
                        tail = res.rest;
                        try res.tok.ok.appendArrayList(ctx, &list);
                    }
                    return .initOk(try .initArrayList(ctx, tag, &list), tail);
                }
            };
            return shim.manyParser;
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

        pub fn discard(parser: Parser) Parser {
            const shim = struct {
                fn discardParser(ctx: Context, input: []const u8) ZpcError!Result {
                    var arena = std.heap.ArenaAllocator.init(ctx.allocator); // TODO
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

        pub fn advances(parser: Parser) Parser {
            const shim = struct {
                fn advancesParser(ctx: Context, input: []const u8) ZpcError!Result {
                    const res = try parser(ctx, input);
                    if (res.matched() and input.len == res.rest.len) {
                        res.deinit(ctx);
                        return .initFailHere(input);
                    }
                    return res;
                }
            };
            return shim.advancesParser;
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
                                    defer res.deinitShallow(ctx);
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

        pub fn refine(lower_parser: Parser, upper_parser: Parser) Parser {
            const upper_complete_parser = left(upper_parser, eof());
            const shim = struct {
                fn refineParser(ctx: Context, input: []const u8) ZpcError!Result {
                    const lres = try lower_parser(ctx, input);
                    errdefer lres.deinit(ctx);

                    if (!lres.matched())
                        return lres;

                    const consumed: usize = input.len - lres.rest.len;
                    var ures = try upper_complete_parser(ctx, input[0..consumed]);

                    if (!ures.matched())
                        return lres;

                    defer lres.deinit(ctx);
                    ures.rest = lres.rest;
                    return ures;
                }
            };
            return shim.refineParser;
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
    };
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
    defer actual.deinit(ctx);
    try expectEqualDeep(expected, actual);
}

test "always" {
    const P = Zpc(TestContext, TestTag);
    const parseAlways = P.always(.FOO, "foo");
    const ctx: TestContext = .{ .allocator = std.testing.allocator };

    try checkAndConsume(
        ctx,
        .initOk(.initSlice(.FOO, "foo"), "Hello, World"),
        try parseAlways(ctx, "Hello, World"),
    );
}

test "eof" {
    const P = Zpc(TestContext, TestTag);
    const parseEof = P.eof();
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

test "rest" {
    const P = Zpc(TestContext, TestTag);
    const parseAllDigits = P.seq(.MULTI, &.{
        P.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
        P.rest(),
    });
    const ctx: TestContext = .{ .allocator = std.testing.allocator };
    try checkAndConsume(
        ctx,
        .initOk(.initList(.MULTI, &.{
            .initSlice(.DIGIT, "123"),
            .initSlice(P.Token.NOP, "ABC."),
        }), ""),

        try parseAllDigits(ctx, "123ABC."),
    );
}

test "keyword" {
    const P = Zpc(TestContext, TestTag);
    const parseHello = P.keyword(.HELLO, "Hello");

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

test "takeWhile" {
    const P = Zpc(TestContext, TestTag);
    const parseDigits = P.takeWhile(
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

test "alt" {
    const P = Zpc(TestContext, TestTag);
    const parseAlt = P.alt(&.{
        P.keyword(.HELLO, "Hello"),
        P.keyword(.FOO, "Foo"),
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

test "seq" {
    const P = Zpc(TestContext, TestTag);
    const parseAlphaNum = P.seq(.MULTI, &.{
        P.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
        P.takeWhile(.ALPHA, .oneOrMore, std.ascii.isAlphabetic),
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

test "left" {
    const P = Zpc(TestContext, TestTag);
    const parseLeft = P.left(
        P.keyword(.FOO, "Foo"),
        P.keyword(.BAR, "Bar"),
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

test "right" {
    const P = Zpc(TestContext, TestTag);
    const parseRight = P.right(
        P.keyword(.FOO, "Foo"),
        P.keyword(.BAR, "Bar"),
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

test "between" {
    const P = Zpc(TestContext, TestTag);
    const parseBetween = P.between(
        P.literal("("),
        P.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
        P.literal(")"),
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

test "many" {
    const P = Zpc(TestContext, TestTag);
    const parseFooBar = P.many(
        .MULTI,
        .range(2, 3),
        P.alt(&.{ P.keyword(.FOO, "Foo"), P.keyword(.BAR, "Bar") }),
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

test "optional" {
    const P = Zpc(TestContext, TestTag);
    const parseMaybeNumber = P.optional(P.takeWhile(
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

test "discard" {
    const P = Zpc(TestContext, TestTag);
    const parseHello = P.discard(P.keyword(.HELLO, "Hello"));

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

test "span" {
    const P = Zpc(TestContext, TestTag);
    const parseAlphaNum = P.span(.ALNUM, P.seq(.MULTI, &.{
        P.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
        P.takeWhile(.ALPHA, .oneOrMore, std.ascii.isAlphabetic),
    }));
    const ctx: TestContext = .{ .allocator = std.testing.allocator };
    try checkAndConsume(
        ctx,
        .initOk(.initSlice(.ALNUM, "100abc"), "."),
        try parseAlphaNum(ctx, "100abc."),
    );
}

test "flat" {
    const P = Zpc(TestContext, TestTag);
    const parseDigits = P.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit);
    const parseFlat = P.seq(.ARRAY, &.{
        parseDigits,
        P.flat(P.many(
            P.Token.NOP,
            .zeroOrMore,
            P.right(P.literal(","), parseDigits),
        )),
    });

    const ctx: TestContext = .{ .allocator = std.testing.allocator };

    const expr = "1,2,3;";
    const want: P.Result = .initOk(.initList(.ARRAY, &.{
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

test "advances" {
    const P = Zpc(TestContext, TestTag);
    const parseDigits = P.takeWhile(.DIGIT, .zeroOrMore, std.ascii.isDigit);
    const parseAdvances = P.advances(parseDigits);
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

test "lower" {
    const P = Zpc(TestContext, TestTag);
    const parseLower = P.lower(P.many(.MULTI, .oneOrMore, P.keyword(.FOO, "Foo")));
    const parseFlatLower = P.flat(parseLower);
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

test "refine" {
    const P = Zpc(TestContext, TestTag);
    const parseKeyword = P.refine(
        P.takeWhile(.IDENT, .oneOrMore, std.ascii.isAlphabetic),
        P.alt(&.{
            P.keyword(.FOO, "Foo"),
            P.keyword(.BAR, "Bar"),
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

test "recurse" {
    const P = Zpc(TestContext, TestTag);
    const parseDigits = P.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit);
    const skipSpace = P.takeWhile(P.Token.NOP, .zeroOrMore, std.ascii.isWhitespace);

    const parseAtom = P.right(skipSpace, P.alt(&.{
        P.between(P.literal("("), P.recurse("expr"), P.literal(")")),
        parseDigits,
    }));

    const parseTerm =
        P.seq(.TERM, &.{
            parseAtom,
            P.many(.MANY, .zeroOrMore, P.seq(.SEQ, &.{
                P.right(skipSpace, P.alt(&.{ P.keyword(.PLUS, "+"), P.keyword(.MINUS, "-") })),
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
    const want: P.Result = .initOk(.initList(.TERM, &.{
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

test ZpcComptime {
    const Context = struct {};

    const Tag = enum { NONE, DIGIT, ALPHA, MULTI };

    const P = ZpcComptime(Context, Tag);
    const parseAlphaNum = P.seq(.MULTI, &.{
        P.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
        P.takeWhile(.ALPHA, .oneOrMore, std.ascii.isAlphabetic),
    });

    const res = comptime blk: {
        const ctx: Context = .{};
        break :blk try parseAlphaNum(ctx, "123ABC.");
    };

    try expectEqualDeep(P.Result.initOk(.initList(.MULTI, &.{
        .initSlice(.DIGIT, "123"),
        .initSlice(.ALPHA, "ABC"),
    }), "."), res);
}
