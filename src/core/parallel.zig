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
//! `splitRecords` runs both phases serially; a parallel driver runs the same functions
//! on several workers. Invalid quoting is not detected here: the parser that consumes
//! each range reports it (`classify.quoteViolation`).

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
