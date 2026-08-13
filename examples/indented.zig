const std = @import("std");

const zpc = @import("zpc");

const Io = std.Io;
const assert = std.debug.assert;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const expectEqualDeep = std.testing.expectEqualDeep;

const IndentTag = enum(u8) { NONE, IN, SAME, OUT, BLOCK, LINE, PROG };

const IndentContext = struct {
    const Self = @This();
    const config: zpc.Config = .{ .Tag = IndentTag, .Context = Self };

    allocator: Allocator,
    indent: []const u8 = "",

    pub fn withIndent(self: Self, indent: []const u8) Self {
        var nest = self;
        nest.indent = indent;
        return nest;
    }
};

const C = zpc.Composer(IndentContext.config);

const skipSpace = C.takeWhile(.NONE, .zeroOrMore, std.ascii.isWhitespace);
const skipHorizontalSpace = C.takeWhile(.NONE, .zeroOrMore, C.P.set_(" \t"));
const parseLine = C.takeUntil(.LINE, .oneOrMore, C.P.set_("\r\n"));

const parseNewline = C.alt(&.{
    C.literal("\n\r"),
    C.literal("\n"),
    C.literal("\r\n"),
    C.literal("\r"),
});

const parseLineAndNewline = C.left(parseLine, parseNewline);

fn parseIndent(ctx: IndentContext, input: []const u8) zpc.Error!C.Result {
    const lws = try skipHorizontalSpace(ctx, input);
    if (!lws.succeeded()) return lws;

    const newline = try parseNewline(ctx, lws.rest);

    // Empty line of whitespace?
    if (newline.succeeded())
        return .initOk(.initNothing(input), newline.rest);

    const indent = lws.tok.ok.value.slice;

    if (indent.len == ctx.indent.len and std.mem.eql(u8, indent, ctx.indent))
        return .initOk(.initSlice(input, .SAME, indent), input[indent.len..])
    else if (indent.len > ctx.indent.len and std.mem.startsWith(u8, indent, ctx.indent))
        return .initOk(.initSlice(input, .IN, indent), input[indent.len..])
    else if (std.mem.startsWith(u8, ctx.indent, indent))
        return .initOk(.initSlice(input, .OUT, indent), input[indent.len..])
    else
        return .initFailHere(input);
}

fn parseCode(ctx: IndentContext, input: []const u8) zpc.Error!C.Result {
    const indent = try parseIndent(ctx, input);
    if (!indent.succeeded()) return indent;

    switch (indent.tok.ok.tag) {
        .IN => {
            const nest = ctx.withIndent(indent.tok.ok.value.slice);
            var list: C.Token.ArrayList = .empty;
            errdefer C.Token.deinitArrayList(&list, nest);

            var tail = indent.rest;
            {
                const res = try parseLineAndNewline(nest, tail);
                if (!res.succeeded()) {
                    C.Token.deinitArrayList(&list, nest);
                    return res;
                }
                try res.tok.ok.appendToArrayList(nest, &list);
                tail = res.rest;
            }

            lines: while (true) {
                const res = try parseCode(nest, tail);
                if (!res.succeeded()) {
                    C.Token.deinitArrayList(&list, nest);
                    return res;
                }
                switch (res.tok.ok.tag) {
                    .NONE => {},
                    .OUT => break :lines,
                    else => try res.tok.ok.appendToArrayList(nest, &list),
                }
                tail = res.rest;
            }

            return .initOk(
                try .initArrayList(nest, input, .BLOCK, &list),
                tail,
            );
        },
        .SAME => return try parseLineAndNewline(ctx, indent.rest),
        .OUT, .NONE => return indent,
        else => unreachable,
    }
}

const parseProgram = C.many(.PROG, .zeroOrMore, parseCode);

pub fn main(init: std.process.Init) !void {
    const ctx: IndentContext = .{ .allocator = init.gpa };

    const codes: []const []const u8 = &.{
        \\A
        \\B
        \\C
        \\
        ,
        \\A
        \\
        \\  B
        \\  C
        \\    D
        \\    E
        \\F
        \\
    };

    for (codes) |code| {
        print("Code:\n{s}\n\n", .{code});
        const res = try parseProgram(ctx, code);
        defer res.deinit(ctx);
        print("{f}\n", .{res.pretty()});
    }
}
