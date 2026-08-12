const std = @import("std");

const zpc = @import("zpc");

const Io = std.Io;
const assert = std.debug.assert;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const expectEqualDeep = std.testing.expectEqualDeep;

const IndentTag = enum(u8) { NONE, LINE, BLOCK };

const IndentContext = struct {
    const config: zpc.Config = .{
        .Tag = IndentTag,
        .Context = @This(),
    };
    allocator: Allocator,
    blockParser: *const zpc.ParserType(config),
    indent: []const u8 = &[_]u8{},
};

const C = zpc.Compiler(IndentContext.config);

fn isHorizontalWhitespace(c: u8) bool {
    return std.ascii.isWhitespace(c) and !std.ascii.isControl(c);
}

const parseHorizontalWhitespace = C.takeWhile(
    .NONE,
    .zeroOrMore,
    isHorizontalWhitespace,
);

fn indentBlock() C.Parser {
    const shim = struct {
        fn parser(ctx: IndentContext, input: []const u8) zpc.Error!C.Result {
            var list: C.Token.ArrayList = .empty;
            errdefer C.Token.deinitArrayList(&list, ctx);
            blk: while (true) {
                const lws = try parseHorizontalWhitespace(ctx, input);
                // Infallible
                assert(lws.tok == .ok);
                const pad = lws.tok.ok.value.slice;
                // Outdent?
                if (pad.len < ctx.indent.len) {
                    if (std.mem.startsWith(u8, ctx.indent, pad))
                        break :blk;
                    return .initFailHere(input);
                }
                // Indent?
                if (pad.len > ctx.indent.len) {
                    if (!std.mem.startsWith(u8, pad, ctx.indent))
                        return .initFailHere(input);
                    const nest: IndentContext = .{
                        .allocator = ctx.allocator,
                        .blockParser = ctx.blockParser,
                        .indent = pad,
                    };
                    //const nest_res = try nest.blockParser(nest,
                    _ = nest;
                }
            }
            return .initFailHere(input);
        }
    };
    return shim.parser;
}

const blockParser = blk: {
    const foo = indentBlock();
    break :blk foo;
};

pub fn main(init: std.process.Init) !void {
    const ctx: IndentContext = .{
        .allocator = init.gpa,
        .blockParser = blockParser,
    };
    _ = ctx;
}
