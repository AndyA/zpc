const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc");

const JsonPathTag = enum(u8) {
    NONE,
    PATH,
    SEGMENT,
    SUBSCRIPT,
    SEARCH,
    IDENT,
    NUMBER,
    STRING,
    WILD,
};

const JsonPathContext = struct {
    pub const config: zpc.ZpcConfig = .{ .Tag = JsonPathTag, .Context = @This() };
    allocator: Allocator,
};

const P = zpc.Zpc(JsonPathContext.config);

fn makeJsonPathParser() P.Parser {
    const intParser = P.takeWhile(.NUMBER, .oneOrMore, std.ascii.isDigit);

    const charParser = P.alt(&.{
        P.left(P.literal("\\"), P.takeUntil(.NONE, .one, std.ascii.isControl)),
        P.takeUntil(.NONE, .oneOrMore, P.predOr(
            std.ascii.isControl,
            P.predSet("\"\\"),
        )),
    });

    const stringParser = P.between(
        P.literal("\""),
        P.span(.STRING, P.many(.NONE, .zeroOrMore, charParser)),
        P.literal("\""),
    );

    const wildParser = P.keyword(.WILD, "*");

    const subscriptParser = P.between(
        P.literal("["),
        P.alt(&.{ wildParser, stringParser, intParser }),
        P.literal("]"),
    );

    const identFirstPred = P.predOr(std.ascii.isAlphabetic, P.predSet("$_"));
    const identRestPred = P.predOr(identFirstPred, std.ascii.isDigit);

    const identParser = P.span(.IDENT, P.left(
        P.takeWhile(.NONE, .one, identFirstPred),
        P.takeWhile(.NONE, .zeroOrMore, identRestPred),
    ));

    const refParser = P.alt(&.{
        subscriptParser,
        identParser,
        wildParser,
    });

    const segmentParser = P.alt(&.{
        // ..foo    SEGMENT(SEARCH, IDENT | WILD)
        // ..[sub]  SEGMENT(SEARCH, NUMBER | STRING | WILD)
        P.seq(.SEGMENT, &.{ P.keyword(.SEARCH, ".."), refParser }),
        // .foo     SEGMENT(SUBSCRIPT, IDENT | WILD)
        // .[sub]   SEGMENT(SUBSCRIPT, NUMBER | STRING | WILD)
        P.seq(.SEGMENT, &.{ P.keyword(.SUBSCRIPT, "."), refParser }),
        // [sub]    SEGMENT(SUBSCRIPT, NUMBER | STRING | WILD)
        P.seq(.SEGMENT, &.{ P.always(.SUBSCRIPT, "."), subscriptParser }),
    });

    return P.between(
        P.literal("$"),
        P.many(.PATH, .zeroOrMore, segmentParser),
        P.eof(),
    );
}

pub fn main(init: std.process.Init) !void {
    const jsonPathParser = makeJsonPathParser();
    const ctx: JsonPathContext = .{ .allocator = init.gpa };

    const paths: []const []const u8 = &.{
        \\$[0].$foo["\""].[*]..$.*
        ,
        \\$
        ,
        \\$.$.x$.$x.$$
        ,
        \\$foo // FAIL
        ,
        \\$..*
        ,
        \\$..[*]
    };

    for (paths) |path| {
        print("Path: {s}\n\n", .{path});
        const res = try jsonPathParser(ctx, path);
        defer res.deinit(ctx);
        print("{f}\n", .{res});
    }
}
