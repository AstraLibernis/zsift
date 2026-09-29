// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Reproducible method-selection experiment — the proof behind zsift's parser
//! choices. `zig build experiment` (or `bench experiment`) generates deterministic
//! corpora and runs every bake-off in one report, so anyone can see WHY the shipped
//! methods were chosen. See EXPERIMENTS.md for the write-up.
//!
//! Self-contained: it generates its own corpora, so no external data file is needed.
//! (Point $ZSIFT_CORPUS at a real CSV and use the per-station modes — `bench matrix`,
//! `width`, `delivery`, `project` — to run any one station on real data instead.)
//!
//! The parser is an assembly line: SCAN (chunk width) → CUT → CHECK (detect) → FIX
//! (collapse) → DELIVER. This runs a bake-off at each station on light- and
//! heavy-escape corpora, printing throughput (and a correctness mark where relevant).

const std = @import("std");
const csv = @import("csv");
const methods = @import("methods.zig");

const reps = 7;

fn nanoTime() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// ---------------------------------------------------------------------------
// Deterministic corpus generator (varied field lengths, cross-chunk quoted
// fields, tunable escape density) — so the experiment reproduces anywhere.
// ---------------------------------------------------------------------------

const first_names = [_][]const u8{ "James", "Mary", "John", "Patricia", "Robert", "Jennifer", "Michael", "Linda", "William", "Elizabeth", "David", "Susan" };
const last_names = [_][]const u8{ "Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis", "Rodriguez", "Wilson" };
const cities = [_][]const u8{ "Springfield", "Riverside", "Franklin", "Greenville", "Bristol", "Fairview", "Salem", "Madison", "Georgetown", "Ashland" };
const states = [_][]const u8{ "CA", "TX", "NY", "FL", "OH", "IL", "PA", "GA", "NC", "MI" };
const words = [_][]const u8{ "invoice", "pending", "review", "urgent", "note", "account", "balance", "overdue", "shipment", "priority", "internal", "memo", "summary", "attached", "report", "meeting", "renewal", "quarter", "escalated", "confirmed" };

/// bufPrint into a caller stack buffer that is always sized large enough here; a
/// formatting failure would be a benchmark bug, so fail loud rather than hit release UB.
fn fmtInto(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch |e| std.debug.panic("experiment fmt: {s}", .{@errorName(e)});
}

fn appendInt(out: *std.ArrayList(u8), alloc: std.mem.Allocator, n: usize) !void {
    var buf: [24]u8 = undefined;
    try out.appendSlice(alloc, fmtInto(&buf, "{d}", .{n}));
}

/// Emit `value` as a CSV field, quoting + escaping (`"`→`""`) when it contains a
/// delimiter, quote, or newline (RFC 4180) — what a correct writer produces.
fn emitField(out: *std.ArrayList(u8), alloc: std.mem.Allocator, value: []const u8) !void {
    if (std.mem.findAny(u8, value, ",\"\n") == null) {
        try out.appendSlice(alloc, value);
        return;
    }
    try out.append(alloc, '"');
    for (value) |c| {
        if (c == '"') try out.append(alloc, '"');
        try out.append(alloc, c);
    }
    try out.append(alloc, '"');
}

/// Deterministic corpus of rows {id, name, age, city, description}. Names and
/// cities sometimes carry a comma (→ quoted); descriptions are 3–11 words (some
/// exceed 64 bytes → cross-chunk quoted fields), and `escape_pct` of them embed a
/// quoted word (→ escaped `""`). Seeded by `escape_pct` so light/heavy differ.
pub fn genCorpus(alloc: std.mem.Allocator, escape_pct: u8, target: usize) ![]u8 {
    var prng = std.Random.DefaultPrng.init(0xC57ABE11 ^ @as(u64, escape_pct));
    const r = prng.random();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, target + 1024);
    var field: [1024]u8 = undefined;
    var id: usize = 1;
    while (out.items.len < target) : (id += 1) {
        try appendInt(&out, alloc, id);
        try out.append(alloc, ',');

        const fnm = first_names[r.uintLessThan(usize, first_names.len)];
        const lnm = last_names[r.uintLessThan(usize, last_names.len)];
        if (r.uintLessThan(u8, 5) == 0) {
            try emitField(&out, alloc, fmtInto(&field, "{s}, {s}", .{ lnm, fnm }));
        } else {
            try out.appendSlice(alloc, fnm);
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, lnm);
        }
        try out.append(alloc, ',');

        try appendInt(&out, alloc, 18 + r.uintLessThan(usize, 60));
        try out.append(alloc, ',');

        const city = cities[r.uintLessThan(usize, cities.len)];
        if (r.uintLessThan(u8, 3) == 0) {
            try emitField(&out, alloc, fmtInto(&field, "{s}, {s}", .{ city, states[r.uintLessThan(usize, states.len)] }));
        } else {
            try out.appendSlice(alloc, city);
        }
        try out.append(alloc, ',');

        // description: 3..11 words, some commas, escape_pct of rows embed a quote
        var w: usize = 0;
        const nwords = 3 + r.uintLessThan(usize, 9);
        var k: usize = 0;
        while (k < nwords) : (k += 1) {
            if (k != 0) {
                field[w] = ' ';
                w += 1;
            }
            const word = words[r.uintLessThan(usize, words.len)];
            @memcpy(field[w..][0..word.len], word);
            w += word.len;
            if (r.uintLessThan(u8, 6) == 0) {
                field[w] = ',';
                w += 1;
            }
        }
        if (r.uintLessThan(u8, 100) < escape_pct) {
            const q = " \"flagged\"";
            @memcpy(field[w..][0..q.len], q);
            w += q.len;
        }
        try emitField(&out, alloc, field[0..w]);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Station 3: delivery-shape bake-off (pull vs batched-pull vs push).
// ---------------------------------------------------------------------------

const Sink = struct {
    sum: u64 = 0,
    fn on(self: *@This(), bytes: []const u8, last: bool) void {
        self.sum +%= bytes.len;
        _ = last;
    }
};

fn mbps(corpus_len: usize, best_ns: u64) f64 {
    const mb = @as(f64, @floatFromInt(corpus_len)) / (1024.0 * 1024.0);
    return mb / (@as(f64, @floatFromInt(best_ns)) / 1e9);
}

/// pull / batched-pull / push over `corpus`. Stream is measured in the normal
/// report; the interesting delivery contrast is these three.
pub fn runDelivery(corpus: []const u8, alloc: std.mem.Allocator) !void {
    const print = std.debug.print;
    const scratch = try alloc.alloc(u8, corpus.len + 64);
    defer alloc.free(scratch);

    var pull: u64 = std.math.maxInt(u64);
    var batch: u64 = std.math.maxInt(u64);
    var push: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < reps) : (i += 1) {
        // pull
        {
            var p = csv.SimdParser.init(corpus, scratch, .{}) catch |e| std.debug.panic("bench: {s}", .{@errorName(e)});
            var sum: u64 = 0;
            const t0 = nanoTime();
            while (p.next() catch null) |f| sum +%= f.bytes.len;
            const dt = nanoTime() - t0;
            std.mem.doNotOptimizeAway(sum);
            if (dt < pull) pull = dt;
        }
        // batched pull
        {
            var p = csv.SimdParser.init(corpus, scratch, .{}) catch |e| std.debug.panic("bench: {s}", .{@errorName(e)});
            var fbuf: [64]csv.Field = undefined;
            var sum: u64 = 0;
            const t0 = nanoTime();
            while (true) {
                const got = p.nextInto(&fbuf) catch |e| std.debug.panic("nextInto: {s}", .{@errorName(e)});
                if (got == 0) break;
                for (fbuf[0..got]) |f| sum +%= f.bytes.len;
                p.resetScratch();
            }
            const dt = nanoTime() - t0;
            std.mem.doNotOptimizeAway(sum);
            if (dt < batch) batch = dt;
        }
        // push
        {
            var s = Sink{};
            const t0 = nanoTime();
            csv.simd.forEachField(corpus, scratch, .{}, &s, Sink.on) catch |e| std.debug.panic("forEachField: {s}", .{@errorName(e)});
            const dt = nanoTime() - t0;
            std.mem.doNotOptimizeAway(s.sum);
            if (dt < push) push = dt;
        }
    }
    print("{s:>12} {s:>12} {s:>12}\n", .{ "pull", "pull-batch", "push" });
    print("{d:>12.0} {d:>12.0} {d:>12.0}\n", .{ mbps(corpus.len, pull), mbps(corpus.len, batch), mbps(corpus.len, push) });
}

// ---------------------------------------------------------------------------
// The combined suite.
// ---------------------------------------------------------------------------

/// Run every station's bake-off on self-generated light- and heavy-escape corpora.
pub fn runExperiment(alloc: std.mem.Allocator) !void {
    const print = std.debug.print;
    const size = 16 << 20; // 16 MiB per corpus — larger than L2, exercises memory

    print(
        \\zsift method-selection experiment
        \\=================================
        \\The parser is an assembly line: SCAN (chunk width) -> CUT -> CHECK (detect
        \\escaped "") -> FIX (collapse "") -> DELIVER. Below is a bake-off at each
        \\station, on two self-generated corpora: LIGHT (~5% of fields escaped) and
        \\HEAVY (~60%). Numbers are best-of-{d} MB/s and are MACHINE-SPECIFIC and
        \\contention-sensitive on a shared box — for trustworthy numbers run the cells
        \\under benchfence (`zig build matrix -- <corpus.csv>`). The winners are what zsift ships.
        \\
        \\
    , .{reps});

    const light = try genCorpus(alloc, 5, size);
    defer alloc.free(light);
    const heavy = try genCorpus(alloc, 60, size);
    defer alloc.free(heavy);
    print("corpora: light {d:.1} MiB (~5% escaped), heavy {d:.1} MiB (~60% escaped)\n", .{
        @as(f64, @floatFromInt(light.len)) / (1024.0 * 1024.0),
        @as(f64, @floatFromInt(heavy.len)) / (1024.0 * 1024.0),
    });

    print("\n===== STATION 1/4: DETECT x COLLAPSE (per-field escape handling) =====\n", .{});
    print("Down a column = detection cost; across a row = collapse cost. '*' = wrong\n", .{});
    print("output (a diagnostic cell). SHIPPED: detect=accum, collapse=swarcpy.\n", .{});
    print("\n--- light ---\n", .{});
    try methods.runMatrix(light, alloc);
    print("\n--- heavy ---\n", .{});
    try methods.runMatrix(heavy, alloc);

    print("\n===== STATION 2/4: CLASSIFIER CHUNK WIDTH =====\n", .{});
    print("Bytes classified per SIMD step. SHIPPED: 64.\n", .{});
    print("\n--- light ---\n", .{});
    try methods.runWidth(light, alloc);
    print("\n--- heavy ---\n", .{});
    try methods.runWidth(heavy, alloc);

    print("\n===== STATION 3/4: DELIVERY (API shape) =====\n", .{});
    print("How finished fields reach the caller. push is fastest; nextInto (batched\n", .{});
    print("pull) recovers much of the one-at-a-time pull tax.\n", .{});
    print("\n--- light ---\n", .{});
    try runDelivery(light, alloc);
    print("\n--- heavy ---\n", .{});
    try runDelivery(heavy, alloc);

    print("\n===== STATION 4/4: EAGER vs LAZY (projection) =====\n", .{});
    print("Collapse every field (eager) vs only fields a projecting reader keeps\n", .{});
    print("(lazy). Lazy helps only when you skip fields — a separate API, not a default.\n", .{});
    print("\n--- light ---\n", .{});
    try methods.runProjection(light, alloc);
    print("\n--- heavy ---\n", .{});
    try methods.runProjection(heavy, alloc);

    print("\nDone. Re-run: `zig build experiment`. Full write-up: EXPERIMENTS.md.\n", .{});
}
