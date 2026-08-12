const std = @import("std");

const zpc = @import("zpc");

const Io = std.Io;
const assert = std.debug.assert;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const expectEqualDeep = std.testing.expectEqualDeep;

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
    ALT, // to be used to build trees of paths
};

const JsonPathContext = struct {
    allocator: Allocator,
};

const jsonPathParser = blk: {
    const C = zpc.Composer(.{
        .Tag = JsonPathTag,
        .Context = JsonPathContext,
    });
    const intParser = C.takeWhile(.NUMBER, .oneOrMore, std.ascii.isDigit);

    const identFirstPred = C.P.or_(std.ascii.isAlphabetic, C.P.set_("$_"));
    const identRestPred = C.P.or_(identFirstPred, std.ascii.isDigit);

    const identParser = C.span(.IDENT, C.left(
        C.takeWhile(.NONE, .one, identFirstPred),
        C.takeWhile(.NONE, .zeroOrMore, identRestPred),
    ));

    const charParser = C.alt(&.{
        C.left(C.literal("\\"), C.takeUntil(.NONE, .one, std.ascii.isControl)),
        C.takeUntil(.NONE, .oneOrMore, C.P.or_(
            std.ascii.isControl,
            C.P.set_("\"\\"),
        )),
    });

    const stringParser = C.between(
        C.literal("\""),
        C.span(.STRING, C.many(.NONE, .zeroOrMore, charParser)),
        C.literal("\""),
    );

    // Any string that's a valid identifier can be replaced with the
    // identifier.
    const stringIdentParser = C.refineSlice(stringParser, identParser);

    const wildParser = C.keyword(.WILD, "*");

    const subscriptParser = C.between(
        C.literal("["),
        C.alt(&.{ wildParser, stringIdentParser, intParser }),
        C.literal("]"),
    );

    const refParser = C.alt(&.{
        subscriptParser,
        identParser,
        wildParser,
    });

    const segmentParser = C.alt(&.{
        // ..foo    SEGMENT(SEARCH,    IDENT | WILD)
        // ..[sub]  SEGMENT(SEARCH,    IDENT | NUMBER | STRING | WILD)
        C.seq(.SEGMENT, &.{ C.keyword(.SEARCH, ".."), refParser }),
        // .foo     SEGMENT(SUBSCRIPT, IDENT | WILD)
        // .[sub]   SEGMENT(SUBSCRIPT, IDENT | NUMBER | STRING | WILD)
        C.seq(.SEGMENT, &.{ C.keyword(.SUBSCRIPT, "."), refParser }),
        // [sub]    SEGMENT(SUBSCRIPT, IDENT | NUMBER | STRING | WILD)
        C.seq(.SEGMENT, &.{ C.always(.SUBSCRIPT, "."), subscriptParser }),
    });

    break :blk C.between(
        C.literal("$"),
        C.many(.PATH, .zeroOrMore, segmentParser),
        C.eof(),
    );
};

pub fn main(init: std.process.Init) !void {
    const ctx: JsonPathContext = .{ .allocator = init.gpa };

    const paths: []const []const u8 = &.{
        \\$["name"].$foo["\""].[*]..$.*
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
        ,
        \\$["foo"]
    };

    for (paths) |path| {
        print("Path: {s}\n\n", .{path});
        const res = try jsonPathParser(ctx, path);
        defer res.deinit(ctx);
        print("{f}\n", .{res.pretty()});
    }
}
