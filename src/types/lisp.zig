const std = @import("std");
const hash_map = std.hash_map;

const ArrayList = std.ArrayList;
const HashMap = hash_map.HashMap;

const LispEnv = @import("../env.zig").LispEnv;

pub const LispFunction = *const fn ([]MalType) MalTypeError!MalType;

pub const LispFunctionWithEnv = *const fn ([]MalType, *LispEnv) MalTypeError!MalType;

pub const GenericLispFunction = union(enum) {
    simple: LispFunction,
    with_env: LispFunctionWithEnv,
};

pub const List = ArrayList(MalType);

pub const MalTypeError = error{
    Unhandled,
    IllegalType,
};

pub const Number = struct {
    // TODO: Support for floating point
    value: u64,
};

pub const MalType = union(enum) {
    boolean: bool,
    number: Number,
    /// An array which is ordered sequence of characters. The basic way
    /// to create is by using double quotes.
    string: ArrayList(u8),
    list: List,
    /// General symbol type including function
    symbol: []const u8,

    SExprEnd,
    /// Incompleted type from parser
    Incompleted,

    pub fn deinit(self: MalType) void {
        switch (self) {
            .string => |string| {
                string.deinit();
            },
            .list => |list| {
                for (list.items) |item| {
                    item.deinit();
                }
                list.deinit();
            },
            else => {},
        }
    }

    pub fn as_symbol(self: MalType) MalTypeError![]const u8 {
        switch (self) {
            .symbol => |symbol| {
                return symbol;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    pub fn as_boolean(self: MalType) MalTypeError!bool {
        switch (self) {
            .boolean => |boolean| {
                return boolean;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    pub fn as_number(self: MalType) MalTypeError!Number {
        switch (self) {
            .number => |num| {
                return num;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    pub fn as_string(self: MalType) MalTypeError!ArrayList(u8) {
        switch (self) {
            .string => |str| {
                return str;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    pub fn as_list(self: MalType) MalTypeError!ArrayList(MalType) {
        switch (self) {
            .list => |list| {
                return list;
            },
            else => return MalTypeError.IllegalType,
        }
    }
};

const MalTypeContext = struct {
    pub fn hash(_: @This(), key: *MalType) u64 {
        return switch (key.*) {
            .symbol => |s| hash_map.hashString(s),
            .string => |str| hash_map.hashString(str.items),
            else => unreachable,
        };
    }

    pub fn eql(_: @This(), ma: *MalType, mb: *MalType) bool {
        return switch (ma.*) {
            .symbol => |a| switch (mb.*) {
                .symbol => |b| hash_map.eqlString(a, b),
                else => false,
            },
            .string => |a| switch (mb.*) {
                .string => |b| hash_map.eqlString(a.items, b.items),
                else => false,
            },
            else => unreachable,
        };
    }
};

pub fn MalTypeHashMap(comptime V: type) type {
    return HashMap(*MalType, V, MalTypeContext, 80);
}
