const std = @import("std");
const logz = @import("logz");

const ArrayList = std.ArrayList;

const data = @import("data.zig");
const utils = @import("utils.zig");

const MalType = @import("reader.zig").MalType;
const MalTypeError = @import("reader.zig").MalTypeError;
const LispFunction = @import("reader.zig").LispFunction;

/// Pointer to the global environment, this is required as the function signature
/// is fixed for all LispFunction. And it is require to access the environment
/// for case like defining functions and variables.
/// There is no guarantee such pointer exists anyway, but the program
/// shall be inited with the LispEnv before accessing any lisp functions.
/// NOTE: Check src/lisp.h#L578 for Lisp_Object in Emacs
/// REVIEW below
/// NOTE: In original Emacs case there is a global pointer which counts for all
/// lisp symbols in runtime.
pub var global_env_ptr: *const anyopaque = undefined;

pub const SPECIAL_EVAL_TABLE = std.StaticStringMap(LispFunction).initComptime(.{
    // According to MAL, not in Emacs env
    .{ "def!", &set },
});

fn set(params: []MalType) MalTypeError!MalType {
    // TODO: Access to current env
    const env: *LispEnv = @constCast(@ptrCast(@alignCast(global_env_ptr)));

    const key = try params[0].as_symbol();
    const value = env.apply(params[1]) catch |err| switch (err) {
        error.IllegalType => return MalTypeError.IllegalType,
        error.Unhandled => return MalTypeError.Unhandled,
    };

    env.addVar(key, value) catch |err| switch (err) {
        error.OutOfMemory => return MalTypeError.IllegalType,
    };

    return value;
}

fn get(params: []MalType) MalTypeError!MalType {
    // TODO: Access to current env
    const env: *LispEnv = @constCast(@ptrCast(@alignCast(global_env_ptr)));

    const key = try params[0].as_symbol();

    return env.getVar(key);
}

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
        readFromStaticMap(baseFnTable, SPECIAL_EVAL_TABLE);

        const externalFnTable = std.StringHashMap(LispFunction).init(allocator);

        self.* = Self{
            .allocator = allocator,
            .data = envData,
            .internalFnTable = baseFnTable.*,
            .externalFnTable = externalFnTable,
        };

        self.logFnTable();

        global_env_ptr = self;

        return self;
    }

    fn logFnTable(self: *Self) void {
        var internalFnTableIter = self.internalFnTable.keyIterator();
        while (internalFnTableIter.next()) |key| {
            logz.info()
                .fmt("[LISP_ENV]", "internalFnTable fn: '{s}' set.", .{key.*})
                .level(.Debug)
                .log();
        }

        var externalFnTableIter = self.externalFnTable.keyIterator();
        while (externalFnTableIter.next()) |key| {
            logz.info()
                .fmt("[LISP_ENV]", "externalFnTable fn: '{s}' set.", .{key.*})
                .level(.Debug)
                .log();
        }
    }

    pub fn addFn(self: *Self, key: []const u8, value: LispFunction) !void {
        try self.externalFnTable.put(key, value);
    }

    pub fn addVar(self: *Self, key: []const u8, value: MalType) !void {
        try self.data.put(key, value);
    }

    pub fn getVar(self: *Self, key: []const u8) !MalType {
        const optional_value = self.data.get(key);

        if (optional_value) |value| {
            return value;
        } else {
            // TODO: Shall return error signal
            return MalType{ .boolean = false };
        }
    }

    pub fn removeVar(self: *Self, key: []const u8) void {
        const success = try self.data.remove(key);
        if (success) {
            logz.info()
                .fmt("[LISP_ENV]", "var: '{s}' is removed.", .{key})
                .level(.Debug)
                .log();
        } else {
            logz.info()
                .fmt("[LISP_ENV]", "var: '{s}' is not found.", .{key})
                .level(.Debug)
                .log();
        }
    }

    /// apply function returns the Lisp object according to the type of
    /// the object. It evals further when it is a list or symbol.
    ///
    /// For list, it evals in the runtime environment and return the result.
    /// For symbol, it checks if the environment contains such value and
    /// return accordingly.
    pub fn apply(self: *Self, mal: MalType) !MalType {
        switch (mal) {
            .list => |list| {
                return self.applyList(list);
            },
            .symbol => |symbol| {
                return self.getVar(symbol);
            },
            else => return mal,
        }
    }

    /// Apply function for a list, which eval the list and return the result,
    /// it takes the first param (which should be in symbol form) as
    /// function name and apply latter to be params.
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
    fn applyList(self: *Self, list: ArrayList(MalType)) MalTypeError!MalType {
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

            // TODO: Simple, lazy and hacky way for checking "special" form
            if (SPECIAL_EVAL_TABLE.has(fnName)) {
                switch (_mal) {
                    .list => {
                        // TODO: Need more assertion
                        // Assume the return type fits with the function
                        mal_param = try self.apply(_mal);
                        if (mal_param == .Incompleted) {
                            return MalTypeError.IllegalType;
                        }
                    },
                    else => {
                        mal_param = _mal;
                    },
                }
            } else {
                switch (_mal) {
                    .list, .symbol => {
                        // TODO: Need more assertion
                        // Assume the return type fits with the function
                        mal_param = try self.apply(_mal);
                        if (mal_param == .Incompleted) {
                            return MalTypeError.IllegalType;
                        }
                    },
                    else => {
                        mal_param = _mal;
                    },
                }
            }

            params.append(mal_param) catch |err| switch (err) {
                // TODO: Meaningful error for such case
                error.OutOfMemory => return MalTypeError.Unhandled,
            };
        }

        // NOTE: Shall use the internal one instead? Though no big difference now
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
