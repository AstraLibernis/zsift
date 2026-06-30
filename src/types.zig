//! Types shared by the scalar (`csv.Parser`) and SIMD (`csv.SimdParser`) parsers.

pub const Options = struct {
    /// Byte that separates fields within a record.
    delimiter: u8 = ',',
    /// Byte used to quote fields that contain the delimiter, a newline, or a quote.
    quote: u8 = '"',
};

pub const Error = error{
    /// A quoted field was opened but the input ended before the closing quote.
    UnterminatedQuote,
    /// A closing quote was followed by something other than a delimiter,
    /// a newline, or end-of-input (e.g. `"ab"c`).
    InvalidQuote,
    /// A quoted field contained an escaped quote and needed rewriting, but the
    /// caller-supplied scratch buffer was too small to hold the result.
    ScratchTooSmall,
    /// `nextRecord` was given a destination slice with fewer slots than the
    /// record has fields.
    TooManyFields,
};

/// One field of a record. `last_in_record` is true when this field is the final
/// one of its record, i.e. the next field (if any) belongs to a new record.
pub const Field = struct {
    bytes: []const u8,
    last_in_record: bool,
};
