//! SIMD fast-path parsers, built on the chunk classifier in `classify.zig`.
//!
//! Two front-ends over the same vectorized structural scan:
//!   * `forEachField` — push: classify each 64-byte chunk, pop separator bits
//!     lowest-first with `@ctz`, and invoke a callback per field. Fully inlined,
//!     no per-field call overhead.
//!   * `SimdParser` — pull: the same scan exposed as a `next()`/`nextRecord()`
//!     iterator, classifying one chunk on demand.
//! Both are zero-allocation; `""` is collapsed only when a quoted field is
//! materialized (`unescapeInto`).
//!
//! IMPORTANT — these assume RFC 4180-strict quoting: a field containing a quote
//! must be fully quoted. Unlike the scalar parser, a bare quote in the middle of
//! an unquoted field is NOT treated as literal here (the prefix-XOR would mask
//! the rest of the input as in-string). Use the scalar `Parser` for lenient input.

const std = @import("std");
const types = @import("types.zig");

pub const Options = types.Options;
pub const Error = types.Error;
pub const Field = types.Field;

const classify = @import("classify.zig");
const classifyAt = classify.classifyAt;
const classifyAtFull = classify.classifyAtFull;
const chunk_len = classify.chunk_len;

/// Prefix popcount: number of quote bits at positions [0, rel) of a chunk mask.
/// Added to a running cross-chunk total this gives "quotes up to a position", so a
/// field's escape status is `(quotes_up_to(end) - quotes_up_to(start)) > 2` — its
/// two bookend quotes plus any escaped `""`. Works across chunks; no byte re-scan.
inline fn quotesBelow(q: u64, rel: usize) u64 {
    const below: u64 = (@as(u64, 1) << @intCast(rel)) -% 1;
    return @popCount(q & below);
}

/// SWAR "index of byte `b` in `s` at/after `start`", or null (classic haszero).
/// Finds the run boundaries for the collapse copy faster than a per-call
/// vectorized search when runs are short — the escaped-field case.
inline fn swarIndexOfPos(s: []const u8, start: usize, b: u8) ?usize {
    const ONES: u64 = 0x0101010101010101;
    const HIGH: u64 = 0x8080808080808080;
    const pat: u64 = ONES *% b;
    var i: usize = start;
    while (i + 8 <= s.len) : (i += 8) {
        const w = std.mem.readInt(u64, s[i..][0..8], .little);
        const x = w ^ pat;
        const hz = (x -% ONES) & ~x & HIGH;
        if (hz != 0) return i + (@ctz(hz) >> 3);
    }
    while (i < s.len) : (i += 1) if (s[i] == b) return i;
    return null;
}

/// Given a separator at `at`, return where the next field starts and whether this
/// separator ends a record. A delimiter continues the record (`last = false`);
/// `\n`, `\r`, or `\r\n` end it. A trailing empty field is owed when `!last`.
inline fn recordStep(input: []const u8, at: usize, delim: u8) struct { next_start: usize, last: bool } {
    if (input[at] == delim) return .{ .next_start = at + 1, .last = false };
    const ns = if (input[at] == '\r' and at + 1 < input.len and input[at + 1] == '\n') at + 2 else at + 1;
    return .{ .next_start = ns, .last = true };
}

/// Core quoted-field unescaping. An unquoted field, or a quoted field with no
/// interior `""` (`needs == false`), returns a zero-copy slice with `written == 0`;
/// a field with an escaped `""` is collapsed into `dst`, the byte count reported so
/// callers can advance a scratch cursor.
///
/// `needs` is the escape decision precomputed from the SIMD quote mask (a running
/// cross-chunk quote count; see `forEachField`/`SimdParser`), so no byte re-scan is
/// needed. The collapse copies clean runs with `@memcpy` (run boundaries found by
/// `swarIndexOfPos`), emitting one quote per escaped pair.
fn unescapeInto(raw: []const u8, quote: u8, dst: []u8, needs: bool) Error!struct { value: []const u8, written: usize } {
    if (raw.len == 0 or raw[0] != quote) return .{ .value = raw, .written = 0 };
    if (raw.len < 2 or raw[raw.len - 1] != quote) return Error.UnterminatedQuote;
    const inner = raw[1 .. raw.len - 1];
    if (!needs) return .{ .value = inner, .written = 0 };
    if (dst.len < inner.len) return Error.ScratchTooSmall;
    var w: usize = 0;
    var j: usize = 0;
    while (j < inner.len) {
        const nq = swarIndexOfPos(inner, j, quote) orelse inner.len;
        const run = nq - j;
        @memcpy(dst[w..][0..run], inner[j..][0..run]);
        w += run;
        if (nq == inner.len) break;
        dst[w] = quote; // one quote per escaped pair
        w += 1;
        j = nq + 2;
    }
    return .{ .value = dst[0..w], .written = w };
}

/// Structural-scan ceiling: classify every chunk and count the field/record
/// separators, doing no per-field work. This is the upper bound on what the
/// vectorized pass can deliver; the gap between this and `SimdParser` throughput
/// is the cost of the pull API plus quote materialization. Benchmark aid only.
pub fn countSeparators(input: []const u8, opts: Options) u64 {
    var carry: u64 = 0;
    var total: u64 = 0;
    var base: usize = 0;
    while (base < input.len) : (base += chunk_len) {
        total += @popCount(classifyAt(input, base, opts, &carry));
    }
    return total;
}

/// Materialize one field into `scratch[0..]` (per call, not cumulative). The
/// returned slice is valid until the next call. Used by the callback API, where
/// each field is consumed synchronously before the next is produced.
fn materializeInto(raw: []const u8, quote: u8, scratch: []u8, needs: bool) Error![]const u8 {
    return (try unescapeInto(raw, quote, scratch, needs)).value;
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
    var pending = false; // last separator was a delimiter → a field is owed
    // Running quote counts for escape detection without a re-scan: `qbc` counts
    // quote bits in chunks before `base`, `fs_q` counts them up to `field_start`.
    // A field needs collapsing iff more than its two bookend quotes lie in it.
    var qbc: u64 = 0;
    var fs_q: u64 = 0;
    while (base < input.len) : (base += chunk_len) {
        const cl = classifyAtFull(input, base, opts, &carry);
        var s = cl.seps;
        // A chunk with no quote bytes can hold no escape, so `quotes_up_to` is just
        // the running `qbc` — skip the per-field popcount (keeps clean data at parity).
        const has_q = cl.quotes != 0;
        while (s != 0) {
            const rel: usize = @ctz(s);
            s &= s - 1;
            const at = base + rel;
            if (at < field_start) continue; // trailing '\n' of a CRLF
            var needs = false;
            if (input[field_start] == quote) {
                // Only a quoted field can need collapsing. Unquoted fields skip this
                // entirely (clean-data parity) and leave the running counts unchanged,
                // since they contribute no quotes between two field starts.
                const q_up_to = if (has_q) qbc + quotesBelow(cl.quotes, rel) else qbc;
                needs = (q_up_to - fs_q) > 2;
                fs_q = q_up_to;
            }
            const value = try materializeInto(input[field_start..at], quote, scratch, needs);
            const step = recordStep(input, at, delim);
            field_start = step.next_start;
            pending = !step.last;
            onField(ctx, value, step.last);
        }
        if (has_q) qbc += @popCount(cl.quotes);
    }
    if (field_start < input.len) {
        // Final field with no terminator: `qbc` now counts every quote in the input.
        const needs = input[field_start] == quote and (qbc - fs_q) > 2;
        const value = try materializeInto(input[field_start..], quote, scratch, needs);
        onField(ctx, value, true);
    } else if (pending) {
        // Input ended on a delimiter: emit the owed trailing empty field.
        onField(ctx, input[input.len..], true);
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
    /// Quote bitmask of the chunk at `scan_base` — for per-field escape detection
    /// without a byte re-scan.
    quotes: u64,
    /// Cumulative quote bits in chunks before `scan_base`.
    quotes_before: u64,
    /// Cumulative quote bits up to `field_start`; the per-field escape test is
    /// `quotes_up_to(at) - field_quotes > 2`.
    field_quotes: u64,
    /// 0 or ~0: whether the *next* chunk begins inside a quoted region.
    carry: u64,
    /// True once the final field has been emitted.
    finished: bool,
    /// True when the last separator consumed was a delimiter, so a final empty
    /// field is owed even if the input ends here (`"a,"` is `["a", ""]`).
    pending: bool,

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
            .quotes = 0,
            .quotes_before = 0,
            .field_quotes = 0,
            .carry = 0,
            .finished = false,
            .pending = false,
        };
    }

    pub fn resetScratch(self: *SimdParser) void {
        self.scratch_used = 0;
    }

    /// Classify the next 64-byte chunk (zero-padded at EOF) into `structural`.
    fn loadChunk(self: *SimdParser) void {
        self.quotes_before += @popCount(self.quotes); // finalize the chunk being left
        const cl = classifyAtFull(self.input, self.next_base, self.opts, &self.carry);
        self.structural = cl.seps;
        self.quotes = cl.quotes;
        self.scan_base = self.next_base;
        self.next_base += chunk_len;
    }

    /// Turn a raw field slice into its value (see `unescapeInto`), advancing the
    /// cumulative scratch cursor so multiple unescaped fields of one record stay
    /// valid together.
    fn materialize(self: *SimdParser, raw: []const u8, needs: bool) Error![]const u8 {
        const r = try unescapeInto(raw, self.opts.quote, self.scratch[self.scratch_used..], needs);
        self.scratch_used += r.written;
        return r.value;
    }

    pub fn next(self: *SimdParser) Error!?Field {
        while (true) {
            if (self.structural != 0) {
                const rel: usize = @ctz(self.structural);
                self.structural &= self.structural - 1; // clear lowest set bit
                const at = self.scan_base + rel;
                // The trailing '\n' of a CRLF sits before field_start; skip it.
                if (at < self.field_start) continue;

                var needs = false;
                if (self.input[self.field_start] == self.opts.quote) {
                    const q_up_to = if (self.quotes != 0) self.quotes_before + quotesBelow(self.quotes, rel) else self.quotes_before;
                    needs = (q_up_to - self.field_quotes) > 2;
                    self.field_quotes = q_up_to;
                }
                const value = try self.materialize(self.input[self.field_start..at], needs);
                const step = recordStep(self.input, at, self.opts.delimiter);
                self.field_start = step.next_start;
                self.pending = !step.last;
                return .{ .bytes = value, .last_in_record = step.last };
            }

            if (self.next_base >= self.input.len) {
                if (self.finished) return null;
                // A real final field (input did not end on a terminator).
                if (self.field_start < self.input.len) {
                    self.finished = true;
                    const needs = self.input[self.field_start] == self.opts.quote and
                        (self.quotes_before + @popCount(self.quotes) - self.field_quotes) > 2;
                    const value = try self.materialize(self.input[self.field_start..self.input.len], needs);
                    return .{ .bytes = value, .last_in_record = true };
                }
                // field_start sits at EOF: emit a trailing empty field only if the
                // last byte was a delimiter; otherwise no phantom record.
                self.finished = true;
                if (self.pending) {
                    self.pending = false;
                    return .{ .bytes = self.input[self.input.len..], .last_in_record = true };
                }
                return null;
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

    /// Batched pull: fill `dst` with up to `dst.len` fields and return the count
    /// (0 at end of input). Same semantics as calling `next()` repeatedly, but the
    /// hot scan state lives in locals for the whole batch and is written back to the
    /// struct only once — amortizing the per-field state round-trip `next()` pays.
    /// Scratch is cumulative across the batch (as with a record); call `resetScratch`
    /// between batches, or size scratch to hold a batch's unescaped bytes.
    pub fn nextInto(self: *SimdParser, dst: []Field) Error!usize {
        const quote = self.opts.quote;
        const delim = self.opts.delimiter;
        var structural = self.structural;
        var quotes = self.quotes;
        var quotes_before = self.quotes_before;
        var field_quotes = self.field_quotes;
        var carry = self.carry;
        var field_start = self.field_start;
        var scan_base = self.scan_base;
        var next_base = self.next_base;
        var scratch_used = self.scratch_used;
        var finished = self.finished;
        var pending = self.pending;
        var n: usize = 0;
        while (n < dst.len) {
            if (structural != 0) {
                const rel: usize = @ctz(structural);
                structural &= structural - 1;
                const at = scan_base + rel;
                if (at < field_start) continue; // trailing '\n' of a CRLF
                var needs = false;
                if (self.input[field_start] == quote) {
                    const q_up_to = if (quotes != 0) quotes_before + quotesBelow(quotes, rel) else quotes_before;
                    needs = (q_up_to - field_quotes) > 2;
                    field_quotes = q_up_to;
                }
                const r = try unescapeInto(self.input[field_start..at], quote, self.scratch[scratch_used..], needs);
                scratch_used += r.written;
                const step = recordStep(self.input, at, delim);
                field_start = step.next_start;
                pending = !step.last;
                dst[n] = .{ .bytes = r.value, .last_in_record = step.last };
                n += 1;
                continue;
            }
            if (next_base >= self.input.len) {
                if (finished) break;
                if (field_start < self.input.len) {
                    finished = true;
                    const needs = self.input[field_start] == quote and
                        (quotes_before + @popCount(quotes) - field_quotes) > 2;
                    const r = try unescapeInto(self.input[field_start..self.input.len], quote, self.scratch[scratch_used..], needs);
                    scratch_used += r.written;
                    dst[n] = .{ .bytes = r.value, .last_in_record = true };
                    n += 1;
                    continue;
                }
                finished = true;
                if (pending) {
                    pending = false;
                    dst[n] = .{ .bytes = self.input[self.input.len..], .last_in_record = true };
                    n += 1;
                }
                break;
            }
            // loadChunk, inline (keeps state in locals)
            quotes_before += @popCount(quotes);
            const cl = classifyAtFull(self.input, next_base, self.opts, &carry);
            structural = cl.seps;
            quotes = cl.quotes;
            scan_base = next_base;
            next_base += chunk_len;
        }
        self.structural = structural;
        self.quotes = quotes;
        self.quotes_before = quotes_before;
        self.field_quotes = field_quotes;
        self.carry = carry;
        self.field_start = field_start;
        self.scan_base = scan_base;
        self.next_base = next_base;
        self.scratch_used = scratch_used;
        self.finished = finished;
        self.pending = pending;
        return n;
    }
};
