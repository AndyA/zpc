const std = @import("std");
const print = std.debug.print;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc");

const CsvTag = enum(u8) { NONE, QUOTED, BARE, ROW, CSV };
const CsvContext = struct {
    const config: zpc.Config = .{ .Tag = CsvTag, .Context = @This() };
    allocator: Allocator,
};

const C = zpc.Zpc(CsvContext.config);

fn makeCsvParser() C.Parser {
    // Skip horizontal whitespace
    const skipSpace = C.takeWhile(.NONE, .zeroOrMore, C.and_(
        std.ascii.isWhitespace,
        C.not_(C.set_("\r\n")),
    ));

    const charParser = C.alt(&.{
        C.literal("\"\""),
        C.takeUntil(.NONE, .oneOrMore, C.equal_('\"')),
    });

    const stringParser = C.between(
        C.literal("\""),
        C.span(.QUOTED, C.many(.NONE, .zeroOrMore, charParser)),
        C.literal("\""),
    );

    const bareParser = C.span(.BARE, C.takeUntil(.NONE, .zeroOrMore, C.set_(",\r\n")));

    const valueParser = C.right(skipSpace, C.alt(&.{ stringParser, bareParser }));

    const rowParser = C.seq(.ROW, &.{
        valueParser,
        C.flat(C.many(.NONE, .zeroOrMore, C.right(
            C.right(skipSpace, C.literal(",")),
            valueParser,
        ))),
    });

    const eolParser = C.alt(&.{
        C.literal("\n"),
        C.literal("\r\n"),
        C.literal("\r"),
    });

    const csvParser = C.seq(.CSV, &.{
        rowParser,
        C.flat(C.many(.NONE, .zeroOrMore, C.right(
            C.right(skipSpace, eolParser),
            rowParser,
        ))),
    });

    return C.left(
        csvParser,
        C.left(
            C.takeWhile(.NONE, .zeroOrMore, std.ascii.isWhitespace),
            C.eof(),
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
