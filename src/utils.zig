const assert = @import("std").debug.assert;

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
