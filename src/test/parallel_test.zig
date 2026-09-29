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

// ---------------------------------------------------------------------------
// parallel.forEachField: concatenated sink output == serial output, errors == serial
// ---------------------------------------------------------------------------

/// Serializes every field it receives (length-prefixed bytes + record-end flag).
const Collector = struct {
    out: std.ArrayList(u8) = .empty,
    fail: bool = false,

    fn on(self: *Collector, bytes: []const u8, last: bool) void {
        const len: u32 = @intCast(bytes.len);
        self.out.appendSlice(testing.allocator, std.mem.asBytes(&len)) catch {
            self.fail = true;
        };
        self.out.appendSlice(testing.allocator, bytes) catch {
            self.fail = true;
        };
        self.out.append(testing.allocator, @intFromBool(last)) catch {
            self.fail = true;
        };
    }
};

fn serialOf(input: []const u8, scratch: []u8) !std.ArrayList(u8) {
    var c = Collector{};
    try csv.simd.forEachField(input, scratch, .{}, &c, Collector.on);
    try testing.expect(!c.fail);
    return c.out;
}

/// Parallel parse with `n` workers; returns the concatenated sink output.
fn parallelOf(io: std.Io, input: []const u8, n: usize) !std.ArrayList(u8) {
    var cols: [16]Collector = @splat(.{});
    var ptrs: [16]*Collector = undefined;
    var bufs: [16][1024]u8 = undefined;
    var scratches: [16][]u8 = undefined;
    for (0..n) |i| {
        ptrs[i] = &cols[i];
        scratches[i] = &bufs[i];
    }
    defer for (cols[0..n]) |*c| c.out.deinit(testing.allocator);
    try csv.parallel.forEachField(io, input, .{}, scratches[0..n], ptrs[0..n], Collector.on);
    var all: std.ArrayList(u8) = .empty;
    for (cols[0..n]) |*c| {
        try testing.expect(!c.fail);
        try all.appendSlice(testing.allocator, c.out.items);
    }
    return all;
}

fn expectParallelMatchesSerial(io: std.Io, input: []const u8) !void {
    var scratch: [1024]u8 = undefined;
    var want = try serialOf(input, &scratch);
    defer want.deinit(testing.allocator);
    for (1..17) |n| {
        var got = try parallelOf(io, input, n);
        defer got.deinit(testing.allocator);
        try testing.expectEqualSlices(u8, want.items, got.items);
    }
}

test "parallel: forEachField output equals serial for N = 1..16 (testing io)" {
    const alloc = testing.allocator;
    for (200..230) |seed| {
        const input = try genCsv(alloc, seed, 40 + (seed % 7) * 30);
        defer alloc.free(input);
        try expectParallelMatchesSerial(testing.io, input);
    }
}

test "parallel: forEachField output equals serial on a real thread pool" {
    const alloc = testing.allocator;
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for (300..316) |seed| {
        const input = try genCsv(alloc, seed, 400);
        defer alloc.free(input);
        try expectParallelMatchesSerial(io, input);
    }
    try expectParallelMatchesSerial(io, "");
    try expectParallelMatchesSerial(io, "only,one,record");
}

fn parallelErr(io: std.Io, input: []const u8, n: usize) ?anyerror {
    var got = parallelOf(io, input, n) catch |e| return e;
    got.deinit(testing.allocator);
    return null;
}

fn serialErr(input: []const u8) ?anyerror {
    var scratch: [1024]u8 = undefined;
    var c = Collector{};
    defer c.out.deinit(testing.allocator);
    csv.simd.forEachField(input, &scratch, .{}, &c, Collector.on) catch |e| return e;
    return null;
}

test "parallel: invalid quoting reports the same error as the serial parse" {
    const alloc = testing.allocator;
    const fixed = [_][]const u8{
        "id,item,v\n1,3\" pipe,1.5\n2,plain,2.5\n3,other,3.5\n",
        "a,b\n\"x\"y,1\n",
        "a,b\n1,\"open\n2,x\n",
        "a\n\"a\"b\"c\"\n",
        "id,x\n1,3\" pipe\n2,\"q\"\n3,z\n",
    };
    var threaded = std.Io.Threaded.init(alloc, .{});
    defer threaded.deinit();
    for (fixed) |input| {
        const want = serialErr(input) orelse return error.TestExpectedError;
        for (1..9) |n| try testing.expectEqual(want, parallelErr(threaded.io(), input, n).?);
    }
    // A stray quote injected at random positions of random valid inputs.
    var prng = std.Random.DefaultPrng.init(7);
    for (400..430) |seed| {
        const input = try genCsv(alloc, seed, 120);
        defer alloc.free(input);
        if (input.len == 0) continue;
        input[prng.random().uintLessThan(usize, input.len)] = '"';
        const want = serialErr(input);
        for ([_]usize{ 2, 3, 5, 8, 16 }) |n| try testing.expectEqual(want, parallelErr(threaded.io(), input, n));
    }
}

test "parallel: worker-count errors are real errors" {
    var c = Collector{};
    var ptrs = [_]*Collector{ &c, &c };
    var buf: [8]u8 = undefined;
    const one = [_][]u8{&buf};
    try testing.expectError(csv.Error.BadWorkerCount, csv.parallel.forEachField(testing.io, "a\n", .{}, &one, &ptrs, Collector.on));
    try testing.expectError(csv.Error.BadWorkerCount, csv.parallel.forEachField(testing.io, "a\n", .{}, one[0..0], ptrs[0..0], Collector.on));
}
