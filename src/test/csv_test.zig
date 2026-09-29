// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Unit tests for the scalar parser, plus the scalar-vs-SIMD differential test.
//! Referenced from `csv.zig`'s test block so they run under `zig build test`.

const std = @import("std");
const testing = std.testing;
const csv = @import("../csv.zig");
const Parser = csv.Parser;
const SimdParser = csv.SimdParser;
const Options = csv.Options;
const Error = csv.Error;

/// Collect a whole document into `[][]const u8` rows for easy assertions.
/// Test-only: allocates.
fn parseAll(
    alloc: std.mem.Allocator,
    input: []const u8,
    opts: Options,
) ![]const []const []const u8 {
    var scratch: [4096]u8 = undefined;
    var p = try Parser.init(input, &scratch, opts);

    var rows: std.ArrayList([]const []const u8) = .empty;
    defer rows.deinit(alloc);

    while (true) {
        var fields: std.ArrayList([]const u8) = .empty;
        defer fields.deinit(alloc);
        const got = try p.next() orelse break;
        var f = got;
        while (true) {
            // Copy bytes so they survive scratch reuse across records.
            try fields.append(alloc, try alloc.dupe(u8, f.bytes));
            if (f.last_in_record) break;
            f = (try p.next()).?;
        }
        try rows.append(alloc, try fields.toOwnedSlice(alloc));
    }
    return rows.toOwnedSlice(alloc);
}

fn expectRows(input: []const u8, expected: []const []const []const u8) !void {
    const alloc = testing.allocator;
    const rows = try parseAll(alloc, input, .{});
    defer {
        for (rows) |row| {
            for (row) |field| alloc.free(field);
            alloc.free(row);
        }
        alloc.free(rows);
    }
    try testing.expectEqual(expected.len, rows.len);
    for (expected, rows) |erow, grow| {
        try testing.expectEqual(erow.len, grow.len);
        for (erow, grow) |ef, gf| try testing.expectEqualStrings(ef, gf);
    }
}

test "simple rows" {
    try expectRows("a,b,c\n1,2,3\n", &.{
        &.{ "a", "b", "c" },
        &.{ "1", "2", "3" },
    });
}

test "no trailing newline" {
    try expectRows("a,b\n1,2", &.{
        &.{ "a", "b" },
        &.{ "1", "2" },
    });
}

test "empty fields" {
    try expectRows("a,,c\n,,\n", &.{
        &.{ "a", "", "c" },
        &.{ "", "", "" },
    });
}

test "trailing delimiter yields a final empty field (regression: was a crash)" {
    try expectRows("a,", &.{&.{ "a", "" }});
    try expectRows("a,b,", &.{&.{ "a", "b", "" }});
    try expectRows("\"x\",", &.{&.{ "x", "" }});
    try expectRows("a,\nb,", &.{ &.{ "a", "" }, &.{ "b", "" } });
}

test "nextRecord does not crash on a trailing delimiter at EOF" {
    var scratch: [64]u8 = undefined;
    var p = try Parser.init("a,", &scratch, .{});
    var buf: [8][]const u8 = undefined;
    const rec = (try p.nextRecord(&buf)).?;
    try testing.expectEqual(@as(usize, 2), rec.len);
    try testing.expectEqualStrings("a", rec[0]);
    try testing.expectEqualStrings("", rec[1]);
    try testing.expect((try p.nextRecord(&buf)) == null);
}

test "crlf terminators" {
    try expectRows("a,b\r\nc,d\r\n", &.{
        &.{ "a", "b" },
        &.{ "c", "d" },
    });
}

test "blank line is a single empty field" {
    try expectRows("a\n\nb\n", &.{
        &.{"a"},
        &.{""},
        &.{"b"},
    });
}

test "quoted fields keep delimiter and newline" {
    try expectRows("\"a,b\",\"c\nd\"\n", &.{
        &.{ "a,b", "c\nd" },
    });
}

test "escaped quotes collapse" {
    try expectRows("\"she said \"\"hi\"\"\",x\n", &.{
        &.{ "she said \"hi\"", "x" },
    });
}

test "quote only opens a field at the start" {
    // The quote mid-field is literal data, not a quoted field.
    try expectRows("3\" pipe,ok\n", &.{
        &.{ "3\" pipe", "ok" },
    });
}

test "empty quoted field" {
    try expectRows("\"\",\"\"\n", &.{
        &.{ "", "" },
    });
}

test "unterminated quote errors" {
    var scratch: [64]u8 = undefined;
    var p = try Parser.init("\"abc", &scratch, .{});
    try testing.expectError(Error.UnterminatedQuote, p.next());
}

test "char after closing quote errors" {
    var scratch: [64]u8 = undefined;
    var p = try Parser.init("\"ab\"c\n", &scratch, .{});
    try testing.expectError(Error.InvalidQuote, p.next());
}

test "scratch too small errors only when unescaping" {
    var scratch: [1]u8 = undefined;
    var p = try Parser.init("\"a\"\"b\"\n", &scratch, .{}); // collapses to `a"b` (3 bytes)
    try testing.expectError(Error.ScratchTooSmall, p.next());
}

test "custom delimiter" {
    var scratch: [64]u8 = undefined;
    var p = try Parser.init("a;b;c\n", &scratch, .{ .delimiter = ';' });
    var buf: [8][]const u8 = undefined;
    const rec = (try p.nextRecord(&buf)).?;
    try testing.expectEqual(@as(usize, 3), rec.len);
    try testing.expectEqualStrings("a", rec[0]);
    try testing.expectEqualStrings("c", rec[2]);
}

test "nextRecord too many fields" {
    var scratch: [64]u8 = undefined;
    var p = try Parser.init("a,b,c\n", &scratch, .{});
    var buf: [2][]const u8 = undefined;
    try testing.expectError(Error.TooManyFields, p.nextRecord(&buf));
}

test "nextRecord keeps multiple unescaped fields alive together" {
    var scratch: [64]u8 = undefined;
    var p = try Parser.init("\"a\"\"a\",\"b\"\"b\"\n", &scratch, .{});
    var buf: [4][]const u8 = undefined;
    const rec = (try p.nextRecord(&buf)).?;
    try testing.expectEqual(@as(usize, 2), rec.len);
    try testing.expectEqualStrings("a\"a", rec[0]);
    try testing.expectEqualStrings("b\"b", rec[1]);
}

// The scalar and SIMD parsers must agree byte-for-byte on every field of
// well-formed RFC 4180 input. This walks a generated corpus through both and
// compares the full field stream.
test "differential: scalar vs simd agree on a generated corpus" {
    const alloc = testing.allocator;

    // A well-formed corpus: every quote is a proper field quote (no bare quotes
    // in unquoted fields, where the two parsers are deliberately allowed to
    // differ). Mixes plain fields, quoted fields with embedded separators and
    // newlines, escaped quotes, CRLF rows, and chunk-boundary-length fields.
    var corpus: std.ArrayList(u8) = .empty;
    defer corpus.deinit(alloc);
    var prng = std.Random.DefaultPrng.init(0xD1FF_C5_7A);
    const r = prng.random();
    const cells = [_][]const u8{
        "plain",      "with space",                                                                 "",
        "\"a,b\"",    "\"line\nbrk\"",                                                              "\"q\"\"q\"",
        "1234567890", "yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy", "\"crlf\r\n2\"",
    };
    var rows: usize = 0;
    while (rows < 400) : (rows += 1) {
        const ncols = 1 + r.uintLessThan(usize, 6);
        var c: usize = 0;
        while (c < ncols) : (c += 1) {
            if (c != 0) try corpus.append(alloc, ',');
            try corpus.appendSlice(alloc, cells[r.uintLessThan(usize, cells.len)]);
        }
        try corpus.appendSlice(alloc, if (r.boolean()) "\r\n" else "\n");
    }

    var scratch_a: [4096]u8 = undefined;
    var scratch_b: [4096]u8 = undefined;
    var sp = try Parser.init(corpus.items, &scratch_a, .{});
    var vp = try SimdParser.init(corpus.items, &scratch_b, .{});

    var count: usize = 0;
    while (true) {
        const a = try sp.next();
        const b = try vp.next();
        if (a == null and b == null) break;
        try testing.expect(a != null and b != null);
        try testing.expectEqual(a.?.last_in_record, b.?.last_in_record);
        try testing.expectEqualStrings(a.?.bytes, b.?.bytes);
        // Reset both scratches in lockstep so unescaped fields stay valid.
        if (a.?.last_in_record) {
            sp.resetScratch();
            vp.resetScratch();
        }
        count += 1;
    }
    try testing.expect(count > 400); // sanity: we actually parsed fields
}
