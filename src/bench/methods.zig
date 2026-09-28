// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Experiment harness (not part of the shipped parser): a DETECT × COLLAPSE
//! matrix over quoted-field handling. For each combination it parses the WHOLE
//! corpus with the push structure and reports throughput plus whether the output
//! matches the scalar parser. Reading the grid:
//!   * down a column (fixed collapse) = the cost of the detection strategy
//!   * across a row (fixed detect)     = the cost of the collapse strategy
//!   * the `detect=none` row and `collapse=none` column are deliberately WRONG
//!     (they isolate one cost); only the bottom-right block produces correct output.

const std = @import("std");
const csv = @import("csv");
const classify = csv.classify;

const reps = 7;

/// How a field decides it contains an escaped `""`.
pub const Detect = enum {
    none, // assume no escape (wrong on escaped fields) — isolates delivery cost
    rescan, // std.mem.indexOfScalar over the field bytes (the current parser)
    swar, // word-at-a-time (SWAR) byte search
    accum, // running quote-count from the SIMD mask (popcount, no byte re-scan)
};

/// How a field removes its `""` once detection says it must.
pub const Collapse = enum {
    none, // skip (wrong on escaped fields) — isolates detection cost
    byteloop, // byte-by-byte with a per-byte branch (the current parser)
    memcpy, // copy clean runs with @memcpy (std.mem.indexOfScalarPos finds runs)
    swarcpy, // copy clean runs with @memcpy, but a SWAR word-scan finds the runs
    mask, // copy clean runs, but the classifier's quote mask (@ctz) finds the runs
};

fn nanoTime() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

// --- primitives shared with the real parser (kept local so the library is untouched) ---

inline fn recordStep(input: []const u8, at: usize, delim: u8) usize {
    if (input[at] == delim) return at + 1;
    return if (input[at] == '\r' and at + 1 < input.len and input[at + 1] == '\n') at + 2 else at + 1;
}

inline fn quotesBelow(q: u64, rel: usize) u64 {
    const below: u64 = (@as(u64, 1) << @intCast(rel)) -% 1;
    return @popCount(q & below);
}

/// SWAR "does `s` contain byte `b`": classic haszero over 8 bytes at a time.
fn swarHasByte(s: []const u8, b: u8) bool {
    const ONES: u64 = 0x0101010101010101;
    const HIGH: u64 = 0x8080808080808080;
    const pat: u64 = ONES *% b;
    var i: usize = 0;
    while (i + 8 <= s.len) : (i += 8) {
        const w = std.mem.readInt(u64, s[i..][0..8], .little);
        const x = w ^ pat;
        if (((x -% ONES) & ~x & HIGH) != 0) return true;
    }
    while (i < s.len) : (i += 1) if (s[i] == b) return true;
    return false;
}

/// SWAR "index of byte `b` in `s` at/after `start`", or null. Same haszero trick
/// as `swarHasByte`, but returns the position of the first match.
fn swarIndexOfPos(s: []const u8, start: usize, b: u8) ?usize {
    const ONES: u64 = 0x0101010101010101;
    const HIGH: u64 = 0x8080808080808080;
    const pat: u64 = ONES *% b;
    var i: usize = start;
    while (i + 8 <= s.len) : (i += 8) {
        const w = std.mem.readInt(u64, s[i..][0..8], .little);
        const x = w ^ pat;
        const hz = (x -% ONES) & ~x & HIGH;
        if (hz != 0) return i + (@ctz(hz) >> 3); // byte index of the lowest match
    }
    while (i < s.len) : (i += 1) if (s[i] == b) return i;
    return null;
}

fn collapseByteLoop(in: []const u8, quote: u8, dst: []u8) []const u8 {
    var w: usize = 0;
    var j: usize = 0;
    while (j < in.len) {
        dst[w] = in[j];
        w += 1;
        j += if (in[j] == quote) 2 else 1;
    }
    return dst[0..w];
}

fn collapseMemcpy(in: []const u8, quote: u8, dst: []u8) []const u8 {
    var w: usize = 0;
    var j: usize = 0;
    while (j < in.len) {
        const nq = std.mem.indexOfScalarPos(u8, in, j, quote) orelse in.len;
        const run = nq - j;
        @memcpy(dst[w..][0..run], in[j..][0..run]);
        w += run;
        if (nq == in.len) break;
        dst[w] = quote; // one quote per escaped pair
        w += 1;
        j = nq + 2;
    }
    return dst[0..w];
}

fn collapseSwarCpy(in: []const u8, quote: u8, dst: []u8) []const u8 {
    var w: usize = 0;
    var j: usize = 0;
    while (j < in.len) {
        const nq = swarIndexOfPos(in, j, quote) orelse in.len;
        const run = nq - j;
        @memcpy(dst[w..][0..run], in[j..][0..run]);
        w += run;
        if (nq == in.len) break;
        dst[w] = quote;
        w += 1;
        j = nq + 2;
    }
    return dst[0..w];
}

/// Mask-driven collapse for a field wholly inside one chunk: the escaped-quote
/// positions come from the classifier's quote mask (`@ctz`) instead of re-searching
/// the bytes. `qbits` is the chunk mask restricted to the inner byte range; `lo` is
/// the chunk-relative bit of `inner[0]`. Interior quotes are adjacent `""` pairs.
fn collapseMaskSingleChunk(inner: []const u8, quote: u8, dst: []u8, qbits: u64, lo: u6) usize {
    var w: usize = 0;
    var prev: usize = 0;
    var m = qbits;
    while (m != 0) {
        const k = @as(usize, @ctz(m)) - @as(usize, lo); // inner-relative pair start
        const run = k - prev;
        @memcpy(dst[w..][0..run], inner[prev..][0..run]);
        w += run;
        dst[w] = quote;
        w += 1;
        prev = k + 2; // skip the escaped pair
        m &= m - 1; // clear the pair's first quote bit
        m &= m - 1; // clear the pair's (adjacent) second quote bit
    }
    const run = inner.len - prev;
    @memcpy(dst[w..][0..run], inner[prev..][0..run]);
    return w + run;
}

/// `.mask` dispatch: a field wholly inside one chunk uses the mask; a field that
/// straddles a chunk boundary falls back to the byte-scan collapse.
inline fn deliverMask(raw: []const u8, quote: u8, dst: []u8, needs: bool, qmask: u64, field_start: usize, at: usize, base: usize) []const u8 {
    if (raw.len < 2 or raw[0] != quote) return raw;
    const inner = raw[1 .. raw.len - 1];
    if (!needs) return inner;
    if (field_start >= base) {
        const lo: u6 = @intCast(field_start + 1 - base);
        const hi: u6 = @intCast(at - 1 - base);
        const range = ((@as(u64, 1) << hi) -% 1) & ~((@as(u64, 1) << lo) -% 1);
        return dst[0..collapseMaskSingleChunk(inner, quote, dst, qmask & range, lo)];
    }
    return collapseSwarCpy(inner, quote, dst);
}

/// Turn a raw field into its delivered value under collapse strategy `c`, given a
/// precomputed `needs` (does it contain an escaped `""`).
inline fn deliver(comptime c: Collapse, raw: []const u8, quote: u8, dst: []u8, needs: bool) []const u8 {
    if (raw.len < 2 or raw[0] != quote) return raw; // unquoted → as-is
    const in = raw[1 .. raw.len - 1];
    if (!needs) return in;
    return switch (c) {
        .none => in, // detected but not collapsed (wrong)
        .byteloop => collapseByteLoop(in, quote, dst),
        .memcpy => collapseMemcpy(in, quote, dst),
        .swarcpy => collapseSwarCpy(in, quote, dst),
        .mask => collapseSwarCpy(in, quote, dst), // fallback for the final tail field
    };
}

/// Parse the whole corpus with the push structure under (detect, collapse) and
/// return a checksum (sum of delivered field lengths).
fn parseChecksum(comptime d: Detect, comptime c: Collapse, input: []const u8, scratch: []u8, opts: csv.Options) u64 {
    const quote = opts.quote;
    const delim = opts.delimiter;
    var sum: u64 = 0;
    var field_start: usize = 0;
    var carry: u64 = 0;
    var base: usize = 0;
    var qbc: u64 = 0; // accum only: quote bits before `base`
    var fs_q: u64 = 0; // accum only: quote bits up to field_start
    while (base < input.len) : (base += classify.chunk_len) {
        const cl = classify.classifyAtFull(input, base, opts, &carry);
        var s = cl.seps;
        const has_q = cl.quotes != 0;
        while (s != 0) {
            const rel: usize = @ctz(s);
            s &= s - 1;
            const at = base + rel;
            if (at < field_start) continue;
            const raw = input[field_start..at];
            const needs = detect(d, raw, quote, cl.quotes, rel, has_q, &qbc, &fs_q);
            const val = if (c == .mask)
                deliverMask(raw, quote, scratch, needs, cl.quotes, field_start, at, base)
            else
                deliver(c, raw, quote, scratch, needs);
            sum +%= val.len;
            field_start = recordStep(input, at, delim);
        }
        if (d == .accum and has_q) qbc += @popCount(cl.quotes);
    }
    if (field_start < input.len) {
        const raw = input[field_start..];
        const needs = switch (d) {
            .none => false,
            .rescan => raw.len >= 2 and raw[0] == quote and std.mem.indexOfScalar(u8, raw[1 .. raw.len - 1], quote) != null,
            .swar => raw.len >= 2 and raw[0] == quote and swarHasByte(raw[1 .. raw.len - 1], quote),
            .accum => (qbc - fs_q) > 2,
        };
        sum +%= deliver(c, raw, quote, scratch, needs).len;
    }
    return sum;
}

inline fn detect(comptime d: Detect, raw: []const u8, quote: u8, q: u64, rel: usize, has_q: bool, qbc: *u64, fs_q: *u64) bool {
    switch (d) {
        .none => return false,
        .rescan => return raw.len >= 2 and raw[0] == quote and std.mem.indexOfScalar(u8, raw[1 .. raw.len - 1], quote) != null,
        .swar => return raw.len >= 2 and raw[0] == quote and swarHasByte(raw[1 .. raw.len - 1], quote),
        .accum => {
            const q_up_to = if (has_q) qbc.* + quotesBelow(q, rel) else qbc.*;
            const n = (q_up_to - fs_q.*) > 2;
            fs_q.* = q_up_to;
            return n;
        },
    }
}

fn scalarChecksum(corpus: []const u8, scratch: []u8) u64 {
    var p = csv.Parser.init(corpus, scratch, .{}) catch |e| std.debug.panic("bench: {s}", .{@errorName(e)});
    var sum: u64 = 0;
    while (p.next() catch null) |first| {
        p.resetScratch();
        var f = first;
        while (true) {
            sum +%= f.bytes.len;
            if (f.last_in_record) break;
            f = (p.next() catch null) orelse break;
        }
    }
    return sum;
}

fn measure(comptime d: Detect, comptime c: Collapse, corpus: []const u8, scratch: []u8, mb: f64) f64 {
    std.mem.doNotOptimizeAway(parseChecksum(d, c, corpus, scratch, .{})); // warm
    var best: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < reps) : (i += 1) {
        const t0 = nanoTime();
        const s = parseChecksum(d, c, corpus, scratch, .{});
        const dt = nanoTime() - t0;
        std.mem.doNotOptimizeAway(s);
        if (dt < best) best = dt;
    }
    return mb / (@as(f64, @floatFromInt(best)) / 1e9);
}

/// Single-shot measurement of ONE cell (for a benchfence driver): runs
/// (detect, collapse) over the whole corpus once (best of `reps`) and returns
/// MB/s. Names match the enum tags (e.g. "accum", "memcpy").
pub fn runCell(detect_name: []const u8, collapse_name: []const u8, corpus: []const u8, alloc: std.mem.Allocator) !f64 {
    const scratch = try alloc.alloc(u8, corpus.len + 64);
    defer alloc.free(scratch);
    const mb = @as(f64, @floatFromInt(corpus.len)) / (1024.0 * 1024.0);
    inline for (.{ Detect.none, Detect.rescan, Detect.swar, Detect.accum }) |d| {
        if (std.mem.eql(u8, detect_name, @tagName(d))) {
            inline for (.{ Collapse.none, Collapse.byteloop, Collapse.memcpy, Collapse.swarcpy, Collapse.mask }) |c| {
                if (std.mem.eql(u8, collapse_name, @tagName(c))) return measure(d, c, corpus, scratch, mb);
            }
        }
    }
    return error.UnknownCell;
}

// --- Campaign axis: classifier chunk width (32 / 64 / 128-byte vectors) ---
// A width-generic version of the classifier + the shipped accum/swarcpy parse, so
// we can measure whether native 32-byte AVX2 beats the 64-byte emulation (or 128).

fn Classifier(comptime W: usize) type {
    return struct {
        const Vec = @Vector(W, u8);
        const Mask = std.meta.Int(.unsigned, W);
        const SMask = std.meta.Int(.signed, W);

        fn prefixXor(x: Mask) Mask {
            var r = x;
            comptime var sh: usize = 1;
            inline while (sh < W) : (sh *= 2) {
                r ^= r << @intCast(sh);
            }
            return r;
        }

        fn loadVec(input: []const u8, base: usize) Vec {
            if (base + W <= input.len) return input[base..][0..W].*;
            var buf: [W]u8 = @splat(0);
            @memcpy(buf[0 .. input.len - base], input[base..]);
            return buf;
        }

        const Res = struct { seps: Mask, quotes: Mask };
        fn classify(input: []const u8, base: usize, opts: csv.Options, carry: *Mask) Res {
            const v = loadVec(input, base);
            const quote_bits: Mask = @bitCast(v == @as(Vec, @splat(opts.quote)));
            const inside = prefixXor(quote_bits) ^ carry.*;
            carry.* = @bitCast(@as(SMask, @bitCast(inside)) >> (W - 1));
            const delim_bits: Mask = @bitCast(v == @as(Vec, @splat(opts.delimiter)));
            const lf: Mask = @bitCast(v == @as(Vec, @splat('\n')));
            const cr: Mask = @bitCast(v == @as(Vec, @splat('\r')));
            return .{ .seps = (delim_bits | lf | cr) & ~inside, .quotes = quote_bits };
        }
    };
}

fn parseW(comptime W: usize, input: []const u8, scratch: []u8, opts: csv.Options) u64 {
    const C = Classifier(W);
    const quote = opts.quote;
    const delim = opts.delimiter;
    var sum: u64 = 0;
    var field_start: usize = 0;
    var carry: C.Mask = 0;
    var base: usize = 0;
    var qbc: u64 = 0;
    var fs_q: u64 = 0;
    while (base < input.len) : (base += W) {
        const cl = C.classify(input, base, opts, &carry);
        var s = cl.seps;
        const has_q = cl.quotes != 0;
        while (s != 0) {
            const rel: usize = @ctz(s);
            s &= s - 1;
            const at = base + rel;
            if (at < field_start) continue;
            const raw = input[field_start..at];
            var needs = false;
            if (input[field_start] == quote) {
                const below: C.Mask = (@as(C.Mask, 1) << @intCast(rel)) -% 1;
                const q_up_to = if (has_q) qbc + @popCount(cl.quotes & below) else qbc;
                needs = (q_up_to - fs_q) > 2;
                fs_q = q_up_to;
            }
            sum +%= deliver(.swarcpy, raw, quote, scratch, needs).len;
            field_start = recordStep(input, at, delim);
        }
        if (has_q) qbc += @popCount(cl.quotes);
    }
    if (field_start < input.len) {
        const raw = input[field_start..];
        const needs = input[field_start] == quote and (qbc - fs_q) > 2;
        sum +%= deliver(.swarcpy, raw, quote, scratch, needs).len;
    }
    return sum;
}

fn measureW(comptime W: usize, corpus: []const u8, scratch: []u8, mb: f64) f64 {
    std.mem.doNotOptimizeAway(parseW(W, corpus, scratch, .{}));
    var best: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < reps) : (i += 1) {
        const t0 = nanoTime();
        const s = parseW(W, corpus, scratch, .{});
        const dt = nanoTime() - t0;
        std.mem.doNotOptimizeAway(s);
        if (dt < best) best = dt;
    }
    return mb / (@as(f64, @floatFromInt(best)) / 1e9);
}

/// Sweep classifier chunk width (accum+swarcpy fixed). Checksum must match scalar.
pub fn runWidth(corpus: []const u8, alloc: std.mem.Allocator) !void {
    const print = std.debug.print;
    const scratch = try alloc.alloc(u8, corpus.len + 64);
    defer alloc.free(scratch);
    const ref = scalarChecksum(corpus, scratch);
    const mb = @as(f64, @floatFromInt(corpus.len)) / (1024.0 * 1024.0);
    print("\nCHUNK WIDTH sweep (accum+swarcpy), {d:.2} MiB, best of {d}\n", .{ mb, reps });
    print("{s:>8} {s:>10} {s:>8}\n", .{ "width", "MB/s", "correct" });
    inline for (.{ 32, 64, 128 }) |w| {
        const sum = parseW(w, corpus, scratch, .{});
        const mbps = measureW(w, corpus, scratch, mb);
        print("{d:>8} {d:>10.0} {s:>8}\n", .{ w, mbps, if (sum == ref) "MATCH" else "MISMATCH" });
    }
}

// --- Campaign axis: eager vs lazy materialization under a projection workload ---
// Fixes detection=accum, collapse=swarcpy (the shipped pair) and only varies whether
// the collapse is done for every field (eager) or only for the fields a projecting
// consumer actually reads (lazy). Detection still runs for all fields — it maintains
// the running counts and is cheap; only the expensive collapse is deferred.

fn parseProject(comptime lazy: bool, comptime stride: usize, input: []const u8, scratch: []u8, opts: csv.Options) u64 {
    const quote = opts.quote;
    const delim = opts.delimiter;
    var sum: u64 = 0;
    var field_start: usize = 0;
    var carry: u64 = 0;
    var base: usize = 0;
    var qbc: u64 = 0;
    var fs_q: u64 = 0;
    var fi: usize = 0; // field index across the whole input
    while (base < input.len) : (base += classify.chunk_len) {
        const cl = classify.classifyAtFull(input, base, opts, &carry);
        var s = cl.seps;
        const has_q = cl.quotes != 0;
        while (s != 0) {
            const rel: usize = @ctz(s);
            s &= s - 1;
            const at = base + rel;
            if (at < field_start) continue;
            const raw = input[field_start..at];
            const needs = detect(.accum, raw, quote, cl.quotes, rel, has_q, &qbc, &fs_q);
            const projected = (fi % stride) == 0;
            if (lazy) {
                if (projected) sum +%= deliver(.swarcpy, raw, quote, scratch, needs).len;
                // non-projected fields skip the collapse entirely
            } else {
                const v = deliver(.swarcpy, raw, quote, scratch, needs); // collapse every field
                if (projected) sum +%= v.len;
            }
            fi += 1;
            field_start = recordStep(input, at, delim);
        }
        if (has_q) qbc += @popCount(cl.quotes);
    }
    return sum;
}

fn measureProject(comptime lazy: bool, comptime stride: usize, corpus: []const u8, scratch: []u8, mb: f64) f64 {
    std.mem.doNotOptimizeAway(parseProject(lazy, stride, corpus, scratch, .{}));
    var best: u64 = std.math.maxInt(u64);
    var i: usize = 0;
    while (i < reps) : (i += 1) {
        const t0 = nanoTime();
        const s = parseProject(lazy, stride, corpus, scratch, .{});
        const dt = nanoTime() - t0;
        std.mem.doNotOptimizeAway(s);
        if (dt < best) best = dt;
    }
    return mb / (@as(f64, @floatFromInt(best)) / 1e9);
}

/// Eager vs lazy collapse across projection strides (read 1 of every N fields).
pub fn runProjection(corpus: []const u8, alloc: std.mem.Allocator) !void {
    const print = std.debug.print;
    const scratch = try alloc.alloc(u8, corpus.len + 64);
    defer alloc.free(scratch);
    const mb = @as(f64, @floatFromInt(corpus.len)) / (1024.0 * 1024.0);
    print("\nEAGER vs LAZY collapse (accum+swarcpy), {d:.2} MiB, best of {d}, MB/s\n", .{ mb, reps });
    print("{s:<14} {s:>10} {s:>10} {s:>8}\n", .{ "read 1 of", "eager", "lazy", "lazy/eager" });
    inline for (.{ 1, 2, 4, 12 }) |stride| {
        const e = measureProject(false, stride, corpus, scratch, mb);
        const l = measureProject(true, stride, corpus, scratch, mb);
        print("{d:<14} {d:>10.0} {d:>10.0} {d:>7.2}x\n", .{ stride, e, l, l / e });
    }
}

/// Run the full DETECT × COLLAPSE grid over `corpus` and print MB/s + correctness.
pub fn runMatrix(corpus: []const u8, alloc: std.mem.Allocator) !void {
    const print = std.debug.print;
    const scratch = try alloc.alloc(u8, corpus.len + 64);
    defer alloc.free(scratch);

    const ref = scalarChecksum(corpus, scratch);
    const mb = @as(f64, @floatFromInt(corpus.len)) / (1024.0 * 1024.0);

    // structural-scan ceiling (no per-field work)
    var cbest: u64 = std.math.maxInt(u64);
    var k: usize = 0;
    while (k < reps) : (k += 1) {
        const t0 = nanoTime();
        const n = csv.simd.countSeparators(corpus, .{});
        const dt = nanoTime() - t0;
        std.mem.doNotOptimizeAway(n);
        if (dt < cbest) cbest = dt;
    }
    const ceil = mb / (@as(f64, @floatFromInt(cbest)) / 1e9);

    print("\nDETECT × COLLAPSE — {d:.2} MiB, best of {d}, MB/s ('*' = output differs from scalar)\n", .{ mb, reps });
    print("{s:<8} {s:>13} {s:>13} {s:>13} {s:>13} {s:>13}\n", .{ "det\\coll", "none", "byteloop", "memcpy", "swarcpy", "mask" });
    inline for (.{ Detect.none, Detect.rescan, Detect.swar, Detect.accum }) |d| {
        print("{s:<8}", .{@tagName(d)});
        inline for (.{ Collapse.none, Collapse.byteloop, Collapse.memcpy, Collapse.swarcpy, Collapse.mask }) |c| {
            const sum = parseChecksum(d, c, corpus, scratch, .{});
            const mbps = measure(d, c, corpus, scratch, mb);
            print(" {d:>11.0}{s} ", .{ mbps, if (sum == ref) " " else "*" });
        }
        print("\n", .{});
    }
    print("refs: structural-scan ceiling {d:.0} MB/s | correct cells: (rescan|swar|accum) × (byteloop|memcpy)\n", .{ceil});
}
