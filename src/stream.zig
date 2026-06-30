//! Streaming CSV over a `std.Io.Reader`, plus an auto-selecting facade that
//! picks between slurp-into-memory and streaming based on input size.
//!
//! Streaming model: the 0.16 `Reader` already maintains a sliding window
//! (`buffer` / `seek` / `end`). We process the largest prefix of the window that
//! consists of *whole records*, in one batched `forEachField` pass (so SIMD
//! amortizes over many records, not one), then `toss` that prefix and let the
//! reader refill. Because we only ever consume up to a record boundary, every
//! refill begins outside any quoted region — so no quote state has to cross a
//! refill, only a re-scan of the small leftover partial record.
//!
//! Field lifetime: fields handed to the callback are valid only for the duration
//! of that call (the reader buffer is reused on the next refill). This matches
//! every streaming CSV reader (Go's `ReuseRecord`, etc.).
//!
//! Like the SIMD parser, streaming assumes RFC 4180-strict quoting. The window
//! must be larger than the longest record; a record that fills the entire window
//! with no terminator yields `error.RecordTooLong`.

const std = @import("std");
const types = @import("types.zig");
const simd = @import("simd.zig");

const Reader = std.Io.Reader;

pub const Options = types.Options;
pub const Error = types.Error;

pub const StreamError = Error || error{
    /// The underlying reader failed.
    ReadFailed,
    /// A single record is larger than the reader's buffer (window).
    RecordTooLong,
};

/// Length of the largest prefix of `window` that consists of whole records:
/// the index one past the last record terminator lying outside a quoted region.
/// Returns 0 when the window holds no complete record.
///
/// Strict quoting: a quote toggles the in/out-of-quotes state; escaped `""` is
/// two toggles, so it preserves parity. A terminator only ends a record when the
/// running quote count is even (we are outside quotes). A lone `\r` at the very
/// end of the window is left for the next refill (it may be a split `\r\n`).
pub fn completeRecordsLen(window: []const u8, opts: Options) usize {
    var last: usize = 0;
    var quotes: usize = 0;
    var i: usize = 0;
    while (i < window.len) : (i += 1) {
        const c = window[i];
        if (c == opts.quote) {
            quotes += 1;
        } else if (quotes & 1 == 0) {
            if (c == '\n') {
                last = i + 1;
            } else if (c == '\r') {
                if (i + 1 < window.len) {
                    if (window[i + 1] == '\n') {
                        last = i + 2;
                        i += 1;
                    } else {
                        last = i + 1;
                    }
                } else break; // trailing '\r' — defer to the next refill
            }
        }
    }
    return last;
}

/// Push every field of the CSV stream to `onField(ctx, bytes, last_in_record)`,
/// reading from `r` in windows. `scratch` holds unescaped (`""`) field bytes and
/// must be at least as large as the longest field; sizing it to the reader's
/// buffer length is always safe.
pub fn streamReader(
    r: *Reader,
    scratch: []u8,
    opts: Options,
    ctx: anytype,
    comptime onField: fn (@TypeOf(ctx), bytes: []const u8, last_in_record: bool) void,
) StreamError!void {
    while (true) {
        const window = r.buffered();
        const boundary = completeRecordsLen(window, opts);
        if (boundary > 0) {
            try simd.forEachField(window[0..boundary], scratch, opts, ctx, onField);
            r.toss(boundary);
            continue;
        }
        // No complete record buffered. If the buffer is full we cannot fillMore
        // (the reader's rebase would assert), so probe one byte beyond it — read
        // into our own tiny buffer, which leaves the window untouched — to tell a
        // genuinely over-long record (more bytes follow) from a complete final
        // record that merely fills the window exactly (EOF here).
        if (r.bufferedLen() == r.buffer.len) {
            var probe: [1]u8 = undefined;
            var bufs: [1][]u8 = .{&probe};
            const got = r.vtable.readVec(r, &bufs) catch |err| switch (err) {
                error.EndOfStream => {
                    try simd.forEachField(window, scratch, opts, ctx, onField);
                    return;
                },
                error.ReadFailed => return StreamError.ReadFailed,
            };
            // Any byte beyond a full window means the record does not fit.
            _ = got;
            return StreamError.RecordTooLong;
        }
        r.fillMore() catch |err| switch (err) {
            error.EndOfStream => {
                // End of input: any leftover is the final record (no trailing
                // newline). It is shorter than the buffer, so it is complete.
                const rem = r.buffered();
                if (rem.len > 0) try simd.forEachField(rem, scratch, opts, ctx, onField);
                return;
            },
            error.ReadFailed => return StreamError.ReadFailed,
        };
    }
}

// ---------------------------------------------------------------------------
// Auto-selecting facade
// ---------------------------------------------------------------------------

pub const Strategy = enum { in_memory, streaming };

pub const AutoOptions = struct {
    csv: Options = .{},
    /// Inputs whose size is known and at most this are slurped into memory and
    /// parsed with the fastest in-memory push path. Larger or unknown-size
    /// inputs are streamed with bounded memory. (Size is the right axis here:
    /// it decides memory footprint, not which parser is faster.)
    in_memory_threshold: usize = 4 << 20, // 4 MiB
    /// Safety cap on the in-memory slurp.
    max_in_memory: usize = 1 << 30, // 1 GiB
};

/// Decide a strategy from a size hint. `null` (unknown size) streams.
pub fn decide(size_hint: ?u64, threshold: usize) Strategy {
    const sz = size_hint orelse return .streaming;
    return if (sz <= threshold) .in_memory else .streaming;
}

/// Parse a CSV stream, auto-selecting between an in-memory slurp (small/known
/// size) and bounded streaming (large/unknown size). The streaming window is the
/// reader's own buffer, so size it for your largest record. Returns the chosen
/// strategy. This is the allocating convenience layer over the zero-alloc core.
pub fn parseReader(
    gpa: std.mem.Allocator,
    r: *Reader,
    size_hint: ?u64,
    ao: AutoOptions,
    ctx: anytype,
    comptime onField: fn (@TypeOf(ctx), bytes: []const u8, last_in_record: bool) void,
) !Strategy {
    const strategy = decide(size_hint, ao.in_memory_threshold);
    switch (strategy) {
        .in_memory => {
            const buf = try r.allocRemaining(gpa, .limited(ao.max_in_memory));
            defer gpa.free(buf);
            const scratch = try gpa.alloc(u8, @max(buf.len, 64));
            defer gpa.free(scratch);
            try simd.forEachField(buf, scratch, ao.csv, ctx, onField);
        },
        .streaming => {
            const scratch = try gpa.alloc(u8, @max(r.buffer.len, 64));
            defer gpa.free(scratch);
            try streamReader(r, scratch, ao.csv, ctx, onField);
        },
    }
    return strategy;
}
