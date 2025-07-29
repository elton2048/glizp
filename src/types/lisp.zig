const std = @import("std");
const builtin = @import("builtin");
const hash_map = std.hash_map;
const Allocator = std.mem.Allocator;

const ArrayList = std.ArrayListUnmanaged;
const HashMap = hash_map.HashMap;

const utils = @import("../utils.zig");
const LispEnv = @import("../env_ptr.zig").LispEnv;

pub const LispFunction = *const fn ([]*MalType) MalTypeError!MalType;

pub const LispFunctionWithEnv = *const fn ([]MalType, *LispEnv) MalTypeError!MalType;

pub const LispFunctionPtrWithEnv = *const fn ([]*MalType, *LispEnv) MalTypeError!*MalType;

/// For function with tail call optimization, there is no return as it should keep looping
/// until the second arg (*MalType) is eval to be non-list type.
pub const LispFunctionWithTail = *const fn ([]*MalType, **MalType, *LispEnv) MalTypeError!void;

/// For plugin purpose, the function shall allow to reference back
/// to the plugin instance, which is denoted as *anyopaque.
pub const LispFunctionWithOpaque = *const fn ([]*MalType, *anyopaque) MalTypeError!*MalType;

pub const GenericLispFunction = union(enum) {
    simple: LispFunction,
    with_env: LispFunctionWithEnv,
    with_ptr: LispFunctionPtrWithEnv,
    with_tail: LispFunctionWithTail,
    plugin: LispFunctionWithOpaque,
};

pub const List = ArrayList(*MalType);

pub const Vector = List;

pub const MalTypeError = error{
    Unhandled,
    IllegalType,
    FileNotFound,
    ArithError,
};

pub const NumberType = f64;

pub const ReferenceCountType = u64;

/// Number representation in lisp. It is possible the number does not
/// associate into an allocator.
pub const NumberData = struct {
    allocator: ?std.mem.Allocator = null,
    value: NumberType,
    reference_count: ReferenceCountType = 1,

    pub fn isInteger(self: NumberData) bool {
        return @trunc(self.value) == self.value;
    }

    pub fn isFloat(self: NumberData) bool {
        return !self.isInteger();
    }

    pub fn integer(self: NumberData) MalTypeError!i64 {
        if (!self.isInteger()) {
            return MalTypeError.IllegalType;
        }
        return @intFromFloat(self.value);
    }

    pub fn to_usize(self: NumberData) MalTypeError!usize {
        const int = try self.integer();
        return @as(usize, @intCast(int));
    }
};

/// An array which is ordered sequence of characters. The basic way
/// to create is by using double quotes.
pub const StringData = struct {
    allocator: ?std.mem.Allocator = null,
    data: ArrayList(u8),
    reference_count: ReferenceCountType = 1,
};

/// As symbol is using slice instead of ArrayList in the current implementation,
/// they are separated into two types.
pub const SymbolData = struct {
    allocator: ?std.mem.Allocator = null,
    data: []const u8,
    reference_count: ReferenceCountType = 1,
};

pub const ListData = struct {
    allocator: std.mem.Allocator,
    data: List,
    reference_count: ReferenceCountType = 1,
};

pub const VectorData = struct {
    allocator: std.mem.Allocator,
    data: Vector,
    reference_count: ReferenceCountType = 1,
};

pub const FunctionData = struct {
    allocator: std.mem.Allocator,
    data: *LispEnv,
    reference_count: ReferenceCountType = 1,
};

pub const MalType = union(enum) {
    boolean: bool,
    number: NumberData,
    /// An array which is ordered sequence of characters. The basic way
    /// to create is by using double quotes.
    string: StringData,
    list: ListData,
    /// Vector type, which provide constant-time element access
    vector: VectorData,
    /// General symbol type including function keyword
    symbol: SymbolData,

    function: FunctionData,

    SExprEnd,
    VectorExprEnd,
    /// Incompleted type from parser
    Incompleted: void,
    /// Undefined param for function
    Undefined: void,

    pub fn format(self: MalType, comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        _ = options;

        if (comptime std.mem.eql(u8, fmt, "")) {
            try writer.writeAll("LispObject: {");

            switch (self) {
                .symbol => |symbol| {
                    try std.fmt.format(writer, ".symbol: '{s}'; count: {d}", .{ symbol.data, symbol.reference_count });
                },
                .number => |number| {
                    try std.fmt.format(writer, "\x1b[35m", .{});
                    try std.fmt.format(writer, ".number: {d}; count: {d}", .{
                        number.value,
                        number.reference_count,
                    });
                    try std.fmt.format(writer, "\x1b[0m", .{});
                },
                .boolean => |boolean| {
                    try std.fmt.format(writer, ".boolean: {any}", .{boolean});
                },
                .SExprEnd,
                .VectorExprEnd,
                .Incompleted,
                .Undefined,
                => {
                    switch (@typeInfo(@TypeOf(self))) {
                        .@"union" => |info| {
                            if (info.tag_type) |UnionTagType| {
                                try std.fmt.format(writer, ".{s}", .{@tagName(@as(UnionTagType, self))});
                            }
                        },
                        else => unreachable,
                    }
                },
                .string => |string| {
                    try std.fmt.format(writer, "count: {d}; ", .{string.reference_count});
                    try std.fmt.format(writer, ".string: '{s}'", .{string.data.items});
                },
                .list => |list| {
                    // TODO: Need level control, limit or better formatting?
                    try std.fmt.format(writer, "count: {d}", .{list.reference_count});
                    try std.fmt.format(writer, ".list: ", .{});
                    if (list.reference_count > 0) {
                        for (list.data.items, 0..) |item, i| {
                            try writer.writeAll("{ ");
                            try std.fmt.format(writer, "index: {d}; {any}", .{ i, item });
                            try writer.writeAll(" }");

                            try std.fmt.format(writer, "pointer: {*}", .{item});
                        }
                    }
                },
                .vector => |vector| {
                    try std.fmt.format(writer, "count: {d}", .{vector.reference_count});
                    try std.fmt.format(writer, ".vector: ", .{});
                    if (vector.reference_count > 0) {
                        for (vector.data.items, 0..) |item, i| {
                            try writer.writeAll("{ ");
                            try std.fmt.format(writer, "index: {d}; {any}", .{ i, item });
                            try writer.writeAll(" }");
                        }
                    }
                },
                .function => |func| {
                    try std.fmt.format(writer, "count: {d}", .{func.reference_count});
                    try std.fmt.format(writer, ".function: ", .{});
                    try std.fmt.format(writer, "{any}", .{func.data});
                },
                // NOTE: This is no way to use default format now as
                // the implementation checks if the struct has "format"
                // method or not for custom formatting
            }
            try writer.writeAll("}");
        }
    }

    pub const INCOMPLETED = @constCast(&MalType{ .Incompleted = undefined });
    pub const UNDEFINED = @constCast(&MalType{ .Undefined = undefined });
    pub const TRUE = @constCast(&MalType{ .boolean = true });
    pub const FALSE = @constCast(&MalType{ .boolean = false });

    pub fn new_boolean_ptr(data: bool) *MalType {
        if (data) {
            return TRUE;
        }
        return FALSE;
    }

    pub fn new_boolean(data: bool) MalType {
        if (data) {
            return TRUE.*;
        }
        return FALSE.*;
    }

    pub fn new_string(data: ArrayList(u8)) MalType {
        return .{ .string = .{
            .data = data,
        } };
    }

    pub fn new_string_ptr(allocator: std.mem.Allocator, data: ArrayList(u8)) *MalType {
        const mal_ptr = allocator.create(MalType) catch @panic("OOM");
        mal_ptr.* = .{ .string = .{
            .allocator = allocator,
            .data = data,
        } };

        return mal_ptr;
    }

    pub fn new_list(allocator: std.mem.Allocator, data: List) MalType {
        return .{ .list = .{
            .allocator = allocator,
            .data = data,
        } };
    }

    pub fn new_vector(allocator: std.mem.Allocator, data: Vector) MalType {
        return .{ .vector = .{
            .allocator = allocator,
            .data = data,
        } };
    }

    pub fn new_symbol(allocator: std.mem.Allocator, data: []const u8) *MalType {
        const mal_ptr = allocator.create(MalType) catch @panic("OOM");
        mal_ptr.* = .{ .symbol = .{
            .allocator = allocator,
            .data = data,
        } };

        return mal_ptr;
    }

    pub fn new_empty_list_ptr(allocator: std.mem.Allocator) *MalType {
        const mal_ptr = allocator.create(MalType) catch @panic("OOM");

        mal_ptr.* = MalType{ .list = .{
            .allocator = allocator,
            .data = List.init(allocator),
        } };

        return mal_ptr;
    }

    pub fn new_list_ptr(allocator: std.mem.Allocator, data: List) *MalType {
        const mal_ptr = allocator.create(MalType) catch @panic("OOM");

        mal_ptr.* = MalType{ .list = .{
            .allocator = allocator,
            .data = data,
        } };

        return mal_ptr;
    }

    pub fn new_vector_ptr(allocator: std.mem.Allocator, data: Vector) *MalType {
        const mal_ptr = allocator.create(MalType) catch @panic("OOM");
        const mal = new_vector(allocator, data);

        mal_ptr.* = mal;

        return mal_ptr;
    }

    pub fn new_number(allocator: std.mem.Allocator, data: NumberType) *MalType {
        const mal_ptr = allocator.create(MalType) catch @panic("OOM");

        mal_ptr.* = .{
            .number = .{
                .allocator = allocator,
                .value = data,
            },
        };

        return mal_ptr;
    }

    pub fn new_function_ptr(data: *LispEnv) *MalType {
        const allocator = data.allocator;
        const mal_ptr = allocator.create(MalType) catch @panic("OOM");

        mal_ptr.* = .{
            .function = .{
                .allocator = allocator,
                .data = data,
            },
        };

        return mal_ptr;
    }

    pub fn deinit(self: *MalType) void {
        utils.log("DEINIT entry", "{*}; {any}", .{ self, self }, .{ .test_only = true });

        switch (self.*) {
            .symbol => |symbol| {
                if (symbol.allocator) |allocator| {
                    allocator.destroy(self);
                }
            },
            .number => |number| {
                if (number.allocator) |allocator| {
                    allocator.destroy(self);
                }
            },
            .string => |*string| {
                if (string.allocator) |allocator| {
                    string.data.deinit(allocator);

                    allocator.destroy(self);
                }
            },
            .list => |*list| {
                for (list.data.items) |item| {
                    item.decref();
                }
                list.data.deinit(list.allocator);

                list.allocator.destroy(self);
            },
            .vector => |*vector| {
                for (vector.data.items) |item| {
                    utils.log("deinit vector", "{any}", .{item}, .{ .enable = false });

                    item.decref();
                }
                vector.data.deinit(vector.allocator);

                vector.allocator.destroy(self);
            },
            .function => |func| {
                // NOTE: Except lambda cases, All env are deinit through root env.
                func.data.deinit();

                func.allocator.destroy(self);
            },
            else => {},
        }
    }

    pub fn clone(self: MalType) MalType {
        switch (self) {
            .string => |string| {
                const original_string = string.data.clone() catch @panic("OOM");
                return MalType{ .string = .{
                    .data = original_string,
                } };
            },
            else => {},
        }
        return self;
    }

    /// Copy MalType into designated allocator. The underlying data
    /// should also be copied into designated allocator.
    /// Not being used. Consider remove this.
    pub fn copy(self: *MalType, allocator: std.mem.Allocator) *MalType {
        utils.log("lisp", "COPY", .{}, .{ .test_only = true });

        var new_object: *MalType = undefined;
        switch (self.*) {
            .symbol => |symbol| {
                new_object = MalType.new_symbol(allocator, symbol.data);
            },
            .string => |string| {
                const new_data = string.data.clone(allocator) catch @panic("");

                new_object = MalType.new_string_ptr(allocator, new_data);
            },
            .number => |number| {
                new_object = allocator.create(MalType) catch @panic("OOM");
                new_object.* = .{ .number = .{
                    .allocator = allocator,
                    .value = number.value,
                    .reference_count = number.reference_count,
                } };
            },
            .list => |list| {
                var copied_list: List = .empty;
                for (list.data.items) |item| {
                    const copied_item = item.copy(allocator);

                    copied_list.append(allocator, copied_item) catch unreachable;
                }

                new_object = MalType.new_list_ptr(allocator, copied_list);
            },
            .vector => |vector| {
                var copied_vector: List = .empty;
                for (vector.data.items) |item| {
                    const copied_item = item.copy(allocator);

                    copied_vector.append(allocator, copied_item) catch unreachable;
                }

                new_object = MalType.new_vector_ptr(allocator, copied_vector);
            },
            .boolean => |boolean| {
                new_object = MalType.new_boolean_ptr(boolean);
            },
            else => {
                new_object = allocator.create(MalType) catch @panic("OOM");
                new_object.* = self.*;
                utils.log("COPY", "{any}", .{self}, .{});
                @panic("Not yet implemented");
            },
        }

        return new_object;
    }

    pub fn as_symbol(self: MalType) MalTypeError![]const u8 {
        switch (self) {
            .symbol => |symbol| {
                return symbol.data;
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

    pub fn as_number(self: MalType) MalTypeError!NumberData {
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
                return str.data;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    pub fn as_list(self: MalType) MalTypeError!List {
        switch (self) {
            .list => |list| {
                return list.data;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    pub fn as_vector(self: MalType) MalTypeError!Vector {
        switch (self) {
            .vector => |vector| {
                return vector.data;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    pub fn as_number_ptr(self: *MalType) MalTypeError!NumberData {
        switch (self.*) {
            .number => |num| {
                return num;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    pub fn as_list_ptr(self: MalType) MalTypeError!List {
        switch (self) {
            .list => |list| {
                return list.data;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    pub fn as_vector_ptr(self: *MalType) MalTypeError!Vector {
        switch (self.*) {
            .vector => |vector| {
                return vector.data;
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

    pub fn as_function_ptr(self: *MalType) MalTypeError!*LispEnv {
        switch (self.*) {
            .function => |func| {
                return func.data;
            },
            else => return MalTypeError.IllegalType,
        }
    }

    /// Increase reference count for a lisp object.
    pub fn incref(self: *MalType) void {
        // A procedure instead of a function returning its argument
        // because it must most of the time be applied *after* a
        // successful assignment.
        // zig fmt: off
        switch (self.*) {
            .list          => |*l| l.reference_count += 1,
            .vector        => |*l| l.reference_count += 1,
            .number,       => |*l| l.reference_count += 1,
            .string        => |*l| l.reference_count += 1,
            .symbol              => |*l| l.reference_count += 1,
            .function      => |*l| l.reference_count += 1,
            else => {},
            // .fncore                    => |*l| l.reference_count += 1,
            // .func                      => |*l| l.reference_count += 1,
            // .atom                      => |*l| l.reference_count += 1,
            // .hashmap                   => |*l| l.reference_count += 1,
            // .nil, .false, .true        => {},
        }
        // zig fmt: on
    }

    pub fn decref(self: *MalType) void {
        switch (self.*) {
            .symbol => |*l| {
                if (l.reference_count == 0) {
                    return;
                }

                l.reference_count -= 1;
                if (l.reference_count == 0) {
                    self.deinit();
                }
            },
            .number => |*l| {
                if (l.reference_count == 0) {
                    return;
                }

                l.reference_count -= 1;
                if (l.reference_count == 0) {
                    self.deinit();
                }
            },
            .string => |*l| {
                if (l.reference_count == 0) {
                    return;
                }

                l.reference_count -= 1;
                if (l.reference_count == 0) {
                    self.deinit();
                }
            },
            .list => |*l| {
                if (l.reference_count == 0) {
                    return;
                }

                l.reference_count -= 1;
                if (l.reference_count == 0) {
                    self.deinit();
                }
            },
            .vector => |*l| {
                if (l.reference_count == 0) {
                    return;
                }

                l.reference_count -= 1;
                if (l.reference_count == 0) {
                    self.deinit();
                }
            },
            .function => |*func| {
                if (func.reference_count == 0) return;

                func.reference_count -= 1;
                if (func.reference_count == 0) {
                    self.deinit();
                }
            },
            else => {},
            // NOTE: Keep as reference
            // else => |*l| {
            //     if (l.reference_count == 0) {
            //         return;
            //     }

            //     l.reference_count -= 1;
            //     if (l.reference_count == 0) {
            //         self.deinit();
            //     }
            // },
        }
    }

    pub fn ref(self: MalType) ReferenceCountType {
        switch (self) {
            .number => |num| {
                return num.reference_count;
            },
            .symbol => |sym| {
                return sym.reference_count;
            },
            .string => |string| {
                return string.reference_count;
            },
            .list => |list| {
                return list.reference_count;
            },
            .vector => |vector| {
                return vector.reference_count;
            },
            else => {
                return 1;
            },
        }
    }
};

const MalTypeContext = struct {
    pub fn hash(_: @This(), key: *MalType) u64 {
        return switch (key.*) {
            .symbol => |s| hash_map.hashString(s.data),
            .string => |str| hash_map.hashString(str.data.items),
            else => unreachable,
        };
    }

    pub fn eql(_: @This(), ma: *MalType, mb: *MalType) bool {
        return switch (ma.*) {
            .symbol => |a| switch (mb.*) {
                .symbol => |b| hash_map.eqlString(a.data, b.data),
                else => false,
            },
            .string => |a| switch (mb.*) {
                .string => |b| hash_map.eqlString(a.data.items, b.data.items),
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

    const key1 = MalType.new_symbol(allocator, "test1");
    defer key1.decref();

    const value1 = "value1";
    lispHashMap.put(key1, value1) catch @panic("Unexpected error in putting value in LispHashMap.");

    const value1_optional_result = lispHashMap.get(key1);
    if (value1_optional_result) |value| {
        try testing.expectEqual(value, "value1");
    }
}

test "NumberData" {
    const f1 = NumberData{ .value = 0.2 };
    try testing.expect(!f1.isInteger());
    try testing.expect(f1.isFloat());
    try testing.expectError(MalTypeError.IllegalType, f1.integer());

    const int1 = NumberData{ .value = 1 };
    try testing.expect(int1.isInteger());
    try testing.expect(!int1.isFloat());

    const int1_int = try int1.integer();
    try testing.expectEqual(1, int1_int);

    const int1_usize = try int1.to_usize();
    try testing.expectEqual(1, int1_usize);
}
