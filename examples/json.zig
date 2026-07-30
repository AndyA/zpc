const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc").Space(u8);

const JsonTag = enum(u8) {
    NONE,
    NUMBER,
    STRING,
    FALSE,
    TRUE,
    NULL,
    ARRAY,
    OBJECT,
    KEYVALUE,
};

const JsonContext = struct {
    allocator: Allocator,
    jsonParser: *const zpc.ParserType(@This(), JsonTag),
};

const P = zpc.Parsers(JsonContext, JsonTag);
const skipSpace = P.takeWhile(.NONE, .zeroOrMore, std.ascii.isWhitespace);

fn makeListParser(
    tag: JsonTag,
    openParser: P.Parser,
    valueParser: P.Parser,
    closeParser: P.Parser,
) P.Parser {
    return P.between(
        openParser,
        P.many(tag, .zeroOrOne, P.flat(P.seq(.NONE, &.{
            valueParser,
            P.flat(P.many(.NONE, .zeroOrMore, P.right(
                P.right(skipSpace, P.literal(",")),
                valueParser,
            ))),
        }))),
        P.right(skipSpace, closeParser),
    );
}

fn makeJsonParser() P.Parser {
    const intParser = P.takeWhile(.NONE, .oneOrMore, std.ascii.isDigit);

    const posParser =
        P.left(
            P.left(intParser, P.optional(P.left(P.literal("."), intParser))),
            P.optional(P.left(
                P.alt(&.{ P.literal("e"), P.literal("E") }),
                P.left(P.optional(P.alt(&.{ P.literal("+"), P.literal("-") })), intParser),
            )),
        );

    const numParser = P.span(.NUMBER, P.alt(&.{
        P.left(P.literal("-"), posParser),
        posParser,
    }));

    const charParser = P.alt(&.{
        P.left(P.literal("\\"), P.takeWhile(.NONE, .one, zpc.predAny())),
        P.takeUntil(.NONE, .oneOrMore, zpc.predSet("\"\\")),
    });

    const stringParser = P.between(
        P.literal("\""),
        P.span(.STRING, P.many(.NONE, .zeroOrMore, charParser)),
        P.literal("\""),
    );

    const selfParser = P.recurse("jsonParser");

    const kvParser = P.seq(.KEYVALUE, &.{
        P.right(skipSpace, stringParser),
        P.right(P.right(skipSpace, P.literal(":")), selfParser),
    });

    const objectParser = makeListParser(.OBJECT, P.literal("{"), kvParser, P.literal("}"));
    const arrayParser = makeListParser(.ARRAY, P.literal("["), selfParser, P.literal("]"));

    const jsonParser = P.right(skipSpace, P.alt(&.{
        P.keyword(.FALSE, "false"),
        P.keyword(.TRUE, "true"),
        P.keyword(.NULL, "null"),
        stringParser,
        objectParser,
        arrayParser,
        numParser,
    }));

    return jsonParser;
}

pub fn main(init: std.process.Init) !void {
    const jsonParser = makeJsonParser();
    const ctx: JsonContext = .{
        .allocator = init.gpa,
        .jsonParser = jsonParser,
    };
    const res = try jsonParser(ctx,
        \\{
        \\  "things": [ -12.3e+99, 0, false, "Hello\n", [], {} ],
        \\  "name": "Andy",
        \\  "tags": ["A", "B", "C", ["nested", ["deeper"]]],
        \\  "empty": [""]
        \\}
    );
    defer res.deinit(ctx);
    print("{f}", .{res});
}
