// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Typed struct reader (`core/reader.zig`).

const std = @import("std");
const testing = std.testing;
const csv = @import("../csv.zig");

const Category = enum { alpha, bravo, charlie, delta };
const Row = struct {
    id: i64,
    price: f64,
    flag: bool,
    name: []const u8,
    category: Category,
};

test "positional: fills a mixed struct in column order" {
    const input =
        \\1,9.50,true,alice,alpha
        \\2,0.00,false,bob,delta
        \\
    ;
    var scratch: [64]u8 = undefined;
    var rdr = try csv.reader(Row).init(input, &scratch, .{});

    const r0 = (try rdr.next()).?;
    try testing.expectEqual(@as(i64, 1), r0.id);
    try testing.expectEqual(@as(f64, 9.50), r0.price);
    try testing.expectEqual(true, r0.flag);
    try testing.expectEqualStrings("alice", r0.name);
    try testing.expectEqual(Category.alpha, r0.category);

    const r1 = (try rdr.next()).?;
    try testing.expectEqual(@as(i64, 2), r1.id);
    try testing.expectEqual(Category.delta, r1.category);
    try testing.expect(!r1.flag);

    try testing.expect((try rdr.next()) == null);
}

test "withHeader: maps by name regardless of column order" {
    // Columns deliberately shuffled vs the struct's field order.
    const input =
        \\category,name,id,flag,price
        \\charlie,carol,7,T,1.25
        \\
    ;
    var scratch: [64]u8 = undefined;
    var rdr = try csv.reader(Row).init(input, &scratch, .{});
    try rdr.withHeader();

    const r = (try rdr.next()).?;
    try testing.expectEqual(@as(i64, 7), r.id);
    try testing.expectEqual(@as(f64, 1.25), r.price);
    try testing.expectEqual(true, r.flag);
    try testing.expectEqualStrings("carol", r.name);
    try testing.expectEqual(Category.charlie, r.category);
}

test "withHeader: MissingHeaderColumn when a struct field is absent" {
    const input = "id,price,flag,name\n1,2.0,true,x\n"; // no `category` column
    var scratch: [64]u8 = undefined;
    var rdr = try csv.reader(Row).init(input, &scratch, .{});
    try testing.expectError(csv.ReaderError.MissingHeaderColumn, rdr.withHeader());
}

test "withHeader: EmptyHeader on empty input" {
    var scratch: [8]u8 = undefined;
    var rdr = try csv.reader(Row).init("", &scratch, .{});
    try testing.expectError(csv.ReaderError.EmptyHeader, rdr.withHeader());
}

test "readerWide: tolerates extra trailing columns beyond the struct" {
    const Pair = struct { a: u32, b: u32 };
    // Rows carry 4 columns; the struct names 2. Strict reader(Pair) would error.
    const input =
        \\a,b,extra1,extra2
        \\10,20,99,88
        \\
    ;
    var scratch: [32]u8 = undefined;
    var rdr = try csv.readerWide(Pair, 8).init(input, &scratch, .{});
    try rdr.withHeader();
    const r = (try rdr.next()).?;
    try testing.expectEqual(@as(u32, 10), r.a);
    try testing.expectEqual(@as(u32, 20), r.b);
}

test "strict positional: TooManyFields when a record is wider than the struct" {
    const Pair = struct { a: u32, b: u32 };
    const input = "1,2,3\n"; // 3 columns, struct has 2
    var scratch: [32]u8 = undefined;
    var rdr = try csv.reader(Pair).init(input, &scratch, .{});
    try testing.expectError(csv.Error.TooManyFields, rdr.next());
}

test "optional field: empty cell becomes null, present cell converts" {
    const Opt = struct { id: u32, note: ?[]const u8, score: ?i32 };
    const input =
        \\1,,
        \\2,hi,5
        \\
    ;
    var scratch: [32]u8 = undefined;
    var rdr = try csv.reader(Opt).init(input, &scratch, .{});

    const r0 = (try rdr.next()).?;
    try testing.expectEqual(@as(u32, 1), r0.id);
    try testing.expect(r0.note == null);
    try testing.expect(r0.score == null);

    const r1 = (try rdr.next()).?;
    try testing.expectEqualStrings("hi", r1.note.?);
    try testing.expectEqual(@as(i32, 5), r1.score.?);
}

test "MissingColumn: a short record with a required field errors" {
    const Two = struct { a: u32, b: u32 };
    // Second record has only one column; `b` is required (non-optional).
    var scratch: [32]u8 = undefined;
    var rdr = try csv.readerWide(Two, 4).init("1,2\n3\n", &scratch, .{});
    _ = (try rdr.next()).?; // first row ok
    try testing.expectError(csv.ReaderError.MissingColumn, rdr.next());
}

test "missing optional column at the tail becomes null" {
    const Tail = struct { a: u32, b: ?u32 };
    var scratch: [32]u8 = undefined;
    var rdr = try csv.readerWide(Tail, 4).init("1\n", &scratch, .{});
    const r = (try rdr.next()).?;
    try testing.expectEqual(@as(u32, 1), r.a);
    try testing.expect(r.b == null);
}

test "[]const u8 field borrows the input bytes" {
    const S = struct { word: []const u8 };
    const input = "hello\n";
    var scratch: [16]u8 = undefined;
    var rdr = try csv.reader(S).init(input, &scratch, .{});
    const r = (try rdr.next()).?;
    try testing.expectEqualStrings("hello", r.word);
    // Borrowed: the field slice points straight into `input`, not a copy.
    try testing.expect(r.word.ptr == input.ptr);
}

test "conversion error surfaces from next()" {
    const S = struct { n: u32 };
    var scratch: [16]u8 = undefined;
    var rdr = try csv.reader(S).init("notanumber\n", &scratch, .{});
    try testing.expectError(csv.ConvertError.InvalidInt, rdr.next());
}

// Compile-time rejection (documented, not compiled): a struct field of an unsupported
// type — e.g. `struct { p: *u8 }` — triggers @compileError in `convert.as` naming the
// type and the accepted set. A non-struct T triggers @compileError in `reader`.
