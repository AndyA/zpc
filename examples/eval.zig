const std = @import("std");

const zpc = @import("zpc");

const Io = std.Io;
const assert = std.debug.assert;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const expectEqualDeep = std.testing.expectEqualDeep;

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
    const config: zpc.Config = .{ .Tag = Tag, .Context = @This() };
    allocator: Allocator,
    expr: *const zpc.ParserType(config),
};

const C = zpc.Composer(Context.config);

const skipSpace = C.takeWhile(.N, .zeroOrMore, std.ascii.isWhitespace);

fn makeBinOpParser(valueParser: C.Parser, opParser: C.Parser) C.Parser {
    return C.lower(C.seq(.BINOPS, &.{ valueParser, C.flat(
        C.many(.N, .zeroOrMore, C.seq(.BINOP, &.{
            C.right(skipSpace, opParser), valueParser,
        })),
    ) }));
}

fn makeExpressionParser() C.Parser {
    const k = C.keyword;
    const t = C.tagName;
    const l = C.literal;
    const intParser = C.takeWhile(.INT, .oneOrMore, std.ascii.isDigit);

    const identFirstPred = C.P.or_(std.ascii.isAlphabetic, C.P.equal_('_'));
    const identRestPred = C.P.or_(identFirstPred, std.ascii.isDigit);

    const identParser = C.span(.IDENT, C.left(
        C.takeWhile(.N, .one, identFirstPred),
        C.takeWhile(.N, .zeroOrMore, identRestPred),
    ));

    const atomParser = C.right(skipSpace, C.alt(&.{
        C.between(l("("), C.recurse("expr"), C.right(skipSpace, l(")"))),
        intParser,
        identParser,
    }));

    const unaryParser = C.alt(&.{
        C.seq(.UNOP, &.{ C.many(.UNOPS, .oneOrMore, C.right(
            skipSpace,
            C.alt(&.{
                k(.NEG, "-"),
                t(.@"~"),
                t(.@"!"),
            }),
        )), atomParser }),
        atomParser,
    });

    const mulDivParser = makeBinOpParser(
        unaryParser,
        C.alt(&.{
            t(.@"*"),
            t(.@"/"),
            t(.@"%"),
        }),
    );

    const addSubParser = makeBinOpParser(
        mulDivParser,
        C.alt(&.{
            t(.@"+"),
            t(.@"-"),
        }),
    );

    const cmpParser = makeBinOpParser(addSubParser, C.alt(&.{
        t(.@"!="),
        k(.@"!=", "<>"),
        t(.@"<="),
        t(.@">="),
        t(.@"<"),
        t(.@">"),
        t(.@"=="),
        k(.@"==", "="),
    }));

    return cmpParser;
}

fn boolInt(b: bool) i64 {
    return if (b) 1 else 0;
}

fn eval(token: C.Token) !i64 {
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
    const fullParser = C.left(exprParser, C.left(skipSpace, C.eof()));
    const ctx: Context = .{ .allocator = init.gpa, .expr = exprParser };

    const expressions: []const []const u8 = &.{
        "-1 + 3",
        "--(100 + 2 - 9) / 3 - ~10",
        "(3 < 4 - q) + 7 - foo + 6",
    };

    for (expressions) |path| {
        print("expr: {s}\n\n", .{path});
        const res = try fullParser(ctx, path);
        defer res.deinit(ctx);
        print("{f}\n", .{res.pretty()});
        if (res.succeeded())
            print("result: {d}\n\n", .{try eval(res.tok.ok)});
    }
}
