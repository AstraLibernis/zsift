//! Unit tests for the SIMD parser. Referenced from `csv.zig`'s test block so
//! they run under `zig build test`.

const std = @import("std");
const testing = std.testing;
const simd = @import("simd.zig");
const SimdParser = simd.SimdParser;
const forEachField = simd.forEachField;
const Error = simd.Error;

test "simd: simple record across the rest of a chunk" {
    var scratch: [256]u8 = undefined;
    var p = SimdParser.init("a,b,c\n", &scratch, .{});
    var buf: [8][]const u8 = undefined;
    const rec = (try p.nextRecord(&buf)).?;
    try testing.expectEqual(@as(usize, 3), rec.len);
    try testing.expectEqualStrings("a", rec[0]);
    try testing.expectEqualStrings("b", rec[1]);
    try testing.expectEqualStrings("c", rec[2]);
}

test "simd: quoted field with embedded delimiter and newline" {
    var scratch: [256]u8 = undefined;
    var p = SimdParser.init("\"a,b\",\"c\nd\"\n", &scratch, .{});
    var buf: [8][]const u8 = undefined;
    const rec = (try p.nextRecord(&buf)).?;
    try testing.expectEqual(@as(usize, 2), rec.len);
    try testing.expectEqualStrings("a,b", rec[0]);
    try testing.expectEqualStrings("c\nd", rec[1]);
}

test "simd: escaped quotes collapse" {
    var scratch: [256]u8 = undefined;
    var p = SimdParser.init("\"she said \"\"hi\"\"\",x\n", &scratch, .{});
    var buf: [8][]const u8 = undefined;
    const rec = (try p.nextRecord(&buf)).?;
    try testing.expectEqualStrings("she said \"hi\"", rec[0]);
    try testing.expectEqualStrings("x", rec[1]);
}

test "simd: crlf terminators" {
    var scratch: [256]u8 = undefined;
    var p = SimdParser.init("a,b\r\nc,d\r\n", &scratch, .{});
    var buf: [8][]const u8 = undefined;
    const r1 = (try p.nextRecord(&buf)).?;
    try testing.expectEqualStrings("a", r1[0]);
    try testing.expectEqualStrings("b", r1[1]);
    var buf2: [8][]const u8 = undefined;
    const r2 = (try p.nextRecord(&buf2)).?;
    try testing.expectEqualStrings("c", r2[0]);
    try testing.expectEqualStrings("d", r2[1]);
}

test "simd: field straddling a 64-byte chunk boundary" {
    // Build a row whose second field starts before offset 64 and ends after it.
    const alloc = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(alloc);
    try src.appendSlice(alloc, "x,");
    try src.appendSlice(alloc, "y" ** 80); // long field crosses the boundary
    try src.append(alloc, '\n');

    var scratch: [256]u8 = undefined;
    var p = SimdParser.init(src.items, &scratch, .{});
    var buf: [8][]const u8 = undefined;
    const rec = (try p.nextRecord(&buf)).?;
    try testing.expectEqual(@as(usize, 2), rec.len);
    try testing.expectEqualStrings("x", rec[0]);
    try testing.expectEqual(@as(usize, 80), rec[1].len);
}

test "simd: quoted field straddling a chunk boundary" {
    const alloc = testing.allocator;
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(alloc);
    try src.append(alloc, '"');
    try src.appendSlice(alloc, "z" ** 100); // quoted region crosses boundary (carry)
    try src.appendSlice(alloc, "\",end\n");

    var scratch: [256]u8 = undefined;
    var p = SimdParser.init(src.items, &scratch, .{});
    var buf: [8][]const u8 = undefined;
    const rec = (try p.nextRecord(&buf)).?;
    try testing.expectEqual(@as(usize, 2), rec.len);
    try testing.expectEqual(@as(usize, 100), rec[0].len);
    try testing.expectEqualStrings("end", rec[1]);
}

test "simd: no trailing newline" {
    var scratch: [256]u8 = undefined;
    var p = SimdParser.init("a,b", &scratch, .{});
    var buf: [8][]const u8 = undefined;
    const rec = (try p.nextRecord(&buf)).?;
    try testing.expectEqual(@as(usize, 2), rec.len);
    try testing.expectEqualStrings("b", rec[1]);
}

test "simd: unterminated quote errors" {
    var scratch: [64]u8 = undefined;
    var p = SimdParser.init("\"abc", &scratch, .{});
    try testing.expectError(Error.UnterminatedQuote, p.next());
}

test "simd: forEachField matches nextRecord" {
    const input = "a,\"b,c\",\"d\"\"e\"\r\nf,g\n";
    const Collector = struct {
        buf: [32][]const u8 = undefined,
        lasts: [32]bool = undefined,
        n: usize = 0,
        fn on(self: *@This(), bytes: []const u8, last: bool) void {
            self.buf[self.n] = bytes;
            self.lasts[self.n] = last;
            self.n += 1;
        }
    };
    var col = Collector{};
    var scratch: [256]u8 = undefined;
    try forEachField(input, &scratch, .{}, &col, Collector.on);

    try testing.expectEqual(@as(usize, 5), col.n);
    try testing.expectEqualStrings("a", col.buf[0]);
    try testing.expectEqualStrings("b,c", col.buf[1]);
    try testing.expectEqualStrings("d\"e", col.buf[2]);
    try testing.expect(col.lasts[2]); // end of first record
    try testing.expectEqualStrings("f", col.buf[3]);
    try testing.expectEqualStrings("g", col.buf[4]);
    try testing.expect(col.lasts[4]);
}

test "simd: empty fields" {
    var scratch: [64]u8 = undefined;
    var p = SimdParser.init("a,,c\n", &scratch, .{});
    var buf: [8][]const u8 = undefined;
    const rec = (try p.nextRecord(&buf)).?;
    try testing.expectEqual(@as(usize, 3), rec.len);
    try testing.expectEqualStrings("", rec[1]);
}

test "simd: trailing delimiter yields a final empty field" {
    var scratch: [64]u8 = undefined;
    var p = SimdParser.init("a,b,", &scratch, .{});
    var buf: [8][]const u8 = undefined;
    const rec = (try p.nextRecord(&buf)).?;
    try testing.expectEqual(@as(usize, 3), rec.len);
    try testing.expectEqualStrings("a", rec[0]);
    try testing.expectEqualStrings("b", rec[1]);
    try testing.expectEqualStrings("", rec[2]);
    try testing.expect((try p.nextRecord(&buf)) == null);
}

test "simd: forEachField emits trailing empty field on a final delimiter" {
    const Collector = struct {
        n: usize = 0,
        last_empty_last: bool = false,
        fn on(self: *@This(), bytes: []const u8, last: bool) void {
            self.n += 1;
            if (bytes.len == 0) self.last_empty_last = last;
        }
    };
    var col = Collector{};
    var scratch: [64]u8 = undefined;
    try forEachField("a,", &scratch, .{}, &col, Collector.on);
    try testing.expectEqual(@as(usize, 2), col.n); // "a" then ""
    try testing.expect(col.last_empty_last); // the empty field closes the record
}
