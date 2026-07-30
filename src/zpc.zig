//! A construction kit for parsers that are constructed at comptime and may be
//! called at runtime or comptime.
//!
//! [More](#zpc.Space.makeParsers)

const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const ct = @import("comptime.zig");

/// Quantify the number of times a match may repeat. Useful constants:
///
/// * .zeroOrMore
/// * .zeroOrOne
/// * .oneOrMore
/// * .one
///
pub const Quantifier = struct {
    const Self = @This();
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

    /// The minimum number of times to match
    min: usize = 0,
    /// The maximum number of times to match
    max: usize = std.math.maxInt(usize),
};

/// Although it's common to parse slices of `u8`, parsers can be constructed for any
/// suitable scalar type. Common examples include `u21` for Unicode code points, `u16`
/// for utc-2 / utf-16. Any type for which `==` equality works should be fine.
///
/// You can choose the character type at import:
///
/// ```zig
/// const zpc = @import("zpc").Space(u8);
/// ```
/// or
/// ```zig
/// const zpc = @import("zpc").Space(u21);
/// ```
///
pub fn Space(Item: type) type {
    return struct {
        pub const Predicate = fn (item: Item) bool;

        /// A predicate that matches any item
        pub fn predAny() Predicate {
            const shim = struct {
                fn pred(_: Item) bool {
                    return true;
                }
            };
            return shim.pred;
        }

        /// A predicate that is the (short circuited) AND of two other
        /// predicates
        pub fn predAnd(a: Predicate, b: Predicate) Predicate {
            const shim = struct {
                fn pred(item: Item) bool {
                    return a(item) and b(item);
                }
            };
            return shim.pred;
        }

        /// A predicate that is the (short circuited) OR of two other
        /// predicates
        pub fn predOr(a: Predicate, b: Predicate) Predicate {
            const shim = struct {
                fn pred(item: Item) bool {
                    return a(item) or b(item);
                }
            };
            return shim.pred;
        }

        /// A predicate that negates the supplied predicate
        pub fn predNot(p: Predicate) Predicate {
            const shim = struct {
                fn pred(item: Item) bool {
                    return !p(item);
                }
            };
            return shim.pred;
        }

        /// A predicate that is true if the item equals the specified value
        pub fn predEqual(want: Item) Predicate {
            const shim = struct {
                fn pred(item: Item) bool {
                    return item == want;
                }
            };
            return shim.pred;
        }

        /// A predicate that tests whether the item is contained in the specified
        /// charset.
        pub fn predSet(charset: []const Item) Predicate {
            const shim = struct {
                fn pred(item: Item) bool {
                    return std.mem.containsAtLeastScalar(Item, charset, item, 1);
                }
            };
            return shim.pred;
        }

        const Error = error{OutOfMemory};

        const Phase = enum { comp, run };

        fn TokenType(Tag: type, phase: Phase) type {
            return struct {
                const Self = @This();
                pub const ArrayList = switch (phase) {
                    .comp => ct.ComptimeArrayList(Self),
                    .run => std.ArrayList(Self),
                };
                pub const NOP: Tag = @fromBackingInt(0);

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

                /// The tag of this token. Tags are from the enumeration passed
                /// when creating the Parsers
                tag: Tag = NOP,
                /// The token's value
                value: union(enum(u8)) {
                    /// An empty token. Unless it's the root token it will never appear
                    /// in the parsed AST because it's discarded from `.list` and `.flat`
                    /// tokens
                    nothing: void,
                    /// A literal slice of text, often but not always a slice into the
                    /// input text.
                    slice: []const Item,
                    /// A list of child tokens.
                    list: []const Self,
                    /// A list of child tokens that will be flattened into its parent
                    /// list to unnest it.
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

        fn ResultType(Token: type) type {
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

        fn ParserTypeForResult(Context: type, Result: type) type {
            return fn (ctx: Context, input: []const Item) Error!Result;
        }

        pub fn ParserType(Context: type, Tag: type) type {
            return ParserTypeForResult(Context, ResultType(TokenType(Tag, .run)));
        }

        pub fn ComptimeParserType(Context: type, Tag: type) type {
            return ParserTypeForResult(Context, ResultType(TokenType(Tag, .comp)));
        }

        fn MapperTypeForResult(Context: type, Result: type) type {
            return fn (ctx: Context, input: []const Item, result: Result) Error!Result;
        }

        pub fn MapperType(Context: type, Tag: type) type {
            return MapperTypeForResult(Context, ResultType(TokenType(Tag, .run)));
        }

        pub fn ComptimeMapperType(Context: type, Tag: type) type {
            return MapperTypeForResult(Context, ResultType(TokenType(Tag, .comp)));
        }

        /// [Here](#zpc.Space.makeParsers)
        pub fn Parsers(Context: type, Tag: type) type {
            if (!@hasField(Context, "allocator"))
                @compileError("Context must have an allocator field");
            return makeParsers(Context, Tag, .run);
        }

        /// [Here](#zpc.Space.makeParsers)
        pub fn ComptimeParsers(Context: type, Tag: type) type {
            return makeParsers(Context, Tag, .comp);
        }

        /// This is the common destination of [Parsers](#zpc.Space.Parsers) and
        /// [ComptimeParsers](#zpc.Space.ComptimeParsers). It returns a struct
        /// that provides parser constructors bound to the supplied `Context` and
        /// `Tag`.
        fn makeParsers(Context: type, Tag: type, phase: Phase) type {
            return struct {
                pub const Token = TokenType(Tag, phase);
                pub const Result = ResultType(Token);
                pub const Parser = ParserTypeForResult(Context, Result);
                pub const Mapper = MapperTypeForResult(Context, Result);

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

                pub fn tagName(tag: Tag) Parser {
                    // Only works with []u8
                    assert(Item == u8);
                    return keyword(tag, @tagName(tag));
                }

                pub fn literal(str: []const Item) Parser {
                    return keyword(Token.NOP, str);
                }

                /// Always match without consuming any input.
                pub fn always(tag: Tag, frag: []const Item) Parser {
                    const shim = struct {
                        fn alwaysParser(_: Context, input: []const Item) Error!Result {
                            return .initOk(.initSlice(tag, frag), input);
                        }
                    };
                    return shim.alwaysParser;
                }

                /// Match only at the end of input. Matches with a `.nothing` (which
                /// disappears if not at the root of the AST).
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

                /// Consume the remainder of the input and return it in a `.slice`.
                pub fn rest(tag: Tag) Parser {
                    const shim = struct {
                        fn restParser(_: Context, input: []const Item) Error!Result {
                            return .initOk(.initSlice(tag, input), "");
                        }
                    };
                    return shim.restParser;
                }

                /// Consume from input while `pred` returns true. Fails if the number
                /// of matched chars falls outside the bounds of `quantifier`.
                pub fn takeWhile(tag: Tag, quantifier: Quantifier, pred: Predicate) Parser {
                    assert(quantifier.min <= quantifier.max);
                    const shim = struct {
                        fn takeWhileParser(_: Context, input: []const Item) Error!Result {
                            const len = @min(input.len, quantifier.max);
                            if (len < quantifier.min)
                                return .initFail("", input);
                            var pos: usize = 0;
                            while (pos < len and pred(input[pos]))
                                pos += 1;
                            if (pos < quantifier.min)
                                return .initFail(input[pos..], input);
                            return .initOk(.initSlice(tag, input[0..pos]), input[pos..]);
                        }
                    };
                    return shim.takeWhileParser;
                }

                /// Try each of `parsers` in turn returning the result of the first
                /// that succeeds. Fail if none succeeds.
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

                /// Try `parsers` in sequence returning a `.list` of their results if they
                /// all succeed otherwise fail.
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

                /// If `left_parser` and `right_parser` succeed in sequence return the left
                /// result and discard the right.
                pub fn left(left_parser: Parser, right_parser: Parser) Parser {
                    const shim = struct {
                        fn leftParser(ctx: Context, input: []const Item) Error!Result {
                            const lres = try left_parser(ctx, input);
                            errdefer lres.deinit(ctx);
                            if (!lres.matched()) return lres;
                            const rres = try discard(right_parser)(ctx, lres.rest);
                            if (!rres.matched()) {
                                lres.deinit(ctx);
                                return .initFail(rres.tok.fail, input);
                            }
                            return .initOk(lres.tok.ok, rres.rest);
                        }
                    };
                    return shim.leftParser;
                }

                /// If `left_parser` and `right_parser` succeed in sequence return the right
                /// result and discard the left.
                pub fn right(left_parser: Parser, right_parser: Parser) Parser {
                    const shim = struct {
                        fn rightParser(ctx: Context, input: []const Item) Error!Result {
                            const lres = try discard(left_parser)(ctx, input);
                            if (!lres.matched()) return lres;
                            const rres = try right_parser(ctx, lres.rest);
                            if (!rres.matched()) return .initFail(rres.tok.fail, input);
                            return rres;
                        }
                    };
                    return shim.rightParser;
                }

                /// If `left_parser`, `parser` and `right_parser` succeed in sequence return
                /// the result of `parser` and discard the left and right results.
                pub fn between(
                    left_parser: Parser,
                    parser: Parser,
                    right_parser: Parser,
                ) Parser {
                    return left(right(left_parser, parser), right_parser);
                }

                pub fn many(tag: Tag, quantifier: Quantifier, parser: Parser) Parser {
                    assert(quantifier.min <= quantifier.max);
                    const shim = struct {
                        fn manyParser(ctx: Context, input: []const Item) Error!Result {
                            var list: Token.ArrayList = .empty;
                            errdefer Token.deinitArrayList(&list, ctx);
                            var tail = input;
                            while (list.items.len < quantifier.max) {
                                const res = try advances(parser)(ctx, tail);
                                if (!res.matched()) {
                                    if (list.items.len >= quantifier.min)
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

                pub fn map(parser: Parser, mapper: Mapper) Parser {
                    const shim = struct {
                        fn mapParser(ctx: Context, input: []const Item) Error!Result {
                            return try mapper(ctx, input, try parser(ctx, input));
                        }
                    };
                    return shim.mapParser;
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

                /// If `parser` succeeds, discard its result and return a `.nothing` token
                /// in its place. At any level of nesting other than the root of the AST
                /// `.nothing` tokens are discarded and won't appear in the result.
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

                /// If `parser` succeeds return a `.slice` token containing the whole of the
                /// matched text, tagged with `tag`.
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

                /// If `parser` returns a `.list` modify it so that it will flatten into the
                /// parent token.
                pub fn flat(parser: Parser) Parser {
                    const shim = struct {
                        fn flatParser(ctx: Context, input: []const Item) Error!Result {
                            const res = try parser(ctx, input);
                            if (!res.matched()) return res;
                            return switch (res.tok.ok.value) {
                                .list => |list| .initOk(.{
                                    .tag = res.tok.ok.tag,
                                    .value = .{ .flat = list },
                                }, res.rest),
                                else => res,
                            };
                        }
                    };
                    return shim.flatParser;
                }

                /// Fail unless `parser` succeeds _and_ moves forwards in the text.
                /// This is useful to wrap any composition of `zeroOrMore` parsers
                /// to ensure that at least one of them made progress.
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

                /// If the result is a single element `.list` lower the result to its first
                /// element.
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

                /// If `lower_parser` succeeds call `upper_parser` on the matched text.
                /// If `upper_parser` succeeds and consumes all of the text matched by
                /// `lower_parser` return its result otherwise return the result from
                /// `lower_parser`.
                pub fn refine(lower_parser: Parser, upper_parser: Parser) Parser {
                    const shim = struct {
                        fn refineParser(ctx: Context, input: []const Item) Error!Result {
                            const lres = try lower_parser(ctx, input);
                            errdefer lres.deinit(ctx);

                            if (!lres.matched())
                                return lres;

                            const consumed: usize = input.len - lres.rest.len;
                            var ures = try left(upper_parser, eof())(ctx, input[0..consumed]);

                            if (!ures.matched())
                                return lres;

                            defer lres.deinit(ctx);
                            ures.rest = lres.rest; // TODO surely redundant?
                            return ures;
                        }
                    };
                    return shim.refineParser;
                }

                /// Call a parser from `field_name` in the context. This makes it possible
                /// to create recursive parsers.
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

test "tagName" {
    const P = TestSpace.Parsers(TestContext, TestTag);
    const parseHello = P.tagName(.HELLO);

    const ctx: TestContext = .{ .allocator = std.testing.allocator };

    try checkAndConsume(
        ctx,
        .initOk(.initSlice(.HELLO, "HELLO"), ", WORLD"),
        try parseHello(ctx, "HELLO, WORLD"),
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
