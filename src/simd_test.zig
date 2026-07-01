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

test "simd: differential fuzz — push and pull match generated fields" {
    // Generate random well-formed RFC-4180 CSV together with the exact field
    // values it encodes, then assert both the push (`forEachField`) and pull
    // (`SimdParser`) paths reproduce them. Fields range up to 129 bytes, so many
    // straddle a 64-byte chunk — exercising both the popcount fast path and the
    // `indexOfScalar` straddle fallback in `interiorQuote`. This is the guard
    // against the mask-based escape detection ever diverging from a byte re-scan.
    const alloc = testing.allocator;
    var seed: u64 = 0;
    while (seed < 400) : (seed += 1) {
        var prng = std.Random.DefaultPrng.init(seed);
        const rnd = prng.random();

        var csv: std.ArrayList(u8) = .empty;
        defer csv.deinit(alloc);
        var expected: std.ArrayList([]const u8) = .empty;
        defer {
            for (expected.items) |e| alloc.free(e);
            expected.deinit(alloc);
        }
        var lasts: std.ArrayList(bool) = .empty;
        defer lasts.deinit(alloc);

        const nrec = 1 + rnd.uintLessThan(usize, 12);
        var rec: usize = 0;
        while (rec < nrec) : (rec += 1) {
            const nfield = 1 + rnd.uintLessThan(usize, 5);
            var f: usize = 0;
            while (f < nfield) : (f += 1) {
                if (f != 0) try csv.append(alloc, ',');

                var val: std.ArrayList(u8) = .empty;
                defer val.deinit(alloc);
                const vlen = rnd.uintLessThan(usize, 130); // 0..129 → crosses 64B
                var k: usize = 0;
                while (k < vlen) : (k += 1) {
                    const c: u8 = switch (rnd.uintLessThan(u8, 20)) {
                        0 => ',', // forces quoting
                        1 => '"', // forces quoting + an escaped pair
                        2 => '\n', // forces quoting (embedded newline)
                        else => 'a' + rnd.uintLessThan(u8, 26),
                    };
                    try val.append(alloc, c);
                }
                const must_quote = std.mem.indexOfAny(u8, val.items, ",\"\n") != null;
                if (must_quote or rnd.boolean()) {
                    try csv.append(alloc, '"');
                    for (val.items) |c| {
                        if (c == '"') try csv.append(alloc, '"'); // RFC escape: double it
                        try csv.append(alloc, c);
                    }
                    try csv.append(alloc, '"');
                } else {
                    try csv.appendSlice(alloc, val.items);
                }
                try expected.append(alloc, try alloc.dupe(u8, val.items));
                try lasts.append(alloc, f == nfield - 1);
            }
            try csv.append(alloc, '\n');
        }

        // Scratch must hold the largest field; the whole input is a safe bound.
        const scratch = try alloc.alloc(u8, csv.items.len + 64);
        defer alloc.free(scratch);

        // Push path.
        const Collector = struct {
            exp: [][]const u8,
            lst: []bool,
            i: usize = 0,
            fn on(self: *@This(), bytes: []const u8, last: bool) void {
                std.debug.assert(self.i < self.exp.len);
                std.debug.assert(std.mem.eql(u8, bytes, self.exp[self.i]));
                std.debug.assert(last == self.lst[self.i]);
                self.i += 1;
            }
        };
        var col = Collector{ .exp = expected.items, .lst = lasts.items };
        try forEachField(csv.items, scratch, .{}, &col, Collector.on);
        try testing.expectEqual(expected.items.len, col.i);

        // Pull path.
        var p = SimdParser.init(csv.items, scratch, .{});
        var idx: usize = 0;
        while (try p.next()) |field| : (idx += 1) {
            try testing.expect(idx < expected.items.len);
            try testing.expectEqualStrings(expected.items[idx], field.bytes);
            try testing.expectEqual(lasts.items[idx], field.last_in_record);
        }
        try testing.expectEqual(expected.items.len, idx);
    }
}
