const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc");

const Tag = enum(u8) {
    N, // means don't care - but `N` is shorter
    INT,
    UNOPS,
    UNOP,
    BINOPS,
    BINOP,
    NEG,
    FLIP,
    NOT,
    MUL,
    DIV,
    MOD,
    ADD,
    SUB,
    LT,
    LTE,
    GT,
    GTE,
    EQ,
    NE,
};

const Context = struct {
    allocator: Allocator,
    expr: *const zpc.ZpcParserForTag(@This(), Tag, .run),
};

const P = zpc.Zpc(Context, Tag);

const skipSpace = P.takeWhile(.N, .zeroOrMore, std.ascii.isWhitespace);

fn makeBinOpParser(valueParser: P.Parser, opParser: P.Parser) P.Parser {
    return P.lower(P.seq(.BINOPS, &.{ valueParser, P.flat(
        P.many(.N, .zeroOrMore, P.seq(.BINOP, &.{
            P.right(skipSpace, opParser), valueParser,
        })),
    ) }));
}

fn makeExpressionParser() P.Parser {
    const intParser = P.takeWhile(.INT, .oneOrMore, std.ascii.isDigit);

    const atomParser = P.right(skipSpace, P.alt(&.{
        P.between(P.literal("("), P.recurse("expr"), P.right(skipSpace, P.literal(")"))),
        intParser,
    }));

    const unaryParser = P.alt(&.{
        P.seq(.UNOP, &.{
            P.many(.UNOPS, .oneOrMore, P.right(skipSpace, P.alt(&.{
                P.keyword(.NEG, "-"),
                P.keyword(.FLIP, "~"),
                P.keyword(.NOT, "!"),
            }))),
            atomParser,
        }),
        atomParser,
    });

    const mulDivParser = makeBinOpParser(unaryParser, P.alt(&.{
        P.keyword(.MUL, "*"),
        P.keyword(.DIV, "/"),
        P.keyword(.MOD, "%"),
    }));

    const addSubParser = makeBinOpParser(mulDivParser, P.alt(&.{
        P.keyword(.ADD, "+"),
        P.keyword(.SUB, "-"),
    }));

    const cmpParser = makeBinOpParser(addSubParser, P.alt(&.{
        P.keyword(.NE, "!="),
        P.keyword(.NE, "<>"),
        P.keyword(.LTE, "<="),
        P.keyword(.GTE, ">="),
        P.keyword(.LT, "<"),
        P.keyword(.GT, ">"),
        P.keyword(.EQ, "=="),
        P.keyword(.EQ, "="),
    }));

    return cmpParser;
}

fn boolInt(b: bool) i64 {
    return if (b) 1 else 0;
}

fn eval(token: P.Token) !i64 {
    return eval: switch (token.tag) {
        .INT => try std.fmt.parseInt(i64, token.value.slice, 10),
        .UNOP => {
            var res = try eval(token.other());
            const head = token.head();
            assert(head.tag == .UNOPS);
            const kids = head.children();
            for (0..kids.len) |i|
                res = switch (kids[kids.len - 1 - i].tag) {
                    .NEG => -res,
                    .FLIP => ~res,
                    .NOT => if (res != 0) 0 else 1,
                    else => unreachable,
                };
            break :eval res;
        },
        .BINOPS => {
            var res = try eval(token.head());
            for (token.tail()) |op| {
                assert(op.tag == .BINOP);
                const rhs = try eval(op.other());
                res = switch (op.head().tag) {
                    .ADD => res + rhs,
                    .SUB => res - rhs,
                    .MUL => res * rhs,
                    .DIV => @divTrunc(res, rhs),
                    .MOD => @mod(res, rhs),
                    .LTE => boolInt(res <= rhs),
                    .LT => boolInt(res < rhs),
                    .GTE => boolInt(res > rhs),
                    .GT => boolInt(res > rhs),
                    .EQ => boolInt(res == rhs),
                    .NE => boolInt(res != rhs),
                    else => unreachable,
                };
            }
            break :eval res;
        },
        else => unreachable,
    };
}

pub fn main(init: std.process.Init) !void {
    const exprParser = makeExpressionParser();
    const fullParser = P.left(exprParser, P.left(skipSpace, P.eof()));
    const ctx: Context = .{ .allocator = init.gpa, .expr = exprParser };

    const expressions: []const []const u8 = &.{
        "-1 + 3",
        "--(100 + 2 - 9) / 3 - ~10",
        "(3 < 4) + 7",
    };

    for (expressions) |path| {
        print("expr: {s}\n\n", .{path});
        const res = try fullParser(ctx, path);
        defer res.deinit(ctx);
        print("{f}\n", .{res});
        if (res.matched())
            print("result: {d}\n\n", .{try eval(res.tok.ok)});
    }
}
