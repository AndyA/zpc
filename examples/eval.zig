const std = @import("std");
const print = std.debug.print;
const assert = std.debug.assert;
const expectEqualDeep = std.testing.expectEqualDeep;

const Io = std.Io;
const Allocator = std.mem.Allocator;

const zpc = @import("zpc").Space(u8);

const Tag = enum(u8) {
    N, // means don't care - but `N` is shorter
    IDENT,
    INT,
    UNOPS,
    UNOP,
    BINOPS,
    BINOP,
    NEG,
    @"~",
    @"!",
    @"*",
    @"/",
    @"%",
    @"+",
    @"-",
    @"<",
    @"<=",
    @">",
    @">=",
    @"==",
    @"!=",
};

const Context = struct {
    allocator: Allocator,
    expr: *const zpc.ParserType(@This(), Tag),
};

const P = zpc.Parsers(Context, Tag);

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

    const identFirstPred = zpc.predOr(std.ascii.isAlphabetic, zpc.predEqual('_'));
    const identRestPred = zpc.predOr(identFirstPred, std.ascii.isDigit);

    const identParser = P.span(.IDENT, P.left(
        P.takeWhile(.N, .one, identFirstPred),
        P.takeWhile(.N, .zeroOrMore, identRestPred),
    ));

    const atomParser = P.right(skipSpace, P.alt(&.{
        P.between(P.literal("("), P.recurse("expr"), P.right(skipSpace, P.literal(")"))),
        intParser,
        identParser,
    }));

    const unaryParser = P.alt(&.{
        P.seq(.UNOP, &.{
            P.many(.UNOPS, .oneOrMore, P.right(skipSpace, P.alt(&.{
                P.keyword(.NEG, "-"),
                P.tagName(.@"~"),
                P.tagName(.@"!"),
            }))),
            atomParser,
        }),
        atomParser,
    });

    const mulDivParser = makeBinOpParser(unaryParser, P.alt(&.{
        P.tagName(.@"*"),
        P.tagName(.@"/"),
        P.tagName(.@"%"),
    }));

    const addSubParser = makeBinOpParser(mulDivParser, P.alt(&.{
        P.tagName(.@"+"),
        P.tagName(.@"-"),
    }));

    const cmpParser = makeBinOpParser(addSubParser, P.alt(&.{
        P.tagName(.@"!="),
        P.keyword(.@"!=", "<>"),
        P.tagName(.@"<="),
        P.tagName(.@">="),
        P.tagName(.@"<"),
        P.tagName(.@">"),
        P.tagName(.@"=="),
        P.keyword(.@"==", "="),
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
                    .@"~" => ~res,
                    .@"!" => if (res != 0) 0 else 1,
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
                    .@"+" => res + rhs,
                    .@"-" => res - rhs,
                    .@"*" => res * rhs,
                    .@"/" => @divTrunc(res, rhs),
                    .@"%" => @mod(res, rhs),
                    .@"<=" => boolInt(res <= rhs),
                    .@"<" => boolInt(res < rhs),
                    .@">=" => boolInt(res > rhs),
                    .@">" => boolInt(res > rhs),
                    .@"==" => boolInt(res == rhs),
                    .@"!=" => boolInt(res != rhs),
                    else => unreachable,
                };
            }
            break :eval res;
        },
        .IDENT => 0,
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
        "(3 < 4) + 7 - foo + 6",
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
