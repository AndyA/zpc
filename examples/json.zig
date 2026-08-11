const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc");

const JsonTag = enum(u8) {
    NONE,
    MULTI,
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

const C = zpc.Compiler(JsonContext.config);

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
                C.left(
                    C.optional(C.alt(&.{ C.literal("+"), C.literal("-") })),
                    intParser,
                ),
            )),
        );

    const numParser = C.span(.NUMBER, C.alt(&.{
        C.left(C.literal("-"), posParser),
        posParser,
    }));

    const charParser = C.alt(&.{
        C.left(C.literal("\\"), C.takeWhile(.NONE, .one, C.P.any_())),
        C.takeUntil(.NONE, .oneOrMore, C.P.set_("\"\\")),
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

    const objectParser = makeListParser(
        .OBJECT,
        C.literal("{"),
        kvParser,
        C.literal("}"),
    );
    const arrayParser = makeListParser(
        .ARRAY,
        C.literal("["),
        selfParser,
        C.literal("]"),
    );

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
    const gapParser = C.left(skipSpace, C.optional(C.literal(",")));
    const jsonGapParser = C.left(jsonParser, gapParser);
    const multiJsonParser = C.left(
        C.lower(C.many(.MULTI, .zeroOrMore, jsonGapParser)),
        C.left(skipSpace, C.eof()),
    );
    const ctx: JsonContext = .{
        .allocator = init.gpa,
        .jsonParser = jsonParser,
    };
    const res = try multiJsonParser(ctx,
        \\{
        \\  "things": [ -12.3e+99, 0, false, "Hello\n", [], {} ],
        \\  "name": "Andy",
        \\  "tags": ["A", "B", "C", ["nested", ["deeper"]]],
        \\  "empty": [""]
        \\}
        \\{"id":1} {"id":2} {"id":3}
    );
    defer res.deinit(ctx);
    print("{f}", .{res.pretty()});
}
