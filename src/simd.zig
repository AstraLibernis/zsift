//! SIMD fast-path CSV parser.
//!
//! Same zero-allocation, pull-based contract as the scalar `csv.Parser`, but the
//! structural scan is vectorized in 64-byte chunks following the simdjson/simdcsv
//! approach (Langdale & Lemire):
//!
//!   1. Compare 64 input bytes against `"`, the delimiter, `\n`, `\r` in
//!      parallel; `@bitCast` each `@Vector(64, bool)` result to a `u64` (this
//!      lowers to a movemask on x86, a shrn trick on aarch64).
//!   2. Turn the quote bitmask into an "inside a quoted region" mask with a
//!      parallel prefix-XOR. We use the portable 6× shift-XOR doubling instead
//!      of `PCLMULQDQ` (Zig has no carry-less-multiply builtin, and shift-XOR is
//!      branchless and works on every target).
//!   3. Real structure = (delimiter | `\n` | `\r`) AND NOT inside-quote. We then
//!      pop those bits lowest-first with `@ctz`, emitting one field per bit —
//!      no structural-index array, so this stays allocation-free.
//!
//! Escaped quotes (`""`) need no special case for *structure*: in the prefix-XOR
//! they toggle the region off then immediately on again, so no separator between
//! them is ever exposed. We collapse `""` only when materializing a quoted field.
//!
//! IMPORTANT — this parser assumes RFC 4180-strict quoting: a field containing a
//! quote must be fully quoted. Unlike the scalar parser, a bare quote in the
//! middle of an unquoted field is NOT treated as literal data here; the
//! prefix-XOR would mask the rest of the input as in-string. Use `csv.Parser`
//! for lenient input.

const std = @import("std");
const types = @import("types.zig");

pub const Options = types.Options;
pub const Error = types.Error;
pub const Field = types.Field;

const chunk_len = 64;
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

/// Structural-scan ceiling: classify every chunk and count the field/record
/// separators, doing no per-field work. This is the upper bound on what the
/// vectorized pass can deliver; the gap between this and `SimdParser` throughput
/// is the cost of the pull API plus quote materialization. Benchmark aid only.
pub fn countSeparators(input: []const u8, opts: Options) u64 {
    var base: usize = 0;
    var carry: u64 = 0;
    var total: u64 = 0;
    while (base < input.len) : (base += chunk_len) {
        const n = @min(input.len - base, chunk_len);
        var buf: [chunk_len]u8 = @splat(0);
        @memcpy(buf[0..n], input[base..][0..n]);
        const v: Vec = buf;
        const quote_bits: u64 = @bitCast(v == @as(Vec, @splat(opts.quote)));
        const delim_bits: u64 = @bitCast(v == @as(Vec, @splat(opts.delimiter)));
        const lf_bits: u64 = @bitCast(v == @as(Vec, @splat('\n')));
        const cr_bits: u64 = @bitCast(v == @as(Vec, @splat('\r')));
        const inside = prefixXor(quote_bits) ^ carry;
        carry = @bitCast(@as(i64, @bitCast(inside)) >> 63);
        total += @popCount((delim_bits | lf_bits | cr_bits) & ~inside);
    }
    return total;
}

/// Materialize one field into `scratch[0..]` (per call, not cumulative). The
/// returned slice is valid until the next call. Used by the callback API, where
/// each field is consumed synchronously before the next is produced.
fn materializeInto(raw: []const u8, quote: u8, scratch: []u8) Error![]const u8 {
    if (raw.len == 0 or raw[0] != quote) return raw;
    if (raw.len < 2 or raw[raw.len - 1] != quote) return Error.UnterminatedQuote;
    const inner = raw[1 .. raw.len - 1];
    if (std.mem.indexOfScalar(u8, inner, quote) == null) return inner;
    if (scratch.len < inner.len) return Error.ScratchTooSmall;
    var w: usize = 0;
    var j: usize = 0;
    while (j < inner.len) {
        scratch[w] = inner[j];
        w += 1;
        j += if (inner[j] == quote) 2 else 1;
    }
    return scratch[0..w];
}

/// Push-style fast path: classify in 64-byte chunks and invoke `onField` for
/// every field, fully inlined, with no per-field `next()` call overhead. This is
/// how the GB/s parsers actually consume their structure. `ctx` is threaded to
/// the callback so it can accumulate without globals. Still zero-allocation.
///
/// `onField(ctx, bytes, last_in_record)` is called once per field in order. The
/// `bytes` slice is valid only for the duration of the call.
pub fn forEachField(
    input: []const u8,
    scratch: []u8,
    opts: Options,
    ctx: anytype,
    comptime onField: fn (@TypeOf(ctx), bytes: []const u8, last_in_record: bool) void,
) Error!void {
    const quote = opts.quote;
    const delim = opts.delimiter;
    var field_start: usize = 0;
    var carry: u64 = 0;
    var base: usize = 0;
    while (base < input.len) : (base += chunk_len) {
        const n = @min(input.len - base, chunk_len);
        var buf: [chunk_len]u8 = @splat(0);
        @memcpy(buf[0..n], input[base..][0..n]);
        const v: Vec = buf;
        const quote_bits: u64 = @bitCast(v == @as(Vec, @splat(quote)));
        const delim_bits: u64 = @bitCast(v == @as(Vec, @splat(delim)));
        const lf_bits: u64 = @bitCast(v == @as(Vec, @splat('\n')));
        const cr_bits: u64 = @bitCast(v == @as(Vec, @splat('\r')));
        const inside = prefixXor(quote_bits) ^ carry;
        carry = @bitCast(@as(i64, @bitCast(inside)) >> 63);

        var s = (delim_bits | lf_bits | cr_bits) & ~inside;
        while (s != 0) {
            const rel: usize = @ctz(s);
            s &= s - 1;
            const at = base + rel;
            if (at < field_start) continue; // trailing '\n' of a CRLF
            const c = input[at];
            const value = try materializeInto(input[field_start..at], quote, scratch);
            if (c == delim) {
                field_start = at + 1;
                onField(ctx, value, false);
            } else {
                field_start = if (c == '\r' and at + 1 < input.len and input[at + 1] == '\n')
                    at + 2
                else
                    at + 1;
                onField(ctx, value, true);
            }
        }
    }
    // Final field when input does not end on a record terminator.
    if (field_start < input.len) {
        const value = try materializeInto(input[field_start..], quote, scratch);
        onField(ctx, value, true);
    }
}

pub const SimdParser = struct {
    input: []const u8,
    scratch: []u8,
    scratch_used: usize,
    opts: Options,

    /// Absolute offset where the current field begins.
    field_start: usize,
    /// Absolute offset of the chunk currently held in `structural`.
    scan_base: usize,
    /// Absolute offset of the next chunk to classify.
    next_base: usize,
    /// Remaining separator bits of the current chunk (consumed bits cleared).
    structural: u64,
    /// 0 or ~0: whether the *next* chunk begins inside a quoted region.
    carry: u64,
    /// True once the final field has been emitted.
    finished: bool,

    pub fn init(input: []const u8, scratch: []u8, opts: Options) SimdParser {
        return .{
            .input = input,
            .scratch = scratch,
            .scratch_used = 0,
            .opts = opts,
            .field_start = 0,
            .scan_base = 0,
            .next_base = 0,
            .structural = 0,
            .carry = 0,
            .finished = false,
        };
    }

    pub fn resetScratch(self: *SimdParser) void {
        self.scratch_used = 0;
    }

    /// Classify the next 64-byte chunk (zero-padded at EOF) into `structural`.
    fn loadChunk(self: *SimdParser) void {
        const base = self.next_base;
        const remaining = self.input.len - base;
        const n = @min(remaining, chunk_len);

        var buf: [chunk_len]u8 = @splat(0);
        @memcpy(buf[0..n], self.input[base..][0..n]);
        const v: Vec = buf;

        const quote_bits: u64 = @bitCast(v == @as(Vec, @splat(self.opts.quote)));
        const delim_bits: u64 = @bitCast(v == @as(Vec, @splat(self.opts.delimiter)));
        const lf_bits: u64 = @bitCast(v == @as(Vec, @splat('\n')));
        const cr_bits: u64 = @bitCast(v == @as(Vec, @splat('\r')));

        const inside = prefixXor(quote_bits) ^ self.carry;
        // Broadcast the top bit: are we still inside a quote at the chunk's end?
        self.carry = @bitCast(@as(i64, @bitCast(inside)) >> 63);

        // Separators outside quoted regions. Padding bytes are 0, so they never
        // match a separator and contribute no spurious bits.
        self.structural = (delim_bits | lf_bits | cr_bits) & ~inside;
        self.scan_base = base;
        self.next_base = base + chunk_len;
    }

    /// Turn a raw field slice into its value: unquoted fields are returned as-is
    /// (zero-copy); quoted fields have their surrounding quotes stripped and any
    /// `""` collapsed (zero-copy if there are none, else into scratch).
    fn materialize(self: *SimdParser, raw: []const u8) Error![]const u8 {
        const quote = self.opts.quote;
        if (raw.len == 0 or raw[0] != quote) return raw;
        if (raw.len < 2 or raw[raw.len - 1] != quote) return Error.UnterminatedQuote;

        const inner = raw[1 .. raw.len - 1];
        if (std.mem.indexOfScalar(u8, inner, quote) == null) return inner;

        const dst = self.scratch[self.scratch_used..];
        if (dst.len < inner.len) return Error.ScratchTooSmall;
        var w: usize = 0;
        var j: usize = 0;
        while (j < inner.len) {
            dst[w] = inner[j];
            w += 1;
            // A quote in `inner` is always the first of an escaped pair.
            j += if (inner[j] == quote) 2 else 1;
        }
        self.scratch_used += w;
        return dst[0..w];
    }

    pub fn next(self: *SimdParser) Error!?Field {
        while (true) {
            if (self.structural != 0) {
                const rel: usize = @ctz(self.structural);
                self.structural &= self.structural - 1; // clear lowest set bit
                const at = self.scan_base + rel;
                // The trailing '\n' of a CRLF sits before field_start; skip it.
                if (at < self.field_start) continue;

                const c = self.input[at];
                const value = try self.materialize(self.input[self.field_start..at]);
                if (c == self.opts.delimiter) {
                    self.field_start = at + 1;
                    return .{ .bytes = value, .last_in_record = false };
                }
                // record terminator: '\n', '\r', or "\r\n"
                self.field_start =
                    if (c == '\r' and at + 1 < self.input.len and self.input[at + 1] == '\n')
                        at + 2
                    else
                        at + 1;
                return .{ .bytes = value, .last_in_record = true };
            }

            if (self.next_base >= self.input.len) {
                if (self.finished) return null;
                self.finished = true;
                // A field_start sitting exactly at EOF means the last byte was a
                // record terminator: no phantom trailing record.
                if (self.field_start >= self.input.len) return null;
                const value = try self.materialize(self.input[self.field_start..self.input.len]);
                return .{ .bytes = value, .last_in_record = true };
            }
            self.loadChunk();
        }
    }

    pub fn nextRecord(self: *SimdParser, dst: [][]const u8) Error!?[]const []const u8 {
        self.resetScratch();
        var n: usize = 0;
        while (true) {
            const f = try self.next() orelse {
                if (n == 0) return null;
                break; // input ended mid-record (no trailing newline)
            };
            if (n >= dst.len) return Error.TooManyFields;
            dst[n] = f.bytes;
            n += 1;
            if (f.last_in_record) break;
        }
        return dst[0..n];
    }
};
