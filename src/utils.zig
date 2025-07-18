const std = @import("std");
const maxInt = std.math.maxInt;
const print = std.debug.print;
const assert = std.debug.assert;

/// ANSI 3-bit Color code for terminal
/// The code actually supports more formatting, for simplicity they
/// are not included now.
const AnsiColor = enum(u8) {
    /// Can be considered as terminal default.
    Reset = 0,
    Black = 30,
    Red = 31,
    Green = 32,
    Yellow = 33,
    Blue = 34,
    Magenta = 35,
    Cyan = 36,
    White = 37,
    BrightBlack = 90,
    BrightRed = 91,
    BrightGreen = 92,
    BrightYellow = 93,
    BrightBlue = 94,
    BrightMagenta = 95,
    BrightCyan = 96,
    BrightWhite = 97,
};

pub inline fn valuesFromEnum(comptime E: type, comptime enums: type) []const E {
    comptime {
        // assert(@typeInfo(enums) == .Enum);
        const enum_fields = @typeInfo(enums).@"enum".fields;
        var result: [enum_fields.len]E = undefined;
        for (&result, enum_fields) |*r, f| {
            r.* = f.value;
        }
        const final = result;
        return &final;
    }
}

/// Further option for util logging function
pub const LogOption = struct {
    /// Color for the log in terminal env.
    color: AnsiColor = .Reset,
    /// Whether the log is shown in test cases only.
    test_only: bool = false,
};

/// Log function with color setting
pub fn log(comptime key: []const u8, comptime message: []const u8, args: anytype, option: LogOption) void {
    if (option.color != .Reset) {
        std.debug.print("\x1b[{d}m", .{@intFromEnum(option.color)});
    }
    if (!std.mem.eql(u8, key, "")) {
        std.debug.print("[{s}]: ", .{key});
    }
    std.debug.print(message, args);
    std.debug.print("\n", .{});
    std.debug.print("\x1b[0m", .{});
}

pub fn log_pointer(ptr: anytype) void {
    // const address = @returnAddress();

    // const info = std.debug.getSelfDebugInfo() catch @panic("Error in getting debug info");

    // const module_info = info.getModuleForAddress(address) catch @panic("ERR");
    // NOTE: This is copied from printSourceAtAddress directly, the signature
    // is incorrect with unknown reason.
    // const symbol_info = module_info.getSymbolAtAddress(info.allocator, address) catch |err| switch (err) {
    //     error.MissingDebugInfo, error.InvalidDebugInfo => @panic("Debug info issue."),
    //     else => @panic("Unknown error when getting symbol info."),
    // };

    // if (symbol_info.line_info) |line_info| {
    //     const file_path = line_info.file_name;
    //     const file_line = line_info.line;

    //     const caller_name = symbol_info.symbol_name;
    //     const file_name = std.fs.path.basename(file_path);

    //     std.debug.print("[POINTER]: {*}; file: {s}:{d}; caller fn: {s}\n", .{ ptr, file_name, file_line, caller_name });
    // } else {
    // }
    std.debug.print("[POINTER]: {*}\n", .{ptr});
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
