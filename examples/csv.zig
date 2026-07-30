const std = @import("std");
const print = std.debug.print;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc");

const CsvTag = enum(u8) { NONE, QUOTED, BARE, ROW, CSV };
const CsvContext = struct {
    pub const config: zpc.ZpcConfig = .{ .Tag = CsvTag, .Context = @This() };
    allocator: Allocator,
};

const P = zpc.Zpc(CsvContext.config);

fn makeCsvParser() P.Parser {
    // Skip horizontal whitespace
    const skipSpace = P.takeWhile(.NONE, .zeroOrMore, P.predAnd(
        std.ascii.isWhitespace,
        P.predNot(P.predSet("\r\n")),
    ));

    const charParser = P.alt(&.{
        P.literal("\"\""),
        P.takeUntil(.NONE, .oneOrMore, P.predEqual('\"')),
    });

    const stringParser = P.between(
        P.literal("\""),
        P.span(.QUOTED, P.many(.NONE, .zeroOrMore, charParser)),
        P.literal("\""),
    );

    const bareParser = P.span(.BARE, P.takeUntil(.NONE, .zeroOrMore, P.predSet(",\r\n")));

    const valueParser = P.right(skipSpace, P.alt(&.{ stringParser, bareParser }));

    const rowParser = P.seq(.ROW, &.{
        valueParser,
        P.flat(P.many(.NONE, .zeroOrMore, P.right(
            P.right(skipSpace, P.literal(",")),
            valueParser,
        ))),
    });

    const eolParser = P.alt(&.{
        P.literal("\n"),
        P.literal("\r\n"),
        P.literal("\r"),
    });

    const csvParser = P.seq(.CSV, &.{
        rowParser,
        P.flat(P.many(.NONE, .zeroOrMore, P.right(
            P.right(skipSpace, eolParser),
            rowParser,
        ))),
    });

    return P.left(
        csvParser,
        P.left(
            P.takeWhile(.NONE, .zeroOrMore, std.ascii.isWhitespace),
            P.eof(),
        ),
    );
}

pub fn main(init: std.process.Init) !void {
    const jsonParser = makeCsvParser();
    const ctx: CsvContext = .{ .allocator = init.gpa };
    const res = try jsonParser(ctx,
        \\"""Hello", "World""", Now
        \\"
        \\"
        \\1,2,3,4
    );
    defer res.deinit(ctx);
    print("{f}", .{res});
}
