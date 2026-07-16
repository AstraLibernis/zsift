//! Field converters (`core/convert.zig`) exercised through the public `Field` methods.

const std = @import("std");
const testing = std.testing;
const csv = @import("../csv.zig");
const Field = csv.Field;
const ConvertError = csv.ConvertError;

fn f(bytes: []const u8) Field {
    return .{ .bytes = bytes, .last_in_record = false };
}

const Color = enum { red, green, blue };

test "as: round-trips every supported type" {
    try testing.expectEqual(@as(i32, -42), try f("-42").as(i32));
    try testing.expectEqual(@as(u64, 18446744073709551615), try f("18446744073709551615").as(u64));
    try testing.expectEqual(@as(f64, 3.14), try f("3.14").as(f64));
    try testing.expectEqual(true, try f("true").as(bool));
    try testing.expectEqual(false, try f("0").as(bool));
    try testing.expectEqual(Color.green, try f("green").as(Color));
    try testing.expectEqualStrings("hello", try f("hello").as([]const u8));
}

test "as: optional maps empty to null, non-empty through the child converter" {
    try testing.expectEqual(@as(?i32, null), try f("").as(?i32));
    try testing.expectEqual(@as(?i32, 7), try f("7").as(?i32));
    try testing.expectEqual(@as(?Color, null), try f("").as(?Color));
    try testing.expectEqual(@as(?Color, .blue), try f("blue").as(?Color));
}

test "as: each ConvertError fires on bad input" {
    try testing.expectError(ConvertError.InvalidInt, f("12x").as(i32));
    try testing.expectError(ConvertError.InvalidInt, f("").as(i32)); // empty is not a valid int
    try testing.expectError(ConvertError.InvalidFloat, f("1.2.3").as(f64));
    try testing.expectError(ConvertError.InvalidBool, f("maybe").as(bool));
    try testing.expectError(ConvertError.InvalidEnum, f("purple").as(Color));
}

test "typed helpers: asInt/asFloat/asBool/asEnum/asOptional" {
    try testing.expectEqual(@as(u8, 255), try f("255").asInt(u8));
    try testing.expectEqual(@as(f32, 1.5), try f("1.5").asFloat(f32));
    try testing.expectEqual(true, try f("T").asBool());
    try testing.expectEqual(Color.red, try f("red").asEnum(Color));
    try testing.expectEqual(@as(?i16, null), try f("").asOptional(i16));
    try testing.expectEqual(@as(?i16, -3), try f("-3").asOptional(i16));
}

test "asBool: accepted token set (truthy and falsy)" {
    for ([_][]const u8{ "true", "True", "TRUE", "1", "t", "T" }) |s|
        try testing.expectEqual(true, try f(s).asBool());
    for ([_][]const u8{ "false", "False", "FALSE", "0", "f", "F" }) |s|
        try testing.expectEqual(false, try f(s).asBool());
}

test "isEmpty / eql / trimmed" {
    try testing.expect(f("").isEmpty());
    try testing.expect(!f("x").isEmpty());
    try testing.expect(f("abc").eql("abc"));
    try testing.expect(!f("abc").eql("abd"));

    const t = f("  hi \t").trimmed();
    try testing.expectEqualStrings("hi", t.bytes);
    // trimmed borrows: the result is a sub-slice of the input, not a copy.
    const src = "  hi \t";
    const tt = f(src).trimmed();
    try testing.expect(tt.bytes.ptr == src.ptr + 2);
    // last_in_record is preserved through trimmed().
    const lir = Field{ .bytes = " x ", .last_in_record = true };
    try testing.expect(lir.trimmed().last_in_record);
}
