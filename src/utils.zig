const std = @import("std");
const maxInt = std.math.maxInt;
const print = std.debug.print;
const assert = std.debug.assert;

pub inline fn valuesFromEnum(comptime E: type, comptime enums: type) []const E {
    comptime {
        assert(@typeInfo(enums) == .Enum);
        const enum_fields = @typeInfo(enums).Enum.fields;
        var result: [enum_fields.len]E = undefined;
        for (&result, enum_fields) |*r, f| {
            r.* = f.value;
        }
        const final = result;
        return &final;
    }
}

pub fn log(comptime key: []const u8, message: anytype) void {
    // var buffer: [100]u8 = undefined;
    // var buffer1: [100]u8 = undefined;
    // const output_format = "{any}";
    // const output = std.fmt.bufPrint(&buffer, "test {s}", .{output_format}) catch unreachable;
    // const final_output = std.fmt.bufPrint(&buffer1, output, .{"aa"}) catch unreachable;
    // std.debug.print("{s}\n", .{final_output});
    // std.debug.print(output, .{"aa"});

    // TODO: Handle the print case better
    // The current way is due to the formatted string has to be known
    // in comptime, which is difficult as it involves internal memory
    // to handle string concatenation, e.g. replace "any" into "s" to
    // handle string in formatting instead of treating them as an array
    // of u8. Consider the print result of string "test":
    // In {s} case: "test"
    // In {any} case: { 116, 101, 115, 116 } <- which are ASCII codes
    const T = @typeInfo(@TypeOf(message));
    // std.debug.print("{any}\n", .{T});
    switch (T) {
        .Int => {
            // std.debug.print("int\n", .{});
        },
        .Float => {
            // std.debug.print("float\n", .{});
        },
        .Array => {
            // std.debug.print("array\n", .{});
        },
        .Pointer => {
            // std.debug.print("pointer\n", .{});
            // T.Pointer.is_const == true;
            const TT = @typeInfo(T.Pointer.child);
            switch (TT) {
                .Array => {
                    if (TT.Array.child == u8) {
                        // std.debug.print("Pointer of array type\n", .{});
                        std.debug.print("[{s}]: {s}\n", .{ key, message });
                        return;
                    }
                },
                .Int => {
                    std.debug.print("[{s}]: {d}\n", .{ key, message });
                    return;
                },
                else => {
                    // Uncomment the following to debug further.
                    // std.debug.print("{any}\n", .{TT});
                    @panic("Not implemented to handle Pointer of non-array types.");
                },
            }
        },
        else => {
            // std.debug.print("Pending to handle\n", .{});
        },
    }
    std.debug.print("[{s}]: {any}\n", .{ key, message });
}

pub fn log_pointer(ptr: anytype) void {
    std.debug.print("[POINTER] {*}\n", .{ptr});
}

// From official documenation
pub fn parseU64(buf: []const u8, radix: u8) !u64 {
    var x: u64 = 0;

    for (buf) |c| {
        const digit = charToDigit(c);

        if (digit >= radix) {
            return error.InvalidChar;
        }

        // x *= radix
        var ov = @mulWithOverflow(x, radix);
        if (ov[1] != 0) return error.OverFlow;

        // x += digit
        ov = @addWithOverflow(ov[0], digit);
        if (ov[1] != 0) return error.OverFlow;
        x = ov[0];
    }

    return x;
}

pub fn parseI64(buf: []const u8, radix: u8) !i64 {
    var x: i64 = 0;
    var negate = false;

    for (buf, 0..) |c, i| {
        const digit = charToDigit(c);

        if (i == 0) {
            if (digit >= radix) {
                if (c == '-') {
                    negate = true;
                    continue;
                } else {
                    return error.InvalidChar;
                }
            }
        }

        // x *= radix
        var ov = @mulWithOverflow(x, radix);
        if (ov[1] != 0) return error.OverFlow;

        // x += digit
        ov = @addWithOverflow(ov[0], digit);
        if (ov[1] != 0) return error.OverFlow;
        x = ov[0];
    }

    if (negate) {
        // TODO: Handle the max_int negation case
        const ov = @subWithOverflow(0, x);
        if (ov[1] != 0) return error.OverFlow;

        x = ov[0];
    }

    return x;
}

fn charToDigit(c: u8) u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'A'...'Z' => c - 'A' + 10,
        'a'...'z' => c - 'a' + 10,
        else => maxInt(u8),
    };
}

const testing = std.testing;

test "parse u64" {
    const num1 = try parseU64("1234", 10);
    try testing.expect(num1 == 1234);

    if (parseU64("-1234", 10)) |_| unreachable else |err| {
        try testing.expectEqual(error.InvalidChar, err);
    }

    // 18,446,744,073,709,551,615; which is max of 64-bit unsigned integer
    const max_pos_u64 = try parseU64("18446744073709551615", 10);
    try testing.expect(max_pos_u64 == 18446744073709551615);

    if (parseU64("18446744073709551616", 10)) |_| unreachable else |err| {
        try testing.expectEqual(error.OverFlow, err);
    }
}

test "parse i64" {
    const num1 = try parseI64("1234", 10);
    try testing.expect(num1 == 1234);

    const num2 = try parseI64("-1234", 10);
    try testing.expect(num2 == -1234);

    const num0 = try parseI64("0", 10);
    try testing.expect(num0 == 0);

    const neg_num0 = try parseI64("-0", 10);
    try testing.expect(neg_num0 == 0);

    // 9,223,372,036,854,775,807; which is max of 64-bit signed integer
    const max_pos_i64 = try parseI64("9223372036854775807", 10);
    try testing.expect(max_pos_i64 == 9223372036854775807);

    const max_neg_i64 = try parseI64("-9223372036854775807", 10);
    try testing.expect(max_neg_i64 == -9223372036854775807);

    if (parseI64("9223372036854775808", 10)) |_| unreachable else |err| {
        try testing.expectEqual(error.OverFlow, err);
    }

    if (parseI64("-9223372036854775808", 10)) |_| unreachable else |err| {
        try testing.expectEqual(error.OverFlow, err);
    }
}
