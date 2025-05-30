const std = @import("std");
const hash_map = std.hash_map;
const Allocator = std.mem.Allocator;

const ArrayList = std.ArrayList;
const HashMap = hash_map.HashMap;

const utils = @import("../utils.zig");
const LispEnv = @import("../env.zig").LispEnv;

pub const LispFunction = *const fn ([]MalType) MalTypeError!MalType;

pub const LispFunctionWithEnv = *const fn ([]MalType, *LispEnv) MalTypeError!MalType;

/// For plugin purpose, the function shall allow to reference back
/// to the plugin instance, which is denoted as *anyopaque.
pub const LispFunctionWithOpaque = *const fn ([]MalType, *anyopaque) MalTypeError!MalType;

pub const GenericLispFunction = union(enum) {
    simple: LispFunction,
    with_env: LispFunctionWithEnv,
    plugin: LispFunctionWithOpaque,
};

pub const List = ArrayList(MalType);

pub const Vector = List;

pub const MalTypeError = error{
    Unhandled,
    IllegalType,
    FileNotFound,
    ArithError,
};

pub const NumberType = f64;

pub const Number = struct {
    value: NumberType,

    pub fn isInteger(self: Number) bool {
        return @trunc(self.value) == self.value;
    }

    pub fn isFloat(self: Number) bool {
        return !self.isInteger();
    }

    pub fn integer(self: Number) MalTypeError!i64 {
        if (!self.isInteger()) {
            return MalTypeError.IllegalType;
        }
        return @intFromFloat(self.value);
    }

    pub fn to_usize(self: Number) MalTypeError!usize {
        const int = try self.integer();
        return @as(usize, @intCast(int));
    }
};

pub const MalType = union(enum) {
    boolean: bool,
    number: Number,
    /// An array which is ordered sequence of characters. The basic way
    /// to create is by using double quotes.
    string: ArrayList(u8),
    list: List,
    /// Vector type, which provide constant-time element access
    vector: Vector,
    /// General symbol type including function keyword
    symbol: []const u8,

    function: *LispEnv,

    SExprEnd,
    VectorExprEnd,
    /// Incompleted type from parser
    Incompleted,
    /// Undefined param for function
    Undefined,

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
            .vector => |vector| {
                for (vector.items) |item| {
                    item.deinit();
                }
                vector.deinit();
            },
            // NOTE: Using the root env to deinit, but it seems a bit
            // magical?
            // .function => |func_with_env| {
            //     func_with_env.deinit();
            // },
            else => {},
        }
    }

    pub fn clone(self: MalType) MalType {
        switch (self) {
            .string => |string| {
                const new_string = string.clone() catch @panic("OOM");
                return MalType{ .string = new_string };
            },
            else => {},
        }
        return self;
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

    pub fn as_vector(self: MalType) MalTypeError!Vector {
        switch (self) {
            .vector => |vector| {
                return vector;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    pub fn as_function(self: MalType) MalTypeError!*LispEnv {
        switch (self) {
            .function => |func| {
                return func;
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

pub fn LispHashMap(comptime V: type) type {
    return struct {
        hash_map: GenericMalHashMap,
        allocator: Allocator,

        const GenericMalHashMap = MalTypeHashMap(V);
        const Self = @This();

        pub fn init(allocator: Allocator) LispHashMap(V) {
            return .{
                .hash_map = GenericMalHashMap.init(allocator),
                .allocator = allocator,
            };
        }

        /// Put the `key` and `value` in the hash map, where the key
        /// is copied. The memory ownership is transfered (and thus
        /// that could be destroyed right away).
        /// This tries to match the best practice to defer destroy the
        /// instance created within the same scope to make sure no memory
        /// leakage.
        pub fn put(self: *Self, key: *MalType, value: V) !void {
            const key_copy = try self.allocator.create(@TypeOf(key.*));
            key_copy.* = key.*;

            try self.hash_map.put(key_copy, value);
        }

        pub fn get(self: *Self, key: *MalType) ?V {
            return self.hash_map.get(key);
        }

        pub fn deinit(self: *Self) void {
            var iter = self.hash_map.iterator();
            while (iter.next()) |entry| {
                // The key is owned by hash_map
                self.allocator.destroy(entry.key_ptr.*);
                // self.allocator.destroy(entry.value_ptr);
            }

            self.hash_map.deinit();
        }
    };
}

const testing = std.testing;

test "LispHashMap" {
    const allocator = std.testing.allocator;

    var lispHashMap = LispHashMap([]const u8).init(allocator);
    defer lispHashMap.deinit();

    const key1 = allocator.create(MalType) catch @panic("OOM");
    defer allocator.destroy(key1);
    key1.* = MalType{ .symbol = "test1" };

    const value1 = "value1";
    lispHashMap.put(key1, value1) catch @panic("Unexpected error in putting value in LispHashMap.");

    const value1_optional_result = lispHashMap.get(key1);
    if (value1_optional_result) |value| {
        try testing.expectEqual(value, "value1");
    }
}

test "Number" {
    const f1 = Number{ .value = 0.2 };
    try testing.expect(!f1.isInteger());
    try testing.expect(f1.isFloat());
    try testing.expectError(MalTypeError.IllegalType, f1.integer());

    const int1 = Number{ .value = 1 };
    try testing.expect(int1.isInteger());
    try testing.expect(!int1.isFloat());

    const int1_int = try int1.integer();
    try testing.expectEqual(1, int1_int);

    const int1_usize = try int1.to_usize();
    try testing.expectEqual(1, int1_usize);
}
