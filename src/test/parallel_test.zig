// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Record-boundary splitting (`core/parallel.zig`). The oracle is the definition of a
//! correct split, not the split algorithm: parsing the ranges one after another with
//! the scalar `Parser` must give exactly the field sequence of parsing the whole input.

const std = @import("std");
const testing = std.testing;
const csv = @import("../csv.zig");
const parallel = csv.parallel;

/// Field-sequence digest of `input` parsed by the scalar oracle, fed into `h`.
fn feed(h: *std.hash.Wyhash, input: []const u8) !void {
    var scratch: [1 << 16]u8 = undefined;
    var p = try csv.Parser.init(input, &scratch, .{});
    while (try p.next()) |f| {
        const len: u64 = f.bytes.len;
        h.update(std.mem.asBytes(&len));
        h.update(f.bytes);
        h.update(if (f.last_in_record) "\x01" else "\x00");
        p.resetScratch();
    }
}

fn digestWhole(input: []const u8) !u64 {
    var h = std.hash.Wyhash.init(0);
    try feed(&h, input);
    return h.final();
}

fn digestSplit(input: []const u8, bounds: []const usize) !u64 {
    var h = std.hash.Wyhash.init(0);
    for (bounds[0 .. bounds.len - 1], bounds[1..]) |a, b| {
        try testing.expect(a <= b);
        try feed(&h, input[a..b]);
    }
    return h.final();
}

/// Random strict-RFC-4180 CSV: quoted fields with embedded newlines, CRLF and lone-CR
/// terminators inside them, escaped quotes, long quoted fields, empty fields, and
/// records ended by `\n`, `\r\n` or `\r`.
fn genCsv(alloc: std.mem.Allocator, seed: u64, records: usize) ![]u8 {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var b: std.ArrayList(u8) = .empty;
    for (0..records) |_| {
        const cols = 1 + r.uintLessThan(usize, 5);
        for (0..cols) |c| {
            if (c > 0) try b.append(alloc, ',');
            switch (r.uintLessThan(u8, 6)) {
                0 => {},
                1, 2 => for (0..r.uintLessThan(usize, 12)) |_| try b.append(alloc, 'a' + r.uintLessThan(u8, 26)),
                else => {
                    try b.append(alloc, '"');
                    const n = if (r.uintLessThan(u8, 10) == 0) 50 + r.uintLessThan(usize, 200) else r.uintLessThan(usize, 16);
                    for (0..n) |_| {
                        const pieces = [_][]const u8{ "x", "y", ",", "\n", "\r\n", "\r", "\"\"" };
                        try b.appendSlice(alloc, pieces[r.uintLessThan(usize, pieces.len)]);
                    }
                    try b.append(alloc, '"');
                },
            }
        }
        const ends = [_][]const u8{ "\n", "\r\n", "\r" };
        try b.appendSlice(alloc, ends[r.uintLessThan(usize, ends.len)]);
    }
    if (r.boolean() and b.items.len > 0) _ = b.pop(); // sometimes no final terminator
    return b.toOwnedSlice(alloc);
}

test "parallel: countQuotes matches a byte count" {
    const input = "\"a\"\",\"b\"\n" ** 40 ++ "tail\"";
    var want: u64 = 0;
    for (input) |c| want += @intFromBool(c == '"');
    try testing.expectEqual(want, parallel.countQuotes(input, '"'));
    try testing.expectEqual(@as(u64, 0), parallel.countQuotes("", '"'));
}

test "parallel: splitRecords is exact for every worker count, over random inputs" {
    const alloc = testing.allocator;
    for (0..40) |seed| {
        const input = try genCsv(alloc, seed, 30 + seed * 7);
        defer alloc.free(input);
        const want = try digestWhole(input);
        var bounds: [18]usize = undefined;
        for (1..17) |n| {
            try parallel.splitRecords(input, .{}, bounds[0 .. n + 1]);
            try testing.expectEqual(@as(usize, 0), bounds[0]);
            try testing.expectEqual(input.len, bounds[n]);
            try testing.expectEqual(want, try digestSplit(input, bounds[0 .. n + 1]));
        }
    }
}

test "parallel: recordStartAfter is a record start from every cut point" {
    const alloc = testing.allocator;
    for (100..112) |seed| {
        const input = try genCsv(alloc, seed, 25);
        defer alloc.free(input);
        const want = try digestWhole(input);
        var cuts_in_quotes: usize = 0;
        for (0..input.len + 1) |cut| {
            const in_quote = parallel.countQuotes(input[0..cut], '"') % 2 == 1;
            cuts_in_quotes += @intFromBool(in_quote);
            const b = parallel.recordStartAfter(input, cut, in_quote, .{});
            try testing.expect(b >= cut);
            try testing.expectEqual(want, try digestSplit(input, &.{ 0, b, input.len }));
        }
        // The inputs must actually put cuts inside quoted fields, or the in-quote state
        // is never exercised.
        try testing.expect(cuts_in_quotes > input.len / 10);
    }
}

test "parallel: CRLF split by the cut is never torn apart" {
    const input = "a,b\r\nc,d\r\ne,f\r\n";
    const want = try digestWhole(input);
    for (0..input.len + 1) |cut| {
        const b = parallel.recordStartAfter(input, cut, false, .{});
        try testing.expect(b == 0 or b == 5 or b == 10 or b == 15);
        try testing.expectEqual(want, try digestSplit(input, &.{ 0, b, input.len }));
    }
}

test "parallel: an odd number of quotes is UnterminatedQuote" {
    var bounds: [5]usize = undefined;
    try testing.expectError(csv.Error.UnterminatedQuote, parallel.splitRecords("a,\"b\nc,d\n", .{}, &bounds));
}

test "parallel: one record spanning every cut gives empty middle ranges" {
    const input = "\"" ++ "x\n" ** 200 ++ "\"\nlast\n";
    var bounds: [9]usize = undefined;
    try parallel.splitRecords(input, .{}, &bounds);
    try testing.expectEqual(try digestWhole(input), try digestSplit(input, &bounds));
}
