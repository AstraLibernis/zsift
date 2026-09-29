// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Throughput benchmark for the zsift parser.
//!
//! Generates a deterministic corpus for several "profiles" (clean data, quoted
//! data, escape-heavy data), parses each many times, and reports MB/s and
//! rows/s. Timing uses the monotonic clock directly — `std.time.Timer` was
//! removed in Zig 0.16, and the new `Io` clock interface is overkill for a
//! pure-CPU microbenchmark.

const std = @import("std");
const csv = @import("csv");
const methods = @import("methods.zig");
const experiment = @import("experiment.zig");
const compare = @import("compare.zig");
const sweep = @import("sweep.zig");
const gen = @import("gen.zig");
const verify = @import("verify.zig");

const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

const MemReader = @import("memreader.zig").MemReader;

/// Monotonic nanoseconds. Linux-only by design (this is a benchmark, and all
/// numbers are machine-specific anyway). Isolated here so it is easy to swap.
fn nanoTime() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Shared typed-row schema for the honest end-to-end benchmark: `csv.reader(TypedRow)`
/// vs rust-csv's serde `deserialize::<Row>()` (see rustcsv/src/main.rs `serde` mode),
/// both parsing the same header'd `typed.csv` into a struct. Columns must match the
/// generated header `id,price,flag,name,category` (see gen.zig `typed_header`).
const Category = enum { alpha, bravo, charlie, delta };
const TypedRow = struct {
    id: i64,
    price: f64,
    flag: bool,
    name: []const u8,
    category: Category,
};

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
        "alpha", "bravo", "charlie", "delta",  "echo", "foxtrot",
        "golf",  "hotel", "india",   "juliet", "kilo", "lima",
        "1234",  "56.78", "true",    "",       "n/a",  "x",
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
    var p = P.init(input, scratch, .{}) catch |e| std.debug.panic("bench: {s}", .{@errorName(e)});
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

/// Best-of-`runs` MB/s for the batched pull API (`SimdParser.nextInto`), reading a
/// bounded batch of fields per call and resetting scratch per batch.
fn measurePullBatch(corpus: []const u8, scratch: []u8, runs: usize) f64 {
    var best_ns: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        var p = csv.SimdParser.init(corpus, scratch, .{}) catch |e| std.debug.panic("bench: {s}", .{@errorName(e)});
        var fbuf: [64]csv.Field = undefined;
        var sum: u64 = 0;
        const t0 = nanoTime();
        while (true) {
            const got = p.nextInto(&fbuf) catch |e|
                std.debug.panic("nextInto failed on well-formed corpus: {s}", .{@errorName(e)});
            if (got == 0) break;
            for (fbuf[0..got]) |f| sum +%= f.bytes.len;
            p.resetScratch(); // keep scratch batch-local
        }
        const dt = nanoTime() - t0;
        std.mem.doNotOptimizeAway(sum);
        if (dt < best_ns) best_ns = dt;
    }
    const secs = @as(f64, @floatFromInt(best_ns)) / 1e9;
    const mb = @as(f64, @floatFromInt(corpus.len)) / (1024.0 * 1024.0);
    return mb / secs;
}

/// Best-of-`runs` MB/s for the typed path: `csv.reader(TypedRow)` deserializing every
/// record into a struct (the same task rust-csv's serde mode does). `corpus` MUST carry
/// the `id,price,flag,name,category` header row (use `bench gen typed` / genTypedBytes).
/// This is the honest end-to-end number — parse *and* convert — not the raw scan.
fn measureTyped(corpus: []const u8, scratch: []u8, runs: usize) f64 {
    var best_ns: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        var rdr = csv.reader(TypedRow).init(corpus, scratch, .{}) catch |e|
            std.debug.panic("typed reader init failed: {s}", .{@errorName(e)});
        rdr.withHeader() catch |e|
            std.debug.panic("typed corpus needs an id,price,flag,name,category header: {s}", .{@errorName(e)});
        var sum: u64 = 0;
        const t0 = nanoTime();
        while (rdr.next() catch |e| std.debug.panic("typed row parse failed: {s}", .{@errorName(e)})) |row| {
            sum +%= @as(u64, @bitCast(row.id));
            sum +%= @as(u64, @intFromFloat(@abs(row.price)));
            sum +%= @intFromBool(row.flag);
            sum +%= row.name.len;
            sum +%= @intFromEnum(row.category);
        }
        const dt = nanoTime() - t0;
        std.mem.doNotOptimizeAway(sum);
        if (dt < best_ns) best_ns = dt;
    }
    const secs = @as(f64, @floatFromInt(best_ns)) / 1e9;
    const mb = @as(f64, @floatFromInt(corpus.len)) / (1024.0 * 1024.0);
    return mb / secs;
}

const stream_window = 64 * 1024;

/// Best-of-`runs` MB/s for the structural-scan ceiling (separator count, no
/// per-field work). Factored out so single-shot mode can request it too.
fn measureScan(corpus: []const u8, runs: usize) f64 {
    var best_ns: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < runs) : (i += 1) {
        const t0 = nanoTime();
        const seps = csv.simd.countSeparators(corpus, .{});
        const dt = nanoTime() - t0;
        std.mem.doNotOptimizeAway(seps);
        if (dt < best_ns) best_ns = dt;
    }
    const secs = @as(f64, @floatFromInt(best_ns)) / 1e9;
    const mb = @as(f64, @floatFromInt(corpus.len)) / (1024.0 * 1024.0);
    return mb / secs;
}

/// Load the real CSV corpus named by $ZSIFT_CORPUS, or null when unset. When
/// present it replaces the synthetic profiles so the benchmark reflects
/// real-world data (true field-length distribution, real quoting/escaping)
/// instead of the generator's short uniform fields.
fn envCorpus(init: std.process.Init, alloc: std.mem.Allocator) !?[]u8 {
    const path = init.environ_map.get("ZSIFT_CORPUS") orelse return null;
    return try std.Io.Dir.cwd().readFileAlloc(init.io, path, alloc, .unlimited);
}

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.page_allocator;
    const print = std.debug.print;

    // A real corpus named by $ZSIFT_CORPUS overrides the synthetic profiles (the
    // profile argument is then ignored), so the benchmark can report numbers on
    // real-world CSV rather than the generator's short-field synthetic data.
    const real = try envCorpus(init, alloc);
    defer if (real) |c| alloc.free(c);

    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    // `bench compare [--rounds N] [--paths ..] [files]` — alternating comparison of
    // the parser paths over the same bytes (replaced benchfence). See `compare.zig`.
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "compare")) {
        return compare.main(init, argv[2..]);
    }

    // `bench verify [--out P] [paths]` — every parser path over the same bytes,
    // judged against the scalar oracle / EXPECT.tsv. See `verify.zig`.
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "verify")) {
        return verify.main(init, argv[2..]);
    }

    // `bench sweep <file>` — size × worker-count sweep of the parallel path. See `sweep.zig`.
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "sweep")) {
        return sweep.main(init, argv[2..]);
    }

    // `bench gen <kind> <dir>` — deterministic corpus generators (structured / random).
    // Replaces the former Python generators. See `gen.zig`.
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "gen")) {
        return gen.main(init, argv[2..]);
    }

    // `bench experiment` — the full method-selection suite on self-generated
    // corpora (no $ZSIFT_CORPUS needed). Also `zig build experiment`.
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "experiment")) {
        try experiment.runExperiment(alloc);
        return;
    }

    // `bench matrix` (with $ZSIFT_CORPUS) runs the DETECT × COLLAPSE experiment
    // grid over the whole corpus instead of the normal report.
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "matrix")) {
        const corpus = real orelse {
            print("matrix mode needs $ZSIFT_CORPUS set to a CSV file\n", .{});
            return error.NoCorpus;
        };
        try methods.runMatrix(corpus, alloc);
        return;
    }

    // `bench project` — campaign axis: eager vs lazy collapse under projection.
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "project")) {
        const corpus = real orelse {
            print("project mode needs $ZSIFT_CORPUS set to a CSV file\n", .{});
            return error.NoCorpus;
        };
        try methods.runProjection(corpus, alloc);
        return;
    }

    // `bench width` — campaign axis: classifier chunk width sweep (32/64/128).
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "width")) {
        const corpus = real orelse {
            print("width mode needs $ZSIFT_CORPUS set to a CSV file\n", .{});
            return error.NoCorpus;
        };
        try methods.runWidth(corpus, alloc);
        return;
    }

    // `bench delivery` — campaign axis: API shape (pull vs batched-pull vs push).
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "delivery")) {
        const corpus = real orelse {
            print("delivery mode needs $ZSIFT_CORPUS set to a CSV file\n", .{});
            return error.NoCorpus;
        };
        var d_scratch: [64 * 1024]u8 = undefined;
        var d_window: [stream_window]u8 = undefined;
        var d_stream_scratch: [stream_window]u8 = undefined;
        const dmb = @as(f64, @floatFromInt(corpus.len)) / (1024.0 * 1024.0);
        print("delivery over {d:.2} MiB, best of {d} — MB/s\n", .{ dmb, iters });
        print("{s:>10} {s:>11} {s:>10} {s:>10}\n", .{ "pull", "pull-batch", "push", "stream" });
        print("{d:>10.0} {d:>11.0} {d:>10.0} {d:>10.0}\n", .{
            measure(csv.SimdParser, corpus, &d_scratch, iters),
            measurePullBatch(corpus, &d_scratch, iters),
            measureCallback(corpus, &d_scratch, iters),
            measureStream(corpus, &d_window, &d_stream_scratch, iters),
        });
        return;
    }

    var scratch: [64 * 1024]u8 = undefined;
    var window: [stream_window]u8 = undefined;
    var stream_scratch: [stream_window]u8 = undefined;

    // Real corpus: one measured row across all paths, plus a scalar-vs-SIMD
    // field checksum cross-check that catches the two parsers disagreeing on the
    // real data (embedded newlines, escaped quotes, cross-chunk quoted fields).
    if (real) |corpus| {
        const warm = parseOnce(csv.Parser, corpus, &scratch);
        const warm_simd = parseOnce(csv.SimdParser, corpus, &scratch);
        const match = warm.checksum == warm_simd.checksum;
        print("zsift benchmark — real corpus $ZSIFT_CORPUS: {d:.2} MiB, {d} records, best of {d}\n", .{ @as(f64, @floatFromInt(corpus.len)) / (1024.0 * 1024.0), warm.rows, iters });
        print("scalar/simd field checksum: {s}\n", .{if (match) "MATCH" else "MISMATCH — parsers disagree!"});
        print("{s:<9} {s:>10} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{ "corpus", "rows", "scalar", "simd pull", "simd push", "stream", "scan ceil" });
        print("{s:<9} {s:>10} {s:>9} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{ "", "", "MB/s", "MB/s", "MB/s", "MB/s", "MB/s" });
        print("{s:<9} {d:>10} {d:>9.1} {d:>10.1} {d:>10.1} {d:>10.1} {d:>10.1}\n", .{
            "real",
            warm.rows,
            measure(csv.Parser, corpus, &scratch, iters),
            measure(csv.SimdParser, corpus, &scratch, iters),
            measureCallback(corpus, &scratch, iters),
            measureStream(corpus, &window, &stream_scratch, iters),
            measureScan(corpus, iters),
        });
        return;
    }

    print("zsift benchmark — corpus ~{d} MiB/profile, {d} cols, best of {d} ({d} KiB stream window)\n", .{ target_bytes >> 20, cols, iters, stream_window >> 10 });
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
