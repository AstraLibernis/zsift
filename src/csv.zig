//! zsift — public API surface for parsing delimited/tabular text (CSV by default;
//! the delimiter and quote are configurable). This file only re-exports; the
//! implementations live in focused modules under `core/`:
//!
//!   * `core/types.zig`  — `Options`, `Field`, `Error` (shared by every parser)
//!   * `core/scalar.zig` — `Parser`: lenient byte-at-a-time, in-memory
//!   * `core/simd.zig`   — `SimdParser` (pull) and `forEachField` (push), strict;
//!                         also the `classify` chunk-classification primitives
//!   * `core/stream.zig` — `streamReader` and the auto-selecting `parseReader`
//!
//! Layering: types → simd(classify) → {scalar, stream} → this facade.

const types = @import("core/types.zig");

pub const Options = types.Options;
pub const Error = types.Error;
pub const Field = types.Field;

/// Lenient scalar parser over an in-memory slice. See `core/scalar.zig`.
pub const Parser = @import("core/scalar.zig").Parser;

/// The vectorized fast-path parsers (well-formed RFC 4180 input). See `core/simd.zig`.
pub const simd = @import("core/simd.zig");
pub const SimdParser = simd.SimdParser;

/// SIMD chunk-classification primitives (the vector layer), re-exported from
/// `core/simd.zig`. Exposed so the benchmark's method-matrix experiment can build
/// alternative parse strategies.
pub const classify = simd.classify;

/// Streaming over a `std.Io.Reader` plus the auto-selecting facade. See `core/stream.zig`.
pub const stream = @import("core/stream.zig");
pub const streamReader = stream.streamReader;
pub const parseReader = stream.parseReader;
pub const Strategy = stream.Strategy;
pub const AutoOptions = stream.AutoOptions;

// Tests live in dedicated files; pull them into `zig build test`.
test {
    _ = @import("test/csv_test.zig");
    _ = @import("test/simd_test.zig");
    _ = @import("test/stream_test.zig");
    _ = @import("test/options_test.zig");
}
