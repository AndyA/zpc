//! A construction kit for parsers that are constructed at comptime and may be
//! called at runtime or comptime.

const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const ct = @import("zpc/comptime.zig");

pub const Quantifier = @import("zpc/Quantifier.zig");
pub const Phase = enum { comp, run };
pub const Error = error{OutOfMemory};

pub const Config = struct {
    /// An enum that will be used to tag parsed tokens
    Tag: type,
    /// The context that is passed to parsers
    Context: type,
    /// Whether generated parsers will be called at runtime (`.run`) or comptime (`.comp`)
    phase: Phase = .run,
    /// The type of a character; may be any type that is supported by `std.mem.eql`
    Char: type = u8,
};

pub fn TokenType(config: Config) type {
    const Char = config.Char;
    const Context = config.Context;
    const Tag = config.Tag;
    return struct {
        const Self = @This();
        pub const ArrayList = switch (config.phase) {
            .comp => ct.ComptimeArrayList(Self),
            .run => std.ArrayList(Self),
        };
        pub const NOP: config.Tag = @fromBackingInt(0);

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
        input: []const Char,
        value: union(enum) {
            nothing: void,
            slice: []const Char,
            list: []const Self,
            flat: []const Self, // Like a list but flattens into its parent
        },

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            try (Formatter{ .token = &self }).format(writer);
        }

        fn getAlloc(ctx: Context) Allocator {
            return switch (config.phase) {
                .comp => ct.non_allocator,
                .run => ctx.allocator,
            };
        }

        fn freeList(ctx: Context, list: []const Self) void {
            switch (config.phase) {
                .comp => {},
                .run => ctx.allocator.free(list),
            }
        }

        pub fn initNothing(input: []const Char) Self {
            return .{
                .tag = NOP,
                .input = input,
                .value = .nothing,
            };
        }

        pub fn initSlice(input: []const Char, tag: Tag, slice: []const Char) Self {
            return .{
                .tag = tag,
                .input = input,
                .value = .{ .slice = slice },
            };
        }

        pub fn initList(input: []const Char, tag: Tag, list: []const Self) Self {
            return .{
                .tag = tag,
                .input = input,
                .value = .{ .list = list },
            };
        }

        pub fn initArrayList(
            ctx: Context,
            input: []const Char,
            tag: Tag,
            array: *ArrayList,
        ) Error!Self {
            const list = try array.toOwnedSlice(getAlloc(ctx));
            return initList(input, tag, list);
        }

        pub fn appendToArrayList(self: Self, ctx: Context, array: *ArrayList) Error!void {
            switch (self.value) {
                .nothing => {},
                .slice, .list => try array.append(getAlloc(ctx), self),
                .flat => |flat| {
                    defer self.deinitShallow(ctx);
                    try array.appendSlice(getAlloc(ctx), flat);
                },
            }
        }

        pub fn deinit(self: Self, ctx: Context) void {
            switch (self.value) {
                .list, .flat => |list| deinitList(list, ctx),
                .nothing, .slice => {},
            }
        }

        pub fn deinitShallow(self: Self, ctx: Context) void {
            switch (self.value) {
                .list, .flat => |list| freeList(ctx, list),
                .nothing, .slice => {},
            }
        }

        pub fn deinitList(list: []const Self, ctx: Context) void {
            for (list) |item| item.deinit(ctx);
            freeList(ctx, list);
        }

        pub fn deinitArrayList(list: *ArrayList, ctx: Context) void {
            for (list.items) |item| item.deinit(ctx);
            list.deinit(getAlloc(ctx));
        }

        /// For a `.list` or `.flat` return the slice of children. Panics if
        /// called on a non-list.
        pub fn children(self: Self) []const Self {
            return switch (self.value) {
                .flat, .list => |l| l,
                else => unreachable,
            };
        }

        /// For a `.list` or `.flat` return the first child. Panics if
        /// called on a non-list or an empty list
        pub fn head(self: Self) Self {
            return self.children()[0];
        }

        /// For a `.list` or `.flat` return the child items after the first.
        /// Panics if called on a non-list or an empty list
        pub fn tail(self: Self) []const Self {
            return self.children()[1..];
        }

        /// For a `.list` or `.flat` with precisely 2 elements return the
        /// second element. Panics if called on a non-list or a list with
        /// more or fewer than two elements.
        pub fn other(self: Self) Self {
            const l = self.children();
            assert(l.len == 2);
            return l[1];
        }
    };
}

pub fn ResultType(config: Config) type {
    const Token = TokenType(config);
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
            /// Success: the token that was parsed
            ok: Token,
            /// Failure: the point at which parsing failed
            fail: []const config.Char,
        },
        /// The rest of the input
        rest: []const config.Char,

        pub fn format(self: Self, writer: *Io.Writer) Io.Writer.Error!void {
            try (Formatter{ .token = &self, .pretty = true }).format(writer);
        }

        pub fn initFail(at: []const config.Char, rest: []const config.Char) Self {
            return .{ .tok = .{ .fail = at }, .rest = rest };
        }

        pub fn initFailHere(rest: []const config.Char) Self {
            return initFail(rest, rest);
        }

        pub fn initOk(value: Token, rest: []const config.Char) Self {
            return .{ .tok = .{ .ok = value }, .rest = rest };
        }

        pub fn deinit(self: Self, ctx: config.Context) void {
            switch (self.tok) {
                .ok => |ok| ok.deinit(ctx),
                .fail => {},
            }
        }

        pub fn deinitShallow(self: Self, ctx: config.Context) void {
            switch (self.tok) {
                .ok => |ok| ok.deinitShallow(ctx),
                .fail => {},
            }
        }

        pub fn succeeded(self: Self) bool {
            return self.tok == .ok;
        }
    };
}

pub fn ParserType(config: Config) type {
    const Result = ResultType(config);
    return fn (ctx: config.Context, input: []const config.Char) Error!Result;
}

pub fn MapperType(config: Config) type {
    const Result = ResultType(config);
    return fn (ctx: config.Context, input: []const config.Char, result: Result) Error!Result;
}

pub fn PredicateType(config: Config) type {
    return fn (char: config.Char) bool;
}

pub fn Compiler(config: Config) type {
    const Char = config.Char;
    const Tag = config.Tag;
    const Context = config.Context;

    return struct {
        pub const Token = TokenType(config);
        pub const Result = ResultType(config);
        pub const Parser = ParserType(config);
        pub const Mapper = MapperType(config);
        pub const Predicate = PredicateType(config);

        /// Predicate composers.
        pub const P = struct {
            /// A predicate that matches any char
            pub fn any_() Predicate {
                const shim = struct {
                    fn pred(_: Char) bool {
                        return true;
                    }
                };
                return shim.pred;
            }

            /// A predicate that is the (short circuited) `and` of two other
            /// predicates
            pub fn and_(a: Predicate, b: Predicate) Predicate {
                const shim = struct {
                    fn pred(char: Char) bool {
                        return a(char) and b(char);
                    }
                };
                return shim.pred;
            }

            /// A predicate that is the (short circuited) `or` of two other
            /// predicates
            pub fn or_(a: Predicate, b: Predicate) Predicate {
                const shim = struct {
                    fn pred(char: Char) bool {
                        return a(char) or b(char);
                    }
                };
                return shim.pred;
            }

            /// A predicate that negates the supplied predicate
            pub fn not_(p: Predicate) Predicate {
                const shim = struct {
                    fn pred(char: Char) bool {
                        return !p(char);
                    }
                };
                return shim.pred;
            }

            /// A predicate that is true if the item equals `want`
            pub fn equal_(want: Char) Predicate {
                const shim = struct {
                    fn pred(char: Char) bool {
                        return char == want;
                    }
                };
                return shim.pred;
            }

            /// A predicate that tests whether the item is in `charset`
            pub fn set_(charset: []const Char) Predicate {
                const shim = struct {
                    fn pred(char: Char) bool {
                        return std.mem.containsAtLeastScalar(config.Char, charset, char, 1);
                    }
                };
                return shim.pred;
            }
        };

        /// Succeed with a token tagged with `tag` if `str` is the next input.
        pub fn keyword(tag: Tag, str: []const Char) Parser {
            assert(str.len != 0);
            const shim = struct {
                fn keywordParser(_: Context, input: []const Char) Error!Result {
                    if (input.len >= str.len and
                        std.mem.eql(Char, input[0..str.len], str))
                        return .initOk(.initSlice(input, tag, str), input[str.len..]);
                    return .initFailHere(input);
                }
            };
            return shim.keywordParser;
        }

        test keyword {
            const parseHello = C.keyword(.HELLO, "Hello");

            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("Hello, World", .HELLO, "Hello"), ", World"),
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

        /// Succeed with a token tagged with `tag` if the next input is the
        /// tag name of the tag. Useful with tags like e.g. `@"<="`.
        pub fn tagName(tag: Tag) Parser {
            // Only works with []u8
            assert(Char == u8);
            return keyword(tag, @tagName(tag));
        }

        test tagName {
            const parseHello = C.tagName(.HELLO);

            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("HELLO, WORLD", .HELLO, "HELLO"), ", WORLD"),
                try parseHello(ctx, "HELLO, WORLD"),
            );
        }

        /// Succeed with a token tagged with `NOP` (the zeroeth `Tag`) if `str` is
        /// the next input.
        pub fn literal(str: []const Char) Parser {
            return keyword(Token.NOP, str);
        }

        /// Always succeed without consuming any input.
        pub fn always(tag: Tag, frag: []const Char) Parser {
            const shim = struct {
                fn alwaysParser(_: Context, input: []const Char) Error!Result {
                    return .initOk(.initSlice(input, tag, frag), input);
                }
            };
            return shim.alwaysParser;
        }

        test always {
            const parseAlways = C.always(.FOO, "foo");
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("Hello, World", .FOO, "foo"), "Hello, World"),
                try parseAlways(ctx, "Hello, World"),
            );
        }

        /// Match only at the end of input. Matches with a `.nothing` (which
        /// disappears if not at the root of the AST).
        pub fn eof() Parser {
            const shim = struct {
                fn eofParser(_: Context, input: []const Char) Error!Result {
                    if (input.len == 0)
                        return .initOk(.initNothing(input), input);
                    return .initFailHere(input);
                }
            };
            return shim.eofParser;
        }

        test eof {
            const parseEof = C.eof();
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initNothing(""), ""),
                try parseEof(ctx, ""),
            );

            try checkAndConsume(
                ctx,
                .initFailHere("X"),
                try parseEof(ctx, "X"),
            );
        }

        /// Consume the remainder of the input and return it in a `.slice`.
        pub fn rest(tag: Tag) Parser {
            const shim = struct {
                fn restParser(_: Context, input: []const Char) Error!Result {
                    return .initOk(.initSlice(input, tag, input), "");
                }
            };
            return shim.restParser;
        }

        test rest {
            const parseAllDigits = C.seq(.MULTI, &.{
                C.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
                C.rest(.REST),
            });
            const ctx: TestContext = .{ .allocator = std.testing.allocator };
            try checkAndConsume(
                ctx,
                .initOk(.initList("123ABC.", .MULTI, &.{
                    .initSlice("123ABC.", .DIGIT, "123"),
                    .initSlice("ABC.", .REST, "ABC."),
                }), ""),

                try parseAllDigits(ctx, "123ABC."),
            );
        }

        /// Consume chars from input while `pred` returns true. Fails if the number
        /// of matched chars falls outside the bounds of `quantifier`. The matched
        /// chars are returned as a `.slice` token.
        pub fn takeWhile(tag: Tag, quantifier: Quantifier, pred: Predicate) Parser {
            assert(quantifier.min <= quantifier.max);
            const shim = struct {
                fn takeWhileParser(_: Context, input: []const Char) Error!Result {
                    const len = @min(input.len, quantifier.max);
                    if (len < quantifier.min)
                        return .initFail("", input);
                    var pos: usize = 0;
                    while (pos < len and pred(input[pos]))
                        pos += 1;
                    if (pos < quantifier.min)
                        return .initFail(input[pos..], input);
                    return .initOk(.initSlice(input, tag, input[0..pos]), input[pos..]);
                }
            };
            return shim.takeWhileParser;
        }

        test takeWhile {
            const parseDigits = C.takeWhile(
                .DIGIT,
                .range(1, 2),
                std.ascii.isDigit,
            );
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("67b", .DIGIT, "67"), "b"),
                try parseDigits(ctx, "67b"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("67", .DIGIT, "67"), ""),
                try parseDigits(ctx, "67"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("678", .DIGIT, "67"), "8"),
                try parseDigits(ctx, "678"),
            );

            try checkAndConsume(
                ctx,
                .initFailHere("X"),
                try parseDigits(ctx, "X"),
            );
        }

        /// Consume chars from input until `pred` returns true. Fails if the number
        /// of matched chars falls outside the bounds of `quantifier`. The matched
        /// chars are returned as a `.slice` token.
        pub fn takeUntil(tag: Tag, quantifier: Quantifier, pred: Predicate) Parser {
            return takeWhile(tag, quantifier, P.not_(pred));
        }

        /// Try each of `parsers` in turn returning the result of the first
        /// that succeeds. Fail if none succeeds.
        pub fn alt(parsers: []const *const Parser) Parser {
            const shim = struct {
                fn furthest(a: []const Char, b: []const Char) []const Char {
                    return if (a.len < b.len) a else b;
                }

                fn altParser(ctx: Context, input: []const Char) Error!Result {
                    var hwm = input;
                    inline for (parsers) |parser| {
                        const res = try parser(ctx, input);
                        if (res.succeeded())
                            return res;
                        hwm = furthest(hwm, res.tok.fail);
                    }

                    return .initFail(hwm, input);
                }
            };
            return shim.altParser;
        }

        test alt {
            const parseAlt = C.alt(&.{
                C.keyword(.HELLO, "Hello"),
                C.keyword(.FOO, "Foo"),
            });

            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("Hello, World", .HELLO, "Hello"), ", World"),
                try parseAlt(ctx, "Hello, World"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("FooBar", .FOO, "Foo"), "Bar"),
                try parseAlt(ctx, "FooBar"),
            );

            try checkAndConsume(
                ctx,
                .initFailHere("Hell or bust"),
                try parseAlt(ctx, "Hell or bust"),
            );

            // TODO check hwm
        }

        /// Try `parsers` in sequence returning a `.list` of their results if they
        /// all succeed otherwise fail.
        pub fn seq(tag: Tag, parsers: []const *const Parser) Parser {
            const shim = struct {
                fn seqParser(ctx: Context, input: []const Char) Error!Result {
                    var list: Token.ArrayList = .empty;
                    errdefer Token.deinitArrayList(&list, ctx);
                    var tail = input;
                    inline for (parsers) |parser| {
                        const res = try parser(ctx, tail);
                        if (!res.succeeded()) {
                            Token.deinitArrayList(&list, ctx);
                            return .initFail(res.tok.fail, input);
                        }
                        tail = res.rest;
                        try res.tok.ok.appendToArrayList(ctx, &list);
                    }

                    return .initOk(try .initArrayList(ctx, input, tag, &list), tail);
                }
            };
            return shim.seqParser;
        }

        test seq {
            const parseAlphaNum = C.seq(.MULTI, &.{
                C.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
                C.takeWhile(.ALPHA, .oneOrMore, std.ascii.isAlphabetic),
            });
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initList("123ABC.", .MULTI, &.{
                    .initSlice("123ABC.", .DIGIT, "123"),
                    .initSlice("ABC.", .ALPHA, "ABC"),
                }), "."),

                try parseAlphaNum(ctx, "123ABC."),
            );

            // TODO fail
        }

        /// If `left_parser` and `right_parser` succeed in sequence return the left
        /// result and discard the right.
        pub fn left(left_parser: Parser, right_parser: Parser) Parser {
            const shim = struct {
                fn leftParser(ctx: Context, input: []const Char) Error!Result {
                    const lres = try left_parser(ctx, input);
                    errdefer lres.deinit(ctx);
                    if (!lres.succeeded()) return lres;
                    const rres = try discard(right_parser)(ctx, lres.rest);
                    if (!rres.succeeded()) {
                        lres.deinit(ctx);
                        return .initFail(rres.tok.fail, input);
                    }
                    return .initOk(lres.tok.ok, rres.rest);
                }
            };
            return shim.leftParser;
        }

        test left {
            const parseLeft = C.left(
                C.keyword(.FOO, "Foo"),
                C.keyword(.BAR, "Bar"),
            );

            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("FooBarBaz", .FOO, "Foo"), "Baz"),
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

        /// If `left_parser` and `right_parser` succeed in sequence return the right
        /// result and discard the left.
        pub fn right(left_parser: Parser, right_parser: Parser) Parser {
            const shim = struct {
                fn rightParser(ctx: Context, input: []const Char) Error!Result {
                    const lres = try discard(left_parser)(ctx, input);
                    if (!lres.succeeded()) return lres;
                    const rres = try right_parser(ctx, lres.rest);
                    if (!rres.succeeded()) return .initFail(rres.tok.fail, input);
                    return rres;
                }
            };
            return shim.rightParser;
        }

        test right {
            const parseRight = C.right(
                C.keyword(.FOO, "Foo"),
                C.keyword(.BAR, "Bar"),
            );

            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("BarBaz", .BAR, "Bar"), "Baz"),
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

        /// If `left_parser`, `parser` and `right_parser` succeed in sequence return
        /// the result of `parser` and discard the left and right results.
        pub fn between(left_parser: Parser, parser: Parser, right_parser: Parser) Parser {
            return left(right(left_parser, parser), right_parser);
        }

        test between {
            const parseBetween = C.between(
                C.literal("("),
                C.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
                C.literal(")"),
            );
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("123).", .DIGIT, "123"), "."),
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

        /// Apply a parser until it fails or reaches `quantifier.max` matches and return
        /// the result as a `.list` token.
        pub fn many(tag: Tag, quantifier: Quantifier, parser: Parser) Parser {
            assert(quantifier.min <= quantifier.max);
            const shim = struct {
                fn manyParser(ctx: Context, input: []const Char) Error!Result {
                    var list: Token.ArrayList = .empty;
                    errdefer Token.deinitArrayList(&list, ctx);
                    var tail = input;
                    while (list.items.len < quantifier.max) {
                        const res = try advances(parser)(ctx, tail);
                        if (!res.succeeded()) {
                            if (list.items.len >= quantifier.min)
                                break;
                            Token.deinitArrayList(&list, ctx);
                            return .initFail(res.tok.fail, input);
                        }
                        tail = res.rest;
                        try res.tok.ok.appendToArrayList(ctx, &list);
                    }
                    return .initOk(try .initArrayList(ctx, input, tag, &list), tail);
                }
            };
            return shim.manyParser;
        }

        test many {
            const parseFooBar = C.many(
                .MULTI,
                .range(2, 3),
                C.alt(&.{ C.keyword(.FOO, "Foo"), C.keyword(.BAR, "Bar") }),
            );
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initList("FooFooBarBaz", .MULTI, &.{
                    .initSlice("FooFooBarBaz", .FOO, "Foo"),
                    .initSlice("FooBarBaz", .FOO, "Foo"),
                    .initSlice("BarBaz", .BAR, "Bar"),
                }), "Baz"),
                try parseFooBar(ctx, "FooFooBarBaz"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initList("FooFooBarBarBaz", .MULTI, &.{
                    .initSlice("FooFooBarBarBaz", .FOO, "Foo"),
                    .initSlice("FooBarBarBaz", .FOO, "Foo"),
                    .initSlice("BarBarBaz", .BAR, "Bar"),
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
                fn optionalParser(ctx: Context, input: []const Char) Error!Result {
                    const res = try parser(ctx, input);
                    if (res.succeeded()) return res;
                    return .initOk(.initNothing(input), input);
                }
            };
            return shim.optionalParser;
        }

        test optional {
            const parseMaybeNumber = C.optional(C.takeWhile(
                .DIGIT,
                .oneOrMore,
                std.ascii.isDigit,
            ));
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("123Foo", .DIGIT, "123"), "Foo"),
                try parseMaybeNumber(ctx, "123Foo"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initNothing("Foo"), "Foo"),
                try parseMaybeNumber(ctx, "Foo"),
            );
        }

        pub fn map(parser: Parser, mapper: Mapper) Parser {
            const shim = struct {
                fn mapParser(ctx: Context, input: []const Char) Error!Result {
                    return try mapper(ctx, input, try parser(ctx, input));
                }
            };
            return shim.mapParser;
        }

        pub fn mapTemp(parser: Parser, mapper: Mapper) Parser {
            const shim = switch (config.phase) {
                .comp => struct {
                    fn mapParser(ctx: Context, input: []const Char) Error!Result {
                        return try mapper(ctx, input, try parser(ctx, input));
                    }
                },
                .run => struct {
                    fn mapParser(ctx: Context, input: []const Char) Error!Result {
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

        /// If `parser` succeeds, discard its result and return a `.nothing` token
        /// in its place. At any level of nesting other than the root of the AST
        /// `.nothing` tokens are discarded and won't appear in the result.
        pub fn discard(parser: Parser) Parser {
            const shim = struct {
                fn disardMapper(
                    _: Context,
                    input: []const Char,
                    res: Result,
                ) Error!Result {
                    if (!res.succeeded()) return .initFail(res.tok.fail, input);
                    return .initOk(.initNothing(res.tok.ok.input), res.rest);
                }
            };

            return mapTemp(parser, shim.disardMapper);
        }

        test discard {
            const parseHello = C.discard(C.keyword(.HELLO, "Hello"));

            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initNothing("Hello, World"), ", World"),
                try parseHello(ctx, "Hello, World"),
            );

            try checkAndConsume(
                ctx,
                .initFailHere("H"),
                try parseHello(ctx, "H"),
            );
        }

        /// If `parser` succeeds return a `.slice` token containing the whole of the
        /// matched text, tagged with `tag`.
        pub fn span(tag: Tag, parser: Parser) Parser {
            const shim = struct {
                fn spanMapper(
                    _: Context,
                    input: []const Char,
                    res: Result,
                ) Error!Result {
                    if (!res.succeeded()) return .initFail(res.tok.fail, input);
                    const consumed: usize = input.len - res.rest.len;
                    return .initOk(.initSlice(input, tag, input[0..consumed]), res.rest);
                }
            };

            return mapTemp(parser, shim.spanMapper);
        }

        test span {
            const parseAlphaNum = C.span(.ALNUM, C.seq(.MULTI, &.{
                C.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
                C.takeWhile(.ALPHA, .oneOrMore, std.ascii.isAlphabetic),
            }));
            const ctx: TestContext = .{ .allocator = std.testing.allocator };
            try checkAndConsume(
                ctx,
                .initOk(.initSlice("100abc.", .ALNUM, "100abc"), "."),
                try parseAlphaNum(ctx, "100abc."),
            );
        }

        /// If `parser` returns a `.list` modify it so that it will flatten into the
        /// parent token.
        pub fn flat(parser: Parser) Parser {
            const shim = struct {
                fn flatParser(ctx: Context, input: []const Char) Error!Result {
                    const res = try parser(ctx, input);
                    if (!res.succeeded()) return res;
                    return switch (res.tok.ok.value) {
                        .list => |list| .initOk(.{
                            .tag = res.tok.ok.tag,
                            .input = res.tok.ok.input,
                            .value = .{ .flat = list },
                        }, res.rest),
                        else => res,
                    };
                }
            };
            return shim.flatParser;
        }

        test flat {
            const parseDigits = C.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit);
            const parseFlat = C.seq(.ARRAY, &.{
                parseDigits,
                C.flat(C.many(
                    C.Token.NOP,
                    .zeroOrMore,
                    C.right(C.literal(","), parseDigits),
                )),
            });

            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            const expr = "1,2,3;";
            const want: C.Result = .initOk(.initList("1,2,3;", .ARRAY, &.{
                .initSlice("1,2,3;", .DIGIT, "1"),
                .initSlice("2,3;", .DIGIT, "2"),
                .initSlice("3;", .DIGIT, "3"),
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

        /// Fail unless `parser` succeeds _and_ moves forwards in the text.
        /// This is useful to wrap any composition of `zeroOrMore` parsers
        /// to ensure that at least one of them made progress.
        pub fn advances(parser: Parser) Parser {
            const shim = struct {
                fn advancesParser(ctx: Context, input: []const Char) Error!Result {
                    const res = try parser(ctx, input);
                    if (res.succeeded() and input.len == res.rest.len) {
                        res.deinit(ctx);
                        return .initFailHere(input);
                    }
                    return res;
                }
            };
            return shim.advancesParser;
        }

        test advances {
            const parseDigits = C.takeWhile(.DIGIT, .zeroOrMore, std.ascii.isDigit);
            const parseAdvances = C.advances(parseDigits);
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice(".", .DIGIT, ""), "."),
                try parseDigits(ctx, "."),
            );

            try checkAndConsume(
                ctx,
                .initFailHere("."),
                try parseAdvances(ctx, "."),
            );
        }

        /// If the result is a single element `.list` lower the result to its first
        /// element.
        pub fn lower(parser: Parser) Parser {
            const shim = struct {
                fn lowerParser(ctx: Context, input: []const Char) Error!Result {
                    const res = try parser(ctx, input);
                    if (res.succeeded()) {
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

        test lower {
            const parseLower = C.lower(C.many(.MULTI, .oneOrMore, C.keyword(.FOO, "Foo")));
            const parseFlatLower = C.flat(parseLower);
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initList("FooFooFoo.", .MULTI, &.{
                    .initSlice("FooFooFoo.", .FOO, "Foo"),
                    .initSlice("FooFoo.", .FOO, "Foo"),
                    .initSlice("Foo.", .FOO, "Foo"),
                }), "."),
                try parseLower(ctx, "FooFooFoo."),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("Foo.", .FOO, "Foo"), "."),
                try parseLower(ctx, "Foo."),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("Foo.", .FOO, "Foo"), "."),
                try parseFlatLower(ctx, "Foo."),
            );
        }

        /// If `lower_parser` succeeds call `upper_parser` on the matched text.
        /// If `upper_parser` succeeds and consumes all of the text matched by
        /// `lower_parser` return its result otherwise return the result from
        /// `lower_parser`.
        pub fn refine(lower_parser: Parser, upper_parser: Parser) Parser {
            const shim = struct {
                fn refineParser(ctx: Context, input: []const Char) Error!Result {
                    const lres = try lower_parser(ctx, input);
                    errdefer lres.deinit(ctx);

                    if (!lres.succeeded())
                        return lres;

                    const consumed: usize = input.len - lres.rest.len;
                    var ures = try left(upper_parser, eof())(ctx, input[0..consumed]);

                    if (!ures.succeeded())
                        return lres;

                    defer lres.deinit(ctx);
                    ures.rest = lres.rest;
                    ures.tok.ok.input = lres.tok.ok.input;
                    return ures;
                }
            };
            return shim.refineParser;
        }

        test refine {
            const parseKeyword = C.refine(
                C.takeWhile(.IDENT, .oneOrMore, std.ascii.isAlphabetic),
                C.alt(&.{
                    C.keyword(.FOO, "Foo"),
                    C.keyword(.BAR, "Bar"),
                }),
            );
            const ctx: TestContext = .{ .allocator = std.testing.allocator };

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("Foo Hello", .FOO, "Foo"), " Hello"),
                try parseKeyword(ctx, "Foo Hello"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("Bar Hello", .BAR, "Bar"), " Hello"),
                try parseKeyword(ctx, "Bar Hello"),
            );

            try checkAndConsume(
                ctx,
                .initOk(.initSlice("FooBar Hello", .IDENT, "FooBar"), " Hello"),
                try parseKeyword(ctx, "FooBar Hello"),
            );
        }

        /// Call a parser from `field_name` in the context. This makes it possible
        /// to create recursive parsers.
        pub fn recurse(field_name: []const Char) Parser {
            const shim = struct {
                fn recurseParser(ctx: Context, input: []const Char) Error!Result {
                    const parser = @field(ctx, field_name);
                    return parser(ctx, input);
                }
            };
            return shim.recurseParser;
        }

        test recurse {
            const parseDigits = C.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit);
            const skipSpace = C.takeWhile(C.Token.NOP, .zeroOrMore, std.ascii.isWhitespace);

            const parseAtom = C.right(skipSpace, C.alt(&.{
                C.between(C.literal("("), C.recurse("expr"), C.literal(")")),
                parseDigits,
            }));

            const parseTerm =
                C.seq(.TERM, &.{
                    parseAtom,
                    C.many(.MANY, .zeroOrMore, C.seq(.SEQ, &.{
                        C.right(skipSpace, C.alt(&.{ C.keyword(.PLUS, "+"), C.keyword(.MINUS, "-") })),
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
                .initOk(.initList("123;", .TERM, &.{
                    .initSlice("123;", .DIGIT, "123"),
                    .initList(";", .MANY, &.{}),
                }), ";"),
                try parseExpr(ctx, "123;"),
            );

            const expr = "(123 + 7) - 2 + 700;";
            const want: C.Result = .initOk(.initList("(123 + 7) - 2 + 700;", .TERM, &.{
                .initList("123 + 7) - 2 + 700;", .TERM, &.{
                    .initSlice("123 + 7) - 2 + 700;", .DIGIT, "123"),
                    .initList(" + 7) - 2 + 700;", .MANY, &.{
                        .initList(" + 7) - 2 + 700;", .SEQ, &.{
                            .initSlice("+ 7) - 2 + 700;", .PLUS, "+"),
                            .initSlice("7) - 2 + 700;", .DIGIT, "7"),
                        }),
                    }),
                }),
                .initList(" - 2 + 700;", .MANY, &.{
                    .initList(" - 2 + 700;", .SEQ, &.{
                        .initSlice("- 2 + 700;", .MINUS, "-"),
                        .initSlice("2 + 700;", .DIGIT, "2"),
                    }),
                    .initList(" + 700;", .SEQ, &.{
                        .initSlice("+ 700;", .PLUS, "+"),
                        .initSlice("700;", .DIGIT, "700"),
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
            const ComptimeTag = enum { NONE, DIGIT, ALPHA, MULTI };
            const ComptimeContext = struct {
                const cfg: Config = .{
                    .Tag = ComptimeTag,
                    .Context = @This(),
                    .phase = .comp,
                };
            };

            const CP = Compiler(ComptimeContext.cfg);
            const parseAlphaNum = CP.seq(.MULTI, &.{
                CP.takeWhile(.DIGIT, .oneOrMore, std.ascii.isDigit),
                CP.takeWhile(.ALPHA, .oneOrMore, std.ascii.isAlphabetic),
            });

            const ctx: ComptimeContext = .{};
            const res = comptime blk: {
                break :blk try parseAlphaNum(ctx, "123ABC.");
            };

            try expectEqualDeep(CP.Result.initOk(.initList("123ABC.", .MULTI, &.{
                .initSlice("123ABC.", .DIGIT, "123"),
                .initSlice("ABC.", .ALPHA, "ABC"),
            }), "."), res);
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

const TestContext = struct {
    pub const config: Config = .{
        .Tag = TestTag,
        .Context = @This(),
    };
    allocator: Allocator,
    expr: *const ParserType(config) = undefined,
};

const TestResult = ResultType(TestContext.config);
const C = Compiler(TestContext.config);

fn checkAndConsume(
    ctx: TestContext,
    expected: TestResult,
    actual: TestResult,
) !void {
    defer actual.deinit(ctx);
    try expectEqualDeep(expected, actual);
}

test {
    _ = Compiler(TestContext.config);
}
