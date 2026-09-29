// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! The strict (SIMD) paths never misparse silently: every input that is not valid
//! RFC 4180 fails with a named error on each entry point (`next`, `nextInto`,
//! `forEachField`, `streamReader`). Before v0.4 a stray quote in an unquoted field
//! merged the rest of the input into one field with no error.

const std = @import("std");
const testing = std.testing;
const csv = @import("../csv.zig");
const Error = csv.Error;

const Sink = struct {
    fn on(_: *Sink, _: []const u8, _: bool) void {}
};

/// Run every strict entry point over `input`; each must fail, with `want` if given.
fn expectStrictError(input: []const u8, want: ?anyerror) !void {
    var scratch: [4096]u8 = undefined;

    const pull: anyerror!void = blk: {
        var p = csv.SimdParser.init(input, &scratch, .{}) catch |e| break :blk e;
        while (p.next() catch |e| break :blk e) |_| p.resetScratch();
    };
    const batch: anyerror!void = blk: {
        var p = csv.SimdParser.init(input, &scratch, .{}) catch |e| break :blk e;
        var fields: [3]csv.Field = undefined;
        while ((p.nextInto(&fields) catch |e| break :blk e) != 0) p.resetScratch();
    };
    var sink = Sink{};
    const push: anyerror!void = csv.simd.forEachField(input, &scratch, .{}, &sink, Sink.on);
    const stream: anyerror!void = blk: {
        var r = std.Io.Reader.fixed(input);
        var ss: [4096]u8 = undefined;
        csv.streamReader(&r, &ss, .{}, &sink, Sink.on) catch |e| break :blk e;
    };

    for ([_]anyerror!void{ pull, batch, push, stream }) |got| {
        if (want) |w| {
            try testing.expectError(w, got);
        } else if (got) |_| return error.TestExpectedError else |_| {}
    }
}

test "strict: stray quote in an unquoted field is InvalidQuote" {
    try expectStrictError("id,item,v\n1,3\" pipe,1.5\n2,plain,2.5\n3,other,3.5\n", Error.InvalidQuote);
}

test "strict: stray quote in the last field of a record" {
    try expectStrictError("id,item\n1,6\"\n2,ok\n", Error.InvalidQuote);
}

test "strict: lone quote at the very end of an unquoted field" {
    try expectStrictError("a,b\"", Error.InvalidQuote);
}

test "strict: stray quote followed later by a real quoted field" {
    try expectStrictError("id,x\n1,3\" pipe\n2,\"q\"\n3,z\n", null);
}

test "strict: text after a closing quote is InvalidQuote" {
    try expectStrictError("a,b\n\"x\"y,1\n", Error.InvalidQuote);
}

test "strict: a lone interior quote is not an escape pair" {
    try expectStrictError("a\n\"a\"b\"c\"\n", Error.InvalidQuote);
}

test "strict: a quote left open at end of input is UnterminatedQuote" {
    try expectStrictError("a,b\n1,\"open\n2,x\n", Error.UnterminatedQuote);
    try expectStrictError("a\n\"", Error.UnterminatedQuote);
}

test "strict: stray quote on every offset around the first chunk boundary" {
    var buf: [256]u8 = undefined;
    var n: usize = 0;
    for ("a,b\n") |c| {
        buf[n] = c;
        n += 1;
    }
    while (n + 22 <= buf.len) : (n += 22) @memcpy(buf[n..][0..22], "xxxxxxxxxx,yyyyyyyyyy\n");
    for (56..72) |at| {
        var input = buf;
        input[at] = '"';
        try expectStrictError(input[0..n], null);
    }
}

test "strict: valid quoting still parses (escapes, empty, quoted separators)" {
    const input = "a,b\n\"he said \"\"hi\"\"\",\"\"\n\"x,y\",\"1\n2\"\n";
    var scratch: [256]u8 = undefined;
    var p = try csv.SimdParser.init(input, &scratch, .{});
    var rec: [4][]const u8 = undefined;
    _ = (try p.nextRecord(&rec)).?;
    const r1 = (try p.nextRecord(&rec)).?;
    try testing.expectEqualStrings("he said \"hi\"", r1[0]);
    try testing.expectEqualStrings("", r1[1]);
    const r2 = (try p.nextRecord(&rec)).?;
    try testing.expectEqualStrings("x,y", r2[0]);
    try testing.expectEqualStrings("1\n2", r2[1]);
    try testing.expect((try p.nextRecord(&rec)) == null);
}
