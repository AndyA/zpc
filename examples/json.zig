const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc");

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
    const config: zpc.Config = .{ .Tag = JsonTag, .Context = @This() };

    allocator: Allocator,
    jsonParser: *const zpc.ParserType(config),
};

const C = zpc.Zpc(JsonContext.config);

const skipSpace = C.takeWhile(.NONE, .zeroOrMore, std.ascii.isWhitespace);

fn makeListParser(
    tag: JsonTag,
    openParser: C.Parser,
    valueParser: C.Parser,
    closeParser: C.Parser,
) C.Parser {
    return C.between(
        openParser,
        C.many(tag, .zeroOrOne, C.flat(C.seq(.NONE, &.{
            valueParser,
            C.flat(C.many(.NONE, .zeroOrMore, C.right(
                C.right(skipSpace, C.literal(",")),
                valueParser,
            ))),
        }))),
        C.right(skipSpace, closeParser),
    );
}

fn makeJsonParser() C.Parser {
    const intParser = C.takeWhile(.NONE, .oneOrMore, std.ascii.isDigit);

    const posParser =
        C.left(
            C.left(intParser, C.optional(C.left(C.literal("."), intParser))),
            C.optional(C.left(
                C.alt(&.{ C.literal("e"), C.literal("E") }),
                C.left(C.optional(C.alt(&.{ C.literal("+"), C.literal("-") })), intParser),
            )),
        );

    const numParser = C.span(.NUMBER, C.alt(&.{
        C.left(C.literal("-"), posParser),
        posParser,
    }));

    const charParser = C.alt(&.{
        C.left(C.literal("\\"), C.takeWhile(.NONE, .one, C.any_())),
        C.takeUntil(.NONE, .oneOrMore, C.set_("\"\\")),
    });

    const stringParser = C.between(
        C.literal("\""),
        C.span(.STRING, C.many(.NONE, .zeroOrMore, charParser)),
        C.literal("\""),
    );

    const selfParser = C.recurse("jsonParser");

    const kvParser = C.seq(.KEYVALUE, &.{
        C.right(skipSpace, stringParser),
        C.right(C.right(skipSpace, C.literal(":")), selfParser),
    });

    const objectParser = makeListParser(.OBJECT, C.literal("{"), kvParser, C.literal("}"));
    const arrayParser = makeListParser(.ARRAY, C.literal("["), selfParser, C.literal("]"));

    const jsonParser = C.right(skipSpace, C.alt(&.{
        C.keyword(.FALSE, "false"),
        C.keyword(.TRUE, "true"),
        C.keyword(.NULL, "null"),
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
