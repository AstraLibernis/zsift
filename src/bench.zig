//! Throughput benchmark for the zcsv parser.
//!
//! Generates a deterministic corpus for several "profiles" (clean data, quoted
//! data, escape-heavy data), parses each many times, and reports MB/s and
//! rows/s. Timing uses the monotonic clock directly — `std.time.Timer` was
//! removed in Zig 0.16, and the new `Io` clock interface is overkill for a
//! pure-CPU microbenchmark.

const std = @import("std");
const csv = @import("csv");

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

/// In-memory reader with a bounded window, serving the corpus through real
/// refills/rebases — so the streaming number reflects genuine streaming cost,
/// not a single in-memory pass.
const MemReader = struct {
    interface: Reader,
    data: []const u8,
    pos: usize,

    fn init(window: []u8, data: []const u8) MemReader {
        return .{
            .interface = .{
                .vtable = &.{
                    .stream = streamFn,
                    .discard = Reader.defaultDiscard,
                    .readVec = Reader.defaultReadVec,
                    .rebase = Reader.defaultRebase,
                },
                .buffer = window,
                .seek = 0,
                .end = 0,
            },
            .data = data,
            .pos = 0,
        };
    }

    fn streamFn(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const self: *MemReader = @alignCast(@fieldParentPtr("interface", r));
        if (self.pos >= self.data.len) return error.EndOfStream;
        const n = try w.write(limit.sliceConst(self.data[self.pos..]));
        self.pos += n;
        return n;
    }
};

/// Monotonic nanoseconds. Linux-only by design (this is a benchmark, and all
/// numbers are machine-specific anyway). Isolated here so it is easy to swap.
fn nanoTime() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

const Profile = struct {
    name: []const u8,
    /// 0..100 chance a given field is quoted.
    quote_pct: u8,
    /// 0..100 chance a quoted field carries an escaped quote (`""`).
    escape_pct: u8,
};

const profiles = [_]Profile{
    .{ .name = "clean   ", .quote_pct = 0, .escape_pct = 0 },
    .{ .name = "quoted  ", .quote_pct = 30, .escape_pct = 0 },
    .{ .name = "escapey ", .quote_pct = 60, .escape_pct = 50 },
};

const cols = 8;
const target_bytes = 16 * 1024 * 1024;

/// Build ~`target_bytes` of CSV for the given profile. Deterministic per seed.
fn generate(alloc: std.mem.Allocator, prof: Profile) ![]u8 {
    var prng = std.Random.DefaultPrng.init(0xC5_7A_BE_11);
    const r = prng.random();

    const words = [_][]const u8{
        "alpha",  "bravo", "charlie", "delta", "echo",  "foxtrot",
        "golf",   "hotel", "india",   "juliet", "kilo", "lima",
        "1234",   "56.78", "true",    "",      "n/a",   "x",
    };

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, target_bytes + 4096);

    while (out.items.len < target_bytes) {
        var c: usize = 0;
        while (c < cols) : (c += 1) {
            if (c != 0) try out.append(alloc, ',');
            const w = words[r.uintLessThan(usize, words.len)];
            const quoted = r.uintLessThan(u8, 100) < prof.quote_pct;
            if (quoted) {
                try out.append(alloc, '"');
                try out.appendSlice(alloc, w);
                // Sometimes embed a delimiter/newline that *requires* quoting.
                if (r.boolean()) try out.appendSlice(alloc, ",more");
                if (r.uintLessThan(u8, 100) < prof.escape_pct) {
                    try out.appendSlice(alloc, "\"\"q\"\""); // escaped quotes
                }
                try out.append(alloc, '"');
            } else {
                try out.appendSlice(alloc, w);
            }
        }
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

/// Parse the whole corpus once with parser type `P` (scalar or SIMD — they share
/// the same method surface). Returns a checksum (sum of field lengths) so the
/// optimizer cannot delete the work, plus the record count.
fn parseOnce(comptime P: type, input: []const u8, scratch: []u8) struct { checksum: u64, rows: u64 } {
    var p = P.init(input, scratch, .{});
    var checksum: u64 = 0;
    var rows: u64 = 0;
    while (p.next() catch null) |first| {
        p.resetScratch();
        var f = first;
        while (true) {
            checksum +%= f.bytes.len;
            if (f.last_in_record) break;
            f = (p.next() catch null) orelse break;
        }
        rows += 1;
    }
    return .{ .checksum = checksum, .rows = rows };
}

/// Sink for the callback API: sums field lengths so the work survives the
/// optimizer.
const Sink = struct {
    sum: u64 = 0,
    fn onField(self: *Sink, bytes: []const u8, last: bool) void {
        self.sum +%= bytes.len;
        _ = last;
    }
};

/// Best-of-`runs` MB/s for the inlined callback fast path over `corpus`.
fn measureCallback(corpus: []const u8, scratch: []u8, runs: usize) f64 {
    var best_ns: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        var sink = Sink{};
        const t0 = nanoTime();
        csv.simd.forEachField(corpus, scratch, .{}, &sink, Sink.onField) catch |e|
            std.debug.panic("forEachField failed on well-formed corpus: {s}", .{@errorName(e)});
        const dt = nanoTime() - t0;
        std.mem.doNotOptimizeAway(sink.sum);
        if (dt < best_ns) best_ns = dt;
    }
    const secs = @as(f64, @floatFromInt(best_ns)) / 1e9;
    const mb = @as(f64, @floatFromInt(corpus.len)) / (1024.0 * 1024.0);
    return mb / secs;
}

/// Best-of-`runs` MB/s for the streaming path: parse `corpus` through a bounded
/// window (real refills), pushing fields to the callback.
fn measureStream(corpus: []const u8, window: []u8, scratch: []u8, runs: usize) f64 {
    var best_ns: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        var sink = Sink{};
        var mr = MemReader.init(window, corpus);
        const t0 = nanoTime();
        csv.streamReader(&mr.interface, scratch, .{}, &sink, Sink.onField) catch |e|
            std.debug.panic("streamReader failed on well-formed corpus: {s}", .{@errorName(e)});
        const dt = nanoTime() - t0;
        std.mem.doNotOptimizeAway(sink.sum);
        if (dt < best_ns) best_ns = dt;
    }
    const secs = @as(f64, @floatFromInt(best_ns)) / 1e9;
    const mb = @as(f64, @floatFromInt(corpus.len)) / (1024.0 * 1024.0);
    return mb / secs;
}

/// Best-of-`runs` MB/s for parser `P` over `corpus`.
fn measure(comptime P: type, corpus: []const u8, scratch: []u8, runs: usize) f64 {
    const warm = parseOnce(P, corpus, scratch);
    std.mem.doNotOptimizeAway(warm.checksum);
    var best_ns: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        const t0 = nanoTime();
        const res = parseOnce(P, corpus, scratch);
        const dt = nanoTime() - t0;
        std.mem.doNotOptimizeAway(res.checksum);
        if (dt < best_ns) best_ns = dt;
    }
    const secs = @as(f64, @floatFromInt(best_ns)) / 1e9;
    const mb = @as(f64, @floatFromInt(corpus.len)) / (1024.0 * 1024.0);
    return mb / secs;
}

const stream_window = 64 * 1024;

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var scratch: [64 * 1024]u8 = undefined;
    var window: [stream_window]u8 = undefined;
    var stream_scratch: [stream_window]u8 = undefined;

    const print = std.debug.print;
    print("zcsv benchmark — corpus ~{d} MiB/profile, {d} cols, best of {d} ({d} KiB stream window)\n", .{ target_bytes >> 20, cols, iters, stream_window >> 10 });
    print("{s:<9} {s:>10} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{ "profile", "rows", "scalar", "simd pull", "simd push", "stream", "scan ceil" });
    print("{s:<9} {s:>10} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{ "", "", "MB/s", "MB/s", "MB/s", "MB/s", "MB/s" });

    for (profiles) |prof| {
        const corpus = try generate(alloc, prof);
        defer alloc.free(corpus);

        const rows = parseOnce(csv.Parser, corpus, &scratch).rows;
        const scalar = measure(csv.Parser, corpus, &scratch, iters);
        const pull = measure(csv.SimdParser, corpus, &scratch, iters);
        const push = measureCallback(corpus, &scratch, iters);
        const strm = measureStream(corpus, &window, &stream_scratch, iters);

        // Structural-scan ceiling (no per-field work).
        var best_ns: u64 = std.math.maxInt(u64);
        var i: usize = 0;
        while (i < iters) : (i += 1) {
            const t0 = nanoTime();
            const seps = csv.simd.countSeparators(corpus, .{});
            const dt = nanoTime() - t0;
            std.mem.doNotOptimizeAway(seps);
            if (dt < best_ns) best_ns = dt;
        }
        const ceil_mbps = (@as(f64, @floatFromInt(corpus.len)) / (1024.0 * 1024.0)) /
            (@as(f64, @floatFromInt(best_ns)) / 1e9);

        print("{s} {d:>10} {d:>9.1} {d:>10.1} {d:>10.1} {d:>10.1} {d:>10.1}\n", .{
            prof.name, rows, scalar, pull, push, strm, ceil_mbps,
        });
    }
}

const iters = 7;
