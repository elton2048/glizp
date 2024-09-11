const std = @import("std");
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
    std.debug.print("[{s}]: {any}\n", .{ key, message });
}

pub fn log_pointer(ptr: anytype) void {
    std.debug.print("[POINTER] {*}\n", .{ptr});
}
