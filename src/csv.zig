//! zsift — public API surface for parsing delimited/tabular text (CSV by default;
//! the delimiter and quote are configurable). This file only re-exports; the
//! implementations live in focused modules:
//!
//!   * `types.zig`    — `Options`, `Field`, `Error` (shared by every parser)
//!   * `classify.zig` — SIMD chunk-classification primitives (the vector layer)
//!   * `scalar.zig`   — `Parser`: lenient byte-at-a-time, in-memory
//!   * `simd.zig`     — `SimdParser` (pull) and `forEachField` (push), strict
//!   * `stream.zig`   — `streamReader` and the auto-selecting `parseReader`
//!
//! Layering: types → classify → {scalar, simd, stream} → this facade.

const types = @import("types.zig");

pub const Options = types.Options;
pub const Error = types.Error;
pub const Field = types.Field;

/// Lenient scalar parser over an in-memory slice. See `scalar.zig`.
pub const Parser = @import("scalar.zig").Parser;

/// The vectorized fast-path parsers (well-formed RFC 4180 input). See `simd.zig`.
pub const simd = @import("simd.zig");
pub const SimdParser = simd.SimdParser;

/// SIMD chunk-classification primitives (the vector layer). Exposed so the
/// benchmark's method-matrix experiment can build alternative parse strategies.
pub const classify = @import("classify.zig");

/// Streaming over a `std.Io.Reader` plus the auto-selecting facade. See `stream.zig`.
pub const stream = @import("stream.zig");
pub const streamReader = stream.streamReader;
pub const parseReader = stream.parseReader;
pub const Strategy = stream.Strategy;
pub const AutoOptions = stream.AutoOptions;

// Tests live in dedicated files; pull them into `zig build test`.
test {
    _ = @import("csv_test.zig");
    _ = @import("simd_test.zig");
    _ = @import("stream_test.zig");
}
