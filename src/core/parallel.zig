// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

//! Exact record boundaries for splitting one input across workers.
//!
//! Cutting a CSV at arbitrary byte offsets is only safe at a record start, and whether
//! a newline starts a record depends on whether it sits inside a quoted field — which
//! depends on every quote before it. Under strict RFC 4180 quoting (enforced by the
//! SIMD paths since v0.4), a position is inside a quoted field iff an odd number of
//! quote bytes precede it: an escaped `""` adds two. So the split is exact, with no
//! speculation, in two phases that each parallelize:
//!
//!   1. `countQuotes` over each range, independently;
//!   2. a prefix sum of those counts gives each cut its in-quote state, and
//!      `recordStartAfter` scans forward from each cut, independently, to the first
//!      record start.
//!
//! `splitRecords` runs both phases serially; `forEachField` runs them, and then the
//! parse of each range, on the caller's `std.Io` (one task per worker). Invalid quoting
//! is reported by the parser that consumes each range (`classify.quoteViolation`).

const std = @import("std");
const types = @import("types.zig");
const simd = @import("simd.zig");
const assert = std.debug.assert;

const Options = types.Options;
const Error = types.Error;
const classify = simd.classify;
const chunk_len = classify.chunk_len;
const Vec = @Vector(chunk_len, u8);

/// Number of `quote` bytes in `bytes` (SIMD compare + popcount per 64-byte chunk).
pub fn countQuotes(bytes: []const u8, quote: u8) u64 {
    var total: u64 = 0;
    var i: usize = 0;
    while (i + chunk_len <= bytes.len) : (i += chunk_len) {
        const v: Vec = bytes[i..][0..chunk_len].*;
        total += @popCount(@as(u64, @bitCast(v == @as(Vec, @splat(quote)))));
    }
    while (i < bytes.len) : (i += 1) total += @intFromBool(bytes[i] == quote);
    return total;
}

/// The first record start at or after `from`, given whether `from` lies inside a
/// quoted field (`in_quote`, from the quote-count prefix). Returns `input.len` if no
/// record starts at or after `from`. A cut between the `\r` and `\n` of a CRLF moves
/// past the `\n`, never splitting the terminator.
pub fn recordStartAfter(input: []const u8, from: usize, in_quote: bool, opts: Options) usize {
    assert(from <= input.len);
    if (from == 0) return 0;
    if (from == input.len) return input.len;
    if (!in_quote) {
        // `from` already starts a record if the byte before it ended one (outside quotes,
        // since the state after a terminator equals the state before it).
        const prev = input[from - 1];
        if (prev == '\n' or (prev == '\r' and input[from] != '\n')) return from;
    }
    var carry: u64 = if (in_quote) ~@as(u64, 0) else 0;
    var base = from;
    while (base < input.len) : (base += chunk_len) {
        const t = classify.terminatorsAt(input, base, opts, &carry);
        if (t != 0) {
            const at = base + @ctz(t);
            if (input[at] == '\r' and at + 1 < input.len and input[at + 1] == '\n') return at + 2;
            return at + 1;
        }
    }
    return input.len;
}

/// Split `input` into `bounds.len - 1` ranges that each begin at a record start:
/// `bounds[0] = 0`, `bounds[last] = input.len`, non-decreasing (a range is empty when
/// one record spans its whole cut). Ranges are cut near equal byte offsets. An odd
/// total number of quotes means a quoted field never closes: `UnterminatedQuote`.
/// This is the serial reference of the two-phase algorithm described above.
pub fn splitRecords(input: []const u8, opts: Options, bounds: []usize) Error!void {
    try opts.validate();
    assert(bounds.len >= 2);
    const n = bounds.len - 1;
    // Phase 1 (parallel per range in a driver): quote count of each raw range.
    // Phase 2: prefix parity at each cut, then the record start after it.
    var quotes_before: u64 = 0;
    var prev_cut: usize = 0;
    bounds[0] = 0;
    for (1..n) |i| {
        const cut = rawCut(input.len, n, i);
        quotes_before += countQuotes(input[prev_cut..cut], opts.quote);
        prev_cut = cut;
        const start = recordStartAfter(input, cut, quotes_before % 2 == 1, opts);
        bounds[i] = @max(start, bounds[i - 1]);
    }
    quotes_before += countQuotes(input[prev_cut..], opts.quote);
    if (quotes_before % 2 == 1) return Error.UnterminatedQuote;
    bounds[n] = input.len;
}

/// Byte offset of raw cut `i` of `n` (before snapping to a record start).
pub fn rawCut(len: usize, n: usize, i: usize) usize {
    return @intCast(@as(u128, len) * i / n);
}

/// Most workers `forEachField` accepts (its bookkeeping lives on the stack).
pub const max_workers = 256;

/// Parallel push parse: split `input` into `ctxs.len` ranges at record starts and run
/// `simd.forEachField` over each on the caller's `io`, one task per range. Range `i`'s
/// fields go, in order, to `onField(ctxs[i], …)` with `scratches[i]` for unescaping, so
/// concatenating the sinks' output in index order is exactly the serial field
/// sequence. Workers run concurrently only if `io` provides concurrency (e.g.
/// `std.Io.Threaded`); zsift itself starts no threads and allocates nothing.
///
/// Keep each sink on its own cache line (`align(std.atomic.cache_line)`): workers write
/// their sinks on every field, and sinks packed side by side made the parallel path
/// slower than the serial one in measurement (false sharing).
///
/// On error, the error of the earliest range that failed is returned — the same error
/// a serial parse reports, since every range before the first defect is cut exactly.
/// Sinks may already hold fields from any range when an error is returned.
pub fn forEachField(
    io: std.Io,
    input: []const u8,
    opts: Options,
    scratches: []const []u8,
    ctxs: anytype,
    comptime onField: fn (std.meta.Elem(@TypeOf(ctxs)), bytes: []const u8, last_in_record: bool) void,
) (Error || std.Io.Cancelable)!void {
    try opts.validate();
    const n = ctxs.len;
    if (n == 0 or n > max_workers or scratches.len != n) return Error.BadWorkerCount;
    if (n == 1) return simd.forEachField(input, scratches[0], opts, ctxs[0], onField);

    const Ctx = std.meta.Elem(@TypeOf(ctxs));
    const Task = struct {
        fn count(out: *u64, bytes: []const u8, quote: u8) void {
            out.* = countQuotes(bytes, quote);
        }
        fn start(out: *usize, text: []const u8, from: usize, in_quote: bool, o: Options) void {
            out.* = recordStartAfter(text, from, in_quote, o);
        }
        fn parse(out: *?Error, bytes: []const u8, scratch: []u8, o: Options, ctx: Ctx) void {
            simd.forEachField(bytes, scratch, o, ctx, onField) catch |e| {
                out.* = e;
            };
        }
    };

    // Phase 1: quote count of each raw range.
    var counts: [max_workers]u64 = undefined;
    {
        var g: std.Io.Group = .init;
        for (0..n) |i| g.async(io, Task.count, .{ &counts[i], input[rawCut(input.len, n, i)..rawCut(input.len, n, i + 1)], opts.quote });
        try g.await(io);
    }
    // Phase 2: prefix parity at each cut, then the record start after it. An odd total
    // is not returned here: the range holding the open quote reports it, so an earlier
    // defect keeps its place in the error order.
    var bounds: [max_workers + 1]usize = undefined;
    {
        var g: std.Io.Group = .init;
        var quotes_before: u64 = 0;
        bounds[0] = 0;
        for (1..n) |i| {
            quotes_before += counts[i - 1];
            g.async(io, Task.start, .{ &bounds[i], input, rawCut(input.len, n, i), quotes_before % 2 == 1, opts });
        }
        try g.await(io);
        for (1..n) |i| bounds[i] = @max(bounds[i], bounds[i - 1]);
        bounds[n] = input.len;
    }
    // Phase 3: parse every range.
    var errs: [max_workers]?Error = @splat(null);
    {
        var g: std.Io.Group = .init;
        for (0..n) |i| g.async(io, Task.parse, .{ &errs[i], input[bounds[i]..bounds[i + 1]], scratches[i], opts, ctxs[i] });
        try g.await(io);
    }
    for (errs[0..n]) |e| if (e) |err| return err;
}
