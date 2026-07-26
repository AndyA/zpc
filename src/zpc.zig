const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const ct = @import("comptime.zig");

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

pub fn Space(Item: type) type {
    return struct {
        pub const Predicate = fn (item: Item) bool;

        pub fn predAny() Predicate {
            const shim = struct {
                fn pred(_: Item) bool {
                    return true;
                }
            };
            return shim.pred;
        }

        pub fn predAnd(a: Predicate, b: Predicate) Predicate {
            const shim = struct {
                fn pred(item: Item) bool {
                    return a(item) and b(item);
                }
            };
            return shim.pred;
        }

        pub fn predOr(a: Predicate, b: Predicate) Predicate {
            const shim = struct {
                fn pred(item: Item) bool {
                    return a(item) or b(item);
                }
            };
            return shim.pred;
        }

        pub fn predNot(p: Predicate) Predicate {
            const shim = struct {
                fn pred(item: Item) bool {
                    return !p(item);
                }
            };
            return shim.pred;
        }

        pub fn predEqual(want: Item) Predicate {
            const shim = struct {
                fn pred(item: Item) bool {
                    return item == want;
                }
            };
            return shim.pred;
        }

        pub fn predSet(charset: []const Item) Predicate {
            const shim = struct {
                fn pred(item: Item) bool {
                    return std.mem.containsAtLeastScalar(Item, charset, item, 1);
                }
            };
            return shim.pred;
        }

        pub const Error = error{OutOfMemory};

        pub const Phase = enum { comp, run };

        pub fn TokenType(Tag: type, phase: Phase) type {
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
                    slice: []const Item,
                    list: []const Self,
                    flat: []const Self, // Like a list but flattens into its parent
                },

                pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
                    try (Formatter{ .token = &self }).format(writer);
                }

                fn getAlloc(ctx: anytype) Allocator {
                    return switch (phase) {
                        .comp => ct.non_allocator,
                        .run => ctx.allocator,
                    };
                }

                fn freeList(ctx: anytype, list: []const Self) void {
                    switch (phase) {
                        .comp => {},
                        .run => ctx.allocator.free(list),
                    }
                }

                pub fn initSlice(tag: Tag, slice: []const Item) Self {
                    return .{ .tag = tag, .value = .{ .slice = slice } };
                }

                pub fn initList(tag: Tag, list: []const Self) Self {
                    return .{ .tag = tag, .value = .{ .list = list } };
                }

                pub fn initArrayList(ctx: anytype, tag: Tag, array: *ArrayList) Error!Self {
                    const list = try array.toOwnedSlice(getAlloc(ctx));
                    return initList(tag, list);
                }

                pub fn isNothing(self: Self) bool {
                    return self.value == .nothing;
                }

                pub fn appendToArrayList(self: Self, ctx: anytype, array: *ArrayList) Error!void {
                    switch (self.value) {
                        .nothing => {},
                        .slice, .list => try array.append(getAlloc(ctx), self),
                        .flat => |flat| {
                            defer self.deinitShallow(ctx);
                            try array.appendSlice(getAlloc(ctx), flat);
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
                        .list, .flat => |list| freeList(ctx, list),
                        .nothing, .slice => {},
                    }
                }

                pub fn deinitList(list: []const Self, ctx: anytype) void {
                    for (list) |item| item.deinit(ctx);
                    freeList(ctx, list);
                }

                pub fn deinitArrayList(list: *ArrayList, ctx: anytype) void {
                    for (list.items) |item| item.deinit(ctx);
                    list.deinit(getAlloc(ctx));
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

        pub fn ResultType(Token: type) type {
            return struct {
                const Self = @This();

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
                    /// The point at which parsing failed
                    fail: []const Item,
                },
                /// The rest of the input
                rest: []const Item,

                pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
                    try (Formatter{ .token = &self, .pretty = true }).format(writer);
                }

                pub fn initFail(at: []const Item, rest: []const Item) Self {
                    return .{ .tok = .{ .fail = at }, .rest = rest };
                }

                pub fn initFailHere(rest: []const Item) Self {
                    return initFail(rest, rest);
                }

                pub fn initOk(value: Token, rest: []const Item) Self {
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

        pub fn ParserTypeForResult(Context: type, Result: type) type {
            return fn (ctx: Context, input: []const Item) Error!Result;
        }

        pub fn ParserType(Context: type, Tag: type) type {
            return ParserTypeForResult(Context, ResultType(TokenType(Tag, .run)));
        }

        pub fn ComptimeParserType(Context: type, Tag: type) type {
            return ParserTypeForResult(Context, ResultType(TokenType(Tag, .comp)));
        }

        pub fn MapperType(Context: type, Result: type) type {
            return fn (ctx: Context, input: []const Item, result: Result) Error!Result;
        }

        pub fn Parsers(Context: type, Tag: type) type {
            if (!@hasField(Context, "allocator"))
                @compileError("Context must have an allocator field");
            return makeParsers(Context, Tag, .run);
        }

        pub fn ComptimeParsers(Context: type, Tag: type) type {
            return makeParsers(Context, Tag, .comp);
        }

        fn makeParsers(Context: type, Tag: type, phase: Phase) type {
            return struct {
                pub const Token = TokenType(Tag, phase);
                pub const Result = ResultType(Token);
                pub const Parser = ParserTypeForResult(Context, Result);
                pub const Mapper = MapperType(Context, Result);

                pub fn keyword(tag: Tag, str: []const Item) Parser {
                    assert(str.len != 0);
                    const shim = struct {
                        fn keywordParser(_: Context, input: []const Item) Error!Result {
                            if (input.len >= str.len and
                                std.mem.eql(Item, input[0..str.len], str))
                                return .initOk(.initSlice(tag, str), input[str.len..]);
                            return .initFailHere(input);
                        }
                    };
                    return shim.keywordParser;
                }

                pub fn literal(str: []const Item) Parser {
                    return keyword(Token.NOP, str);
                }

                pub fn always(tag: Tag, frag: []const Item) Parser {
                    const shim = struct {
                        fn alwaysParser(_: Context, input: []const Item) Error!Result {
                            return .initOk(.initSlice(tag, frag), input);
                        }
                    };
                    return shim.alwaysParser;
                }

                pub fn eof() Parser {
                    const shim = struct {
                        fn eofParser(_: Context, input: []const Item) Error!Result {
                            if (input.len == 0)
                                return .initOk(.nothing, input);
                            return .initFailHere(input);
                        }
                    };
                    return shim.eofParser;
                }

                pub fn rest(tag: Tag) Parser {
                    const shim = struct {
                        fn restParser(_: Context, input: []const Item) Error!Result {
                            return .initOk(.initSlice(tag, input), "");
                        }
                    };
                    return shim.restParser;
                }

                pub fn takeWhile(tag: Tag, bounds: Quantifier, pred: Predicate) Parser {
                    assert(bounds.min <= bounds.max);
                    const shim = struct {
                        fn takeWhileParser(_: Context, input: []const Item) Error!Result {
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
                        fn furthest(a: []const Item, b: []const Item) []const Item {
                            return if (a.len < b.len) a else b;
                        }

                        fn altParser(ctx: Context, input: []const Item) Error!Result {
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
                        fn seqParser(ctx: Context, input: []const Item) Error!Result {
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
                                try res.tok.ok.appendToArrayList(ctx, &list);
                            }

                            return .initOk(try .initArrayList(ctx, tag, &list), tail);
                        }
                    };
                    return shim.seqParser;
                }

                pub fn left(lp: Parser, rp: Parser) Parser {
                    const shim = struct {
                        fn leftParser(ctx: Context, input: []const Item) Error!Result {
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
                        fn rightParser(ctx: Context, input: []const Item) Error!Result {
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
                        fn manyParser(ctx: Context, input: []const Item) Error!Result {
                            var list: Token.ArrayList = .empty;
                            errdefer Token.deinitArrayList(&list, ctx);
                            var tail = input;
                            while (list.items.len < bounds.max) {
                                const res = try parser(ctx, tail);
                                if (!res.matched()) {
                                    if (list.items.len >= bounds.min)
                                        break;
                                    Token.deinitArrayList(&list, ctx);
                                    return .initFail(res.tok.fail, input);
                                }
                                tail = res.rest;
                                try res.tok.ok.appendToArrayList(ctx, &list);
                            }
                            return .initOk(try .initArrayList(ctx, tag, &list), tail);
                        }
                    };
                    return shim.manyParser;
                }

                pub fn optional(parser: Parser) Parser {
                    const shim = struct {
                        fn optionalParser(ctx: Context, input: []const Item) Error!Result {
                            const res = try parser(ctx, input);
                            if (res.matched()) return res;
                            return .initOk(.nothing, input);
                        }
                    };
                    return shim.optionalParser;
                }

                pub fn mapTemp(parser: Parser, mapper: Mapper) Parser {
                    const shim = switch (phase) {
                        .comp => struct {
                            fn mapParser(ctx: Context, input: []const Item) Error!Result {
                                return try mapper(ctx, input, try parser(ctx, input));
                            }
                        },
                        .run => struct {
                            fn mapParser(ctx: Context, input: []const Item) Error!Result {
                                var arena = std.heap.ArenaAllocator.init(ctx.allocator);
                                defer arena.deinit();
                                var tmp_ctx: Context = ctx;
                                tmp_ctx.allocator = arena.allocator();
                                return try mapper(ctx, input, try parser(tmp_ctx, input));
                            }
                        },
                    };
                    return shim.mapParser;
                }

                pub fn discard(parser: Parser) Parser {
                    const shim = struct {
                        fn disardMapper(
                            _: Context,
                            input: []const Item,
                            res: Result,
                        ) Error!Result {
                            if (!res.matched()) return .initFail(res.tok.fail, input);
                            return .initOk(.nothing, res.rest);
                        }
                    };

                    return mapTemp(parser, shim.disardMapper);
                }

                pub fn span(tag: Tag, parser: Parser) Parser {
                    const shim = struct {
                        fn spanMapper(
                            _: Context,
                            input: []const Item,
                            res: Result,
                        ) Error!Result {
                            if (!res.matched()) return .initFail(res.tok.fail, input);
                            const consumed: usize = input.len - res.rest.len;
                            return .initOk(.initSlice(tag, input[0..consumed]), res.rest);
                        }
                    };

                    return mapTemp(parser, shim.spanMapper);
                }

                pub fn flat(parser: Parser) Parser {
                    const shim = struct {
                        fn flatParser(ctx: Context, input: []const Item) Error!Result {
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
                        fn advancesParser(ctx: Context, input: []const Item) Error!Result {
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
                        fn lowerParser(ctx: Context, input: []const Item) Error!Result {
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
                        fn refineParser(ctx: Context, input: []const Item) Error!Result {
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
                pub fn recurse(field_name: []const Item) Parser {
                    const shim = struct {
                        fn recurseParser(ctx: Context, input: []const Item) Error!Result {
                            const parser = @field(ctx, field_name);
                            return parser(ctx, input);
                        }
                    };
                    return shim.recurseParser;
                }
            };
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

const TestSpace = Space(u8);
const TestToken = TestSpace.TokenType(TestTag, .run);
const TestResult = TestSpace.ResultType(TestToken);

const TestContext = struct {
    allocator: Allocator,
    expr: *const TestSpace.ParserTypeForResult(@This(), TestResult) = undefined,
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
    const P = TestSpace.Parsers(TestContext, TestTag);
    const parseAlways = P.always(.FOO, "foo");
    const ctx: TestContext = .{ .allocator = std.testing.allocator };

    try checkAndConsume(
        ctx,
        .initOk(.initSlice(.FOO, "foo"), "Hello, World"),
        try parseAlways(ctx, "Hello, World"),
    );
}

test "eof" {
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
    const parseAllDigits = P.seq(.MULTI, &.{
        P.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
        P.rest(.REST),
    });
    const ctx: TestContext = .{ .allocator = std.testing.allocator };
    try checkAndConsume(
        ctx,
        .initOk(.initList(.MULTI, &.{
            .initSlice(.DIGIT, "123"),
            .initSlice(.REST, "ABC."),
        }), ""),

        try parseAllDigits(ctx, "123ABC."),
    );
}

test "keyword" {
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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
    const P = TestSpace.Parsers(TestContext, TestTag);
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

test "ComptimeParsers" {
    const Context = struct {};

    const Tag = enum { NONE, DIGIT, ALPHA, MULTI };

    const P = TestSpace.ComptimeParsers(Context, Tag);
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
