//! Tests for `Options` validation (the fail-loud guard against configurations the
//! parsers cannot represent) and the debug-only scratch poisoning that backs the
//! `Field.bytes` lifetime contract. Referenced from `csv.zig`'s test block.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const csv = @import("../csv.zig");
const Options = csv.Options;
const Error = csv.Error;

test "validate accepts sensible configurations" {
    try Options.validate(.{}); // default comma/quote
    try Options.validate(.{ .delimiter = ';' });
    try Options.validate(.{ .delimiter = '\t' }); // TSV
    try Options.validate(.{ .delimiter = '|', .quote = '\'' });
}

test "validate rejects delimiter == quote" {
    try testing.expectError(Error.InvalidOptions, Options.validate(.{ .delimiter = '"' })); // == default quote
    try testing.expectError(Error.InvalidOptions, Options.validate(.{ .delimiter = ',', .quote = ',' }));
    try testing.expectError(Error.InvalidOptions, Options.validate(.{ .delimiter = '#', .quote = '#' }));
}

test "validate rejects a terminator as delimiter or quote" {
    try testing.expectError(Error.InvalidOptions, Options.validate(.{ .delimiter = '\n' }));
    try testing.expectError(Error.InvalidOptions, Options.validate(.{ .delimiter = '\r' }));
    try testing.expectError(Error.InvalidOptions, Options.validate(.{ .quote = '\n' }));
    try testing.expectError(Error.InvalidOptions, Options.validate(.{ .quote = '\r' }));
}

test "init surfaces InvalidOptions instead of silently corrupting" {
    var scratch: [64]u8 = undefined;
    try testing.expectError(Error.InvalidOptions, csv.Parser.init("a,b\n", &scratch, .{ .delimiter = '"' }));
    try testing.expectError(Error.InvalidOptions, csv.SimdParser.init("a,b\n", &scratch, .{ .quote = '\n' }));
    // A valid config still constructs fine.
    _ = try csv.Parser.init("a,b\n", &scratch, .{ .delimiter = '\t' });
    _ = try csv.SimdParser.init("a,b\n", &scratch, .{ .delimiter = ';' });
}

test "forEachField (push path) validates before parsing" {
    const noop = struct {
        fn on(_: void, _: []const u8, _: bool) void {}
    }.on;
    var scratch: [64]u8 = undefined;
    try testing.expectError(
        Error.InvalidOptions,
        csv.simd.forEachField("a,b\n", &scratch, .{ .delimiter = '"' }, {}, noop),
    );
}

// The `Field.bytes` lifetime contract, made observable: an unescaped (scratch-
// backed) field retained past `resetScratch()` must not read as still-valid. Debug
// builds poison the reclaimed region, so the stale slice reads 0xAA; in release the
// poisoning is compiled out, so this assertion only holds (and only runs) in Debug.
test "scratch-backed field is poisoned after resetScratch (debug only)" {
    if (builtin.mode != .Debug) return error.SkipZigTest;

    var scratch: [64]u8 = undefined;
    // `"a""b"` collapses to `a"b` (3 bytes) written into scratch — a borrowed slice.
    var p = try csv.Parser.init("\"a\"\"b\"\n", &scratch, .{});
    const field = (try p.next()).?;
    try testing.expectEqualStrings("a\"b", field.bytes); // valid before reset
    try testing.expect(@intFromPtr(field.bytes.ptr) == @intFromPtr(&scratch)); // points into scratch

    p.resetScratch();
    for (field.bytes) |byte| try testing.expectEqual(@as(u8, 0xAA), byte); // now poisoned
}
