// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Header (name→column) view, exercised over a real SimdParser record.

const std = @import("std");
const testing = std.testing;
const csv = @import("../csv.zig");
const Header = csv.Header;
const Record = csv.Record;

test "index / col / len over a parsed header row" {
    const input = "id,name,age\n1,alice,30\n";
    var scratch: [64]u8 = undefined;
    var p = try csv.SimdParser.init(input, &scratch, .{});

    // Capture the header into its own storage so the shared `row` buffer can be reused
    // for data rows without clobbering the names (see `Header` lifetime note).
    var row: [8][]const u8 = undefined;
    var hslots: [8][]const u8 = undefined;
    const h = Header.capture((try p.nextRecord(&row)).?, &hslots);

    try testing.expectEqual(@as(usize, 3), h.len());
    try testing.expectEqual(@as(?usize, 0), h.index("id"));
    try testing.expectEqual(@as(?usize, 2), h.index("age"));
    try testing.expectEqual(@as(?usize, null), h.index("missing"));

    const data = (try p.nextRecord(&row)).?;
    try testing.expectEqualStrings("alice", h.col(data, "name").?.bytes);
    try testing.expectEqual(@as(u8, 30), try h.col(data, "age").?.as(u8));
    try testing.expect(h.col(data, "nope") == null);
}

test "col returns null when the record is shorter than the column index" {
    const input = "a,b,c\nx\n";
    var scratch: [32]u8 = undefined;
    var p = try csv.SimdParser.init(input, &scratch, .{});
    var row: [8][]const u8 = undefined;
    var hslots: [8][]const u8 = undefined;
    const h = Header.capture((try p.nextRecord(&row)).?, &hslots);
    const short = (try p.nextRecord(&row)).?; // only one field
    try testing.expectEqualStrings("x", h.col(short, "a").?.bytes);
    try testing.expect(h.col(short, "c") == null); // index 2, record has 1 field
}

test "init: a direct (uncaptured) view is valid until the next read" {
    // Header.init borrows the record in place — fine as long as the buffer is not reused.
    const input = "one,two,three\n";
    var scratch: [32]u8 = undefined;
    var p = try csv.SimdParser.init(input, &scratch, .{});
    var row: [8][]const u8 = undefined;
    const h = Header.init((try p.nextRecord(&row)).?);
    try testing.expectEqual(@as(?usize, 1), h.index("two"));
    try testing.expect(p.next() catch null == null); // no more records; `row` never reused
}

test "capture: header survives later nextRecord calls" {
    const input = "k1,k2\nv1,v2\nw1,w2\n";
    var scratch: [32]u8 = undefined;
    var p = try csv.SimdParser.init(input, &scratch, .{});

    var row: [8][]const u8 = undefined;
    var slots: [8][]const u8 = undefined;
    const h = Header.capture((try p.nextRecord(&row)).?, &slots);

    // Two more reads reuse `row`; the captured header must still be intact.
    _ = (try p.nextRecord(&row)).?;
    _ = (try p.nextRecord(&row)).?;
    try testing.expectEqual(@as(usize, 2), h.len());
    try testing.expectEqualStrings("k1", h.names[0]);
    try testing.expectEqualStrings("k2", h.names[1]);
    try testing.expectEqual(@as(?usize, 1), h.index("k2"));
}

test "Record: positional at / count / as" {
    const input = "10,hello,3.5\n";
    var scratch: [32]u8 = undefined;
    var p = try csv.SimdParser.init(input, &scratch, .{});
    var row: [8][]const u8 = undefined;
    const rec = Record.init((try p.nextRecord(&row)).?);

    try testing.expectEqual(@as(usize, 3), rec.count());
    try testing.expectEqualStrings("hello", rec.at(1).bytes);
    try testing.expect(rec.at(2).last_in_record);
    try testing.expect(!rec.at(0).last_in_record);
    try testing.expectEqual(@as(u32, 10), try rec.as(0, u32));
    try testing.expectEqual(@as(f64, 3.5), try rec.as(2, f64));
}

test "Record: get by name with an attached header, null without" {
    const input = "id,name\n42,zed\n";
    var scratch: [32]u8 = undefined;
    var p = try csv.SimdParser.init(input, &scratch, .{});
    var row: [8][]const u8 = undefined;
    var slots: [8][]const u8 = undefined;
    const h = Header.capture((try p.nextRecord(&row)).?, &slots);

    const data = (try p.nextRecord(&row)).?;
    const with = Record.withHeader(data, &h);
    try testing.expectEqualStrings("zed", with.get("name").?.bytes);
    try testing.expectEqual(@as(u32, 42), try with.get("id").?.as(u32));
    try testing.expect(with.get("nope") == null);

    // Without a header, get() always yields null.
    const without = Record.init(data);
    try testing.expect(without.get("name") == null);
}
