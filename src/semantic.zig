const StaticStringMap = @import("std").StaticStringMap;

pub const BOOLEAN_TRUE = "t";
pub const BOOLEAN_FALSE = "nil";

/// Denote the syntax for boolean value
pub const BOOLEAN_MAP = StaticStringMap(bool).initComptime(.{
    .{ BOOLEAN_TRUE, true },
    .{ BOOLEAN_FALSE, false },
});
