const std = @import("std");
const logz = @import("logz");

const ArrayList = std.ArrayList;

const data = @import("data.zig");
const utils = @import("utils.zig");

const MalType = @import("reader.zig").MalType;
const MalTypeError = @import("reader.zig").MalTypeError;
const LispFunction = @import("reader.zig").LispFunction;

pub const LispEnv = struct {
    allocator: std.mem.Allocator,
    data: std.StringHashMap(MalType),
    internalFnTable: std.StringHashMap(LispFunction),
    externalFnTable: std.StringHashMap(LispFunction),

    const Self = @This();

    fn readFromStaticMap(baseTable: *std.StringHashMap(LispFunction), map: std.StaticStringMap(LispFunction)) void {
        for (map.keys()) |key| {
            const func = map.get(key);
            baseTable.put(key, func.?) catch @panic("Unexpected error when putting KV pair from static map to env map");
        }
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit();
        self.externalFnTable.deinit();
        self.internalFnTable.deinit();
        self.allocator.destroy(self);
    }

    pub fn init(allocator: std.mem.Allocator) *Self {
        const self = allocator.create(Self) catch @panic("OOM");

        const envData = std.StringHashMap(MalType).init(allocator);
        // Expected to modify the pointer through function to setup
        // initial function table.
        const baseFnTable = @constCast(&std.StringHashMap(LispFunction).init(allocator));
        readFromStaticMap(baseFnTable, data.EVAL_TABLE);

        const externalFnTable = std.StringHashMap(LispFunction).init(allocator);

        self.* = Self{
            .allocator = allocator,
            .data = envData,
            .internalFnTable = baseFnTable.*,
            .externalFnTable = externalFnTable,
        };

        self.logFnTable();

        return self;
    }

    fn logFnTable(self: *Self) void {
        var internalFnTableIter = self.internalFnTable.keyIterator();
        while (internalFnTableIter.next()) |key| {
            logz.info()
                .fmt("[LISP_ENV]", "internalFnTable fn: '{s}' set", .{key.*})
                .level(.Debug)
                .log();
        }

        var externalFnTableIter = self.externalFnTable.keyIterator();
        while (externalFnTableIter.next()) |key| {
            logz.info()
                .fmt("[LISP_ENV]", "externalFnTable fn: '{s}' set", .{key.*})
                .level(.Debug)
                .log();
        }
    }

    pub fn addFn(self: *Self, key: []const u8, value: LispFunction) !void {
        try self.externalFnTable.put(key, value);
    }

    /// apply function execute the function when the Lisp Object is in list
    /// type and the first item is in symbol.
    /// It checks if all the params on the layer needs further apply first,
    /// return the result to be the param.
    /// e.g. For (+ 1 2 (+ 2 3))
    /// -> (+ 1 2 5) ;; Eval (+ 2 3) in recursion
    /// -> 8
    /// TODO: Consider if continuous apply is suitable, possible and more scalable
    /// e.g. For (+ 1 2 (+ 2 3))
    /// -> (+ 3 (+ 2 3))         ;; Hit (+ 1 2), call add function with accum = 1 and param = 2
    /// -> (+ 3 5)               ;; Hit the list (+2 3); Eval (+ 2 3), perhaps in new thread?
    /// -> 8
    pub fn apply(self: *Self, mal: MalType) !MalType {
        var fnName: []const u8 = undefined;
        var mal_param: MalType = undefined;
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = gpa.allocator();

        var params = ArrayList(MalType).init(allocator);

        defer {
            params.deinit();
            const check = gpa.deinit();
            std.debug.assert(check == .ok);
        }

        const list = try mal.as_list();
        for (list.items, 0..) |_mal, i| {
            if (i == 0) {
                fnName = _mal.as_symbol() catch |err| switch (err) {
                    MalTypeError.IllegalType => {
                        utils.log("ERROR", "Invalid symbol type to apply");
                        return err;
                    },
                    else => {
                        utils.log("ERROR", "Unhandled error");
                        return err;
                    },
                };
                continue;
            }

            if (_mal.as_list()) |_| {
                // TODO: Need more assertion
                // Assume the return type fits with the function
                mal_param = try self.apply(_mal);
                if (mal_param == .Incompleted) {
                    return MalTypeError.IllegalType;
                }
            } else |_| {
                mal_param = _mal;
            }
            try params.append(mal_param);
        }
        if (self.internalFnTable.get(fnName)) |func| {
            const fnValue: MalType = try @call(.auto, func, .{params.items});
            return fnValue;
        } else {
            utils.log("SYMBOL", "Not implemented");
        }

        return .Incompleted;
    }
};

const testing = std.testing;

test "env" {
    const allocator = std.testing.allocator;

    var mal_list = ArrayList(MalType).init(allocator);
    defer mal_list.deinit();

    const plus = MalType{
        .symbol = "+",
    };

    const num1 = MalType{
        .number = .{ .value = 1 },
    };
    const num2 = MalType{
        .number = .{ .value = 2 },
    };

    try mal_list.append(plus);
    try mal_list.append(num1);
    try mal_list.append(num2);

    const plus1 = MalType{
        .list = mal_list,
    };

    {
        const env = LispEnv.init(allocator);
        defer env.deinit();

        const plus1_value = try env.apply(plus1);
        const plus1_value_number = plus1_value.as_number() catch unreachable;
        try testing.expectEqual(3, plus1_value_number.value);
    }
}
