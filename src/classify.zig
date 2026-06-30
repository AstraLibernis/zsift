//! SIMD chunk-classification primitives — the vector layer the parsers build on.
//!
//! Each helper works on a 64-byte chunk (`@Vector(64, u8)`) following the
//! simdjson/simdcsv approach (Langdale & Lemire): compare bytes in parallel and
//! `@bitCast` each `@Vector(64, bool)` result to a `u64` (lowers to a movemask on
//! x86), then turn the quote bitmask into an "inside a quoted region" mask with a
//! parallel prefix-XOR. The prefix-XOR uses the portable 6× shift-XOR doubling,
//! not `PCLMULQDQ` (Zig has no carry-less-multiply builtin, and shift-XOR is
//! branchless and works on every target). The in-quote state is threaded across
//! chunk boundaries via `carry` (0 or ~0).
//!
//! Escaped `""` needs no special case for *structure*: in the prefix-XOR it
//! toggles the region off then immediately on again, so no separator between the
//! pair is ever exposed.

const Options = @import("types.zig").Options;

pub const chunk_len = 64;
const Vec = @Vector(chunk_len, u8);

/// Parallel prefix-XOR (inclusive scan) of a 64-bit mask: output bit i is the XOR
/// of input bits 0..=i. Equivalent to the low word of a carry-less multiply by
/// all-ones, but portable. After this, a bit is set wherever an odd number of
/// quotes lie at or before it — i.e. "inside a quoted region".
inline fn prefixXor(x: u64) u64 {
    var r = x;
    r ^= r << 1;
    r ^= r << 2;
    r ^= r << 4;
    r ^= r << 8;
    r ^= r << 16;
    r ^= r << 32;
    return r;
}

/// Load the chunk at `base`: a full 64 bytes directly (no copy) when available,
/// otherwise the final short chunk zero-padded. Avoids a per-chunk memset+memcpy
/// that otherwise dominates classification cost; padding bytes are 0, so they
/// never match a separator.
inline fn loadVec(input: []const u8, base: usize) Vec {
    if (base + chunk_len <= input.len) return input[base..][0..chunk_len].*;
    var buf: [chunk_len]u8 = @splat(0);
    @memcpy(buf[0 .. input.len - base], input[base..]);
    return buf;
}

/// "Inside a quoted region" bitmask for `v`, folding the end-of-chunk in-quote
/// state into `carry` (0 or ~0). Single source of the prefix-XOR + carry logic.
inline fn quoteInsideMask(v: Vec, quote: u8, carry: *u64) u64 {
    const quote_bits: u64 = @bitCast(v == @as(Vec, @splat(quote)));
    const inside = prefixXor(quote_bits) ^ carry.*;
    carry.* = @bitCast(@as(i64, @bitCast(inside)) >> 63);
    return inside;
}

/// Field/record separators (delimiter, `\n`, `\r`) outside quoted regions, for
/// the chunk at `base`.
pub inline fn classifyAt(input: []const u8, base: usize, opts: Options, carry: *u64) u64 {
    const v = loadVec(input, base);
    const inside = quoteInsideMask(v, opts.quote, carry);
    const delim_bits: u64 = @bitCast(v == @as(Vec, @splat(opts.delimiter)));
    const lf_bits: u64 = @bitCast(v == @as(Vec, @splat('\n')));
    const cr_bits: u64 = @bitCast(v == @as(Vec, @splat('\r')));
    return (delim_bits | lf_bits | cr_bits) & ~inside;
}

/// Record terminators (`\n`, `\r`) outside quoted regions, for the chunk at
/// `base`. Used by streaming to find record boundaries without a separate scalar
/// pass. (Delimiters are excluded — a record ends only on a newline.)
pub inline fn terminatorsAt(input: []const u8, base: usize, opts: Options, carry: *u64) u64 {
    const v = loadVec(input, base);
    const inside = quoteInsideMask(v, opts.quote, carry);
    const lf_bits: u64 = @bitCast(v == @as(Vec, @splat('\n')));
    const cr_bits: u64 = @bitCast(v == @as(Vec, @splat('\r')));
    return (lf_bits | cr_bits) & ~inside;
}
