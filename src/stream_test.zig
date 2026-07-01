//! Tests for the streaming parser and the auto-selecting facade. Referenced from
//! `csv.zig`'s test block so they run under `zig build test`.

const std = @import("std");
const testing = std.testing;
const csv = @import("csv.zig");
const simd = @import("simd.zig");
const stream = @import("stream.zig");

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

// ---------------------------------------------------------------------------
// A reader that serves an in-memory slice a few bytes at a time, forcing the
// streaming parser through real refills, rebases, and record straddles.
// ---------------------------------------------------------------------------
const ChunkedReader = struct {
    interface: Reader,
    data: []const u8,
    pos: usize,
    chunk: usize,

    fn init(buffer: []u8, data: []const u8, chunk: usize) ChunkedReader {
        return .{
            .interface = .{
                .vtable = &.{
                    .stream = streamFn,
                    .discard = Reader.defaultDiscard,
                    .readVec = Reader.defaultReadVec,
                    .rebase = Reader.defaultRebase,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .data = data,
            .pos = 0,
            .chunk = chunk,
        };
    }

    fn streamFn(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const self: *ChunkedReader = @alignCast(@fieldParentPtr("interface", r));
        if (self.pos >= self.data.len) return error.EndOfStream;
        const remaining = self.data[self.pos..];
        const take = @min(self.chunk, limit.minInt(remaining.len));
        const n = try w.write(remaining[0..take]);
        self.pos += n;
        return n;
    }
};

// Records each field as bytes followed by '|', and ends each record with '\n',
// giving a canonical string we can compare across parsing strategies. No
// allocation, so it is safe to call from a parser callback.
const Collector = struct {
    buf: [16 * 1024]u8 = undefined,
    len: usize = 0,
    fn on(self: *Collector, bytes: []const u8, last: bool) void {
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
        self.buf[self.len] = if (last) '\n' else '|';
        self.len += 1;
    }
    fn slice(self: *const Collector) []const u8 {
        return self.buf[0..self.len];
    }
};

fn canonInMemory(data: []const u8) !Collector {
    var c = Collector{};
    var scratch: [4096]u8 = undefined;
    try simd.forEachField(data, &scratch, .{}, &c, Collector.on);
    return c;
}

// ---------------------------------------------------------------------------
// completeRecordsLen
// ---------------------------------------------------------------------------

test "completeRecordsLen: basic and partial" {
    try testing.expectEqual(@as(usize, 4), stream.completeRecordsLen("a,b\n", .{}));
    try testing.expectEqual(@as(usize, 4), stream.completeRecordsLen("a,b\nc,d", .{})); // 2nd partial
    try testing.expectEqual(@as(usize, 0), stream.completeRecordsLen("a,b", .{})); // no terminator
    try testing.expectEqual(@as(usize, 0), stream.completeRecordsLen("", .{}));
}

test "completeRecordsLen: crlf and split crlf" {
    try testing.expectEqual(@as(usize, 5), stream.completeRecordsLen("a,b\r\nc", .{}));
    try testing.expectEqual(@as(usize, 0), stream.completeRecordsLen("a,b\r", .{})); // trailing CR deferred
}

test "completeRecordsLen: terminators inside quotes are ignored" {
    try testing.expectEqual(@as(usize, 6), stream.completeRecordsLen("\"x\ny\"\n", .{})); // embedded newline
    try testing.expectEqual(@as(usize, 7), stream.completeRecordsLen("\"x\"\"y\"\n", .{})); // escaped quotes ("x""y"\n = 7 bytes)
    try testing.expectEqual(@as(usize, 0), stream.completeRecordsLen("\"x,y", .{})); // open quote, no close
}

// ---------------------------------------------------------------------------
// streamReader
// ---------------------------------------------------------------------------

const sample =
    "a,b,c\n" ++
    "\"x,y\",\"z\"\"z\",ok\r\n" ++
    "embedded,\"line\nbreak\",end\n" ++
    "trailing,no,newline";

test "stream: fixed reader matches in-memory" {
    const want = try canonInMemory(sample);
    var buf: [4096]u8 = undefined;
    @memcpy(buf[0..sample.len], sample);
    var r = Reader.fixed(buf[0..sample.len]);
    var got = Collector{};
    var scratch: [4096]u8 = undefined;
    try csv.streamReader(&r, &scratch, .{}, &got, Collector.on);
    try testing.expectEqualStrings(want.slice(), got.slice());
}

test "stream: CR at exact window edge (CRLF and lone CR) matches in-memory" {
    // Regression: a record + trailing `\r` that exactly fills the window used to
    // trip a spurious RecordTooLong, because `completeRecordsLen` defers a `\r` at
    // the window end. Both a split CRLF and a lone CR (Mac) must parse correctly.
    // The record (15 bytes) plus its trailing `\r` exactly fill the 16-byte
    // window; the `\r` is inside the window, so it is a valid complete record
    // (unlike a 16-byte record whose terminator would fall outside — that is the
    // documented RecordTooLong case and is intentionally excluded here).
    const cases = [_][]const u8{
        "aaaaaaaaaaaaaaa\r\nbbb\n", // 15 chars + CR fills the window; LF is next
        "aaaaaaaaaaaaaaa\rbbb", // lone CR at the window edge, more data after
        "aaaaaaaaaaaaaaa\r\nbbb", // split CRLF, no trailing newline
        "aaaaaaaaaaaaaaa\r", // CR at window edge is the last byte of input
    };
    for (cases) |data| {
        const want = try canonInMemory(data);
        var window: [16]u8 = undefined;
        var cr = ChunkedReader.init(&window, data, 4);
        var got = Collector{};
        var scratch: [4096]u8 = undefined;
        try csv.streamReader(&cr.interface, &scratch, .{}, &got, Collector.on);
        try testing.expectEqualStrings(want.slice(), got.slice());
    }
}

test "stream: chunked reader (real refills) matches in-memory" {
    const want = try canonInMemory(sample);
    // Window larger than the longest record, but data delivered 3 bytes at a
    // time so records straddle refills and rebases happen repeatedly.
    var window: [64]u8 = undefined;
    var cr = ChunkedReader.init(&window, sample, 3);
    var got = Collector{};
    var scratch: [4096]u8 = undefined;
    try csv.streamReader(&cr.interface, &scratch, .{}, &got, Collector.on);
    try testing.expectEqualStrings(want.slice(), got.slice());
}

test "stream: many tiny chunks, varied window sizes" {
    const want = try canonInMemory(sample);
    for ([_]usize{ 32, 48, 64, 128 }) |wlen| {
        var window: [128]u8 = undefined;
        var cr = ChunkedReader.init(window[0..wlen], sample, 1); // one byte per read
        var got = Collector{};
        var scratch: [4096]u8 = undefined;
        try csv.streamReader(&cr.interface, &scratch, .{}, &got, Collector.on);
        try testing.expectEqualStrings(want.slice(), got.slice());
    }
}

test "stream: record longer than the window errors" {
    const data = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"; // 30 + newline
    var window: [16]u8 = undefined;
    var cr = ChunkedReader.init(&window, data, 8);
    var got = Collector{};
    var scratch: [64]u8 = undefined;
    try testing.expectError(
        csv.stream.StreamError.RecordTooLong,
        csv.streamReader(&cr.interface, &scratch, .{}, &got, Collector.on),
    );
}

test "stream: final record that exactly fills the window is accepted (regression B3)" {
    const data = "aaaaaaaaaaaaaaaa"; // 16 bytes, no trailing newline
    var window: [16]u8 = undefined; // record length == window length
    var cr = ChunkedReader.init(&window, data, 8);
    var got = Collector{};
    var scratch: [64]u8 = undefined;
    try csv.streamReader(&cr.interface, &scratch, .{}, &got, Collector.on);
    try testing.expectEqualStrings("aaaaaaaaaaaaaaaa\n", got.slice());
}

// ---------------------------------------------------------------------------
// Auto-selecting facade
// ---------------------------------------------------------------------------

test "decide: by size hint" {
    try testing.expectEqual(csv.Strategy.in_memory, csv.stream.decide(100, 1000));
    try testing.expectEqual(csv.Strategy.streaming, csv.stream.decide(5000, 1000));
    try testing.expectEqual(csv.Strategy.streaming, csv.stream.decide(null, 1000)); // unknown size
}

test "parseReader: both strategies produce identical output" {
    const want = try canonInMemory(sample);
    const gpa = testing.allocator;

    // in_memory: tiny threshold above the input size.
    {
        var buf: [4096]u8 = undefined;
        @memcpy(buf[0..sample.len], sample);
        var r = Reader.fixed(buf[0..sample.len]);
        var got = Collector{};
        const strat = try csv.parseReader(gpa, &r, sample.len, .{ .in_memory_threshold = 1 << 20 }, &got, Collector.on);
        try testing.expectEqual(csv.Strategy.in_memory, strat);
        try testing.expectEqualStrings(want.slice(), got.slice());
    }

    // streaming: threshold below the input size forces the streaming path.
    {
        var window: [128]u8 = undefined;
        var cr = ChunkedReader.init(&window, sample, 5);
        var got = Collector{};
        const strat = try csv.parseReader(gpa, &cr.interface, sample.len, .{ .in_memory_threshold = 8 }, &got, Collector.on);
        try testing.expectEqual(csv.Strategy.streaming, strat);
        try testing.expectEqualStrings(want.slice(), got.slice());
    }
}
