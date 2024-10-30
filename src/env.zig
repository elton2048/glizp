const std = @import("std");
const logz = @import("logz");

const ArrayList = std.ArrayList;

const data = @import("data.zig");
const utils = @import("utils.zig");

const lisp = @import("types/lisp.zig");
const MalType = lisp.MalType;
const MalTypeError = lisp.MalTypeError;
const LispFunction = lisp.LispFunction;
const LispFunctionWithEnv = lisp.LispFunctionWithEnv;
const GenericLispFunction = lisp.GenericLispFunction;

/// Pointer to the global environment, this is required as the function signature
/// is fixed for all LispFunction. And it is require to access the environment
/// for case like defining functions and variables.
/// There is no guarantee such pointer exists anyway, but the program
/// shall be inited with the LispEnv before accessing any lisp functions.
/// NOTE: Check src/lisp.h#L578 for Lisp_Object in Emacs
pub var global_env_ptr: *const anyopaque = undefined;
// const global_env: *LispEnv = @constCast(@ptrCast(@alignCast(global_env_ptr)));

pub const SPECIAL_ENV_EVAL_TABLE = std.StaticStringMap(LispFunctionWithEnv).initComptime(.{
    // According to MAL, not in Emacs env
    .{ "def!", &set },
    .{ "let*", &letX },
});

pub const FunctionType = union(enum) {
    /// Denote the function is defined in core system.
    internal,
    /// Denote the function is defined in from Lisp.
    external,
};

pub const FunctionWithAttributes = struct {
    type: FunctionType,
    func: GenericLispFunction,
};

fn set(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    std.debug.assert(params.len == 2);

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

fn get(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    const key = try params[0].as_symbol();

    return env.getVar(key);
}

fn letX(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    const binding_arg = params[0];
    const eval_arg = params[1];

    const bindings = try binding_arg.as_list();

    const newEnv = LispEnv.init(env.allocator, env);
    defer newEnv.deinit();

    for (bindings.items) |binding| {
        const list = try binding.as_list();

        _ = try set(list.items, newEnv);
    }

    return newEnv.apply(eval_arg);
}

pub const LispEnv = struct {
    outer: ?*LispEnv,
    allocator: std.mem.Allocator,
    data: std.StringHashMap(MalType),
    fnTable: lisp.MalTypeHashMap(FunctionWithAttributes),

    const Self = @This();

    fn readFromStaticMap(baseTable: *lisp.MalTypeHashMap(FunctionWithAttributes), map: std.StaticStringMap(LispFunction)) void {
        for (map.keys()) |key| {
            const optional_func = map.get(key);
            if (optional_func) |func| {
                const value = FunctionWithAttributes{
                    .type = .internal,
                    .func = GenericLispFunction{ .simple = func },
                };
                const lispKey = baseTable.allocator.create(MalType) catch @panic("OOM");
                lispKey.* = MalType{
                    .symbol = key,
                };

                baseTable.put(lispKey, value) catch @panic("Unexpected error when putting KV pair from static map to env map");
            }
        }
    }

    fn readFromEnvStaticMap(baseTable: *lisp.MalTypeHashMap(FunctionWithAttributes), map: std.StaticStringMap(LispFunctionWithEnv)) void {
        for (map.keys()) |key| {
            const optional_func = map.get(key);
            if (optional_func) |func| {
                const value = FunctionWithAttributes{
                    .type = .internal,
                    .func = GenericLispFunction{ .with_env = func },
                };
                const lispKey = baseTable.allocator.create(MalType) catch @panic("OOM");
                lispKey.* = MalType{
                    .symbol = key,
                };

                baseTable.put(lispKey, value) catch @panic("Unexpected error when putting KV pair from static map to env map");
            }
        }
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit();
        var fnTableIter = self.fnTable.iterator();
        while (fnTableIter.next()) |func| {
            self.fnTable.allocator.destroy(func.key_ptr.*);
        }
        self.fnTable.deinit();
        self.allocator.destroy(self);
    }

    pub fn init_root(allocator: std.mem.Allocator) *Self {
        const self = allocator.create(Self) catch @panic("OOM");

        const envData = std.StringHashMap(MalType).init(allocator);
        // Expected to modify the pointer through function to setup
        // initial function table.
        const fnTable = @constCast(&lisp.MalTypeHashMap(FunctionWithAttributes).init(allocator));
        readFromStaticMap(fnTable, data.EVAL_TABLE);
        readFromEnvStaticMap(fnTable, SPECIAL_ENV_EVAL_TABLE);

        self.* = Self{
            .outer = null,
            .allocator = allocator,
            .data = envData,
            .fnTable = fnTable.*,
        };

        self.logFnTable();

        global_env_ptr = self;

        return self;
    }

    fn init(allocator: std.mem.Allocator, outer: *Self) *Self {
        const self = allocator.create(Self) catch @panic("OOM");

        const envData = std.StringHashMap(MalType).init(allocator);

        const fnTable = lisp.MalTypeHashMap(FunctionWithAttributes).init(allocator);

        self.* = Self{
            .outer = outer,
            .allocator = allocator,
            .data = envData,
            .fnTable = fnTable,
        };

        return self;
    }

    fn logFnTable(self: *Self) void {
        var newfnTableIter = self.fnTable.keyIterator();
        while (newfnTableIter.next()) |key| {
            const symbol = key.*.as_symbol() catch @panic("Unexpected non-symbol key value");

            logz.info()
                .fmt("[LISP_ENV]", "fnTable fn: '{s}' set.", .{symbol})
                .level(.Debug)
                .log();
        }
    }

    pub fn addFn(self: *Self, key: []const u8, value: LispFunction) !void {
        const lispKey = try self.allocator.create(MalType);
        lispKey.* = MalType{
            .symbol = key,
        };

        const inputValue = GenericLispFunction{ .simple = value };
        try self.fnTable.put(lispKey, .{
            .func = inputValue,
            .type = .external,
        });
    }

    pub fn addFnWithEnv(self: *Self, key: []const u8, value: LispFunctionWithEnv) !void {
        const lispKey = try self.allocator.create(MalType);
        lispKey.* = MalType{
            .symbol = key,
        };

        const inputValue = GenericLispFunction{ .with_env = value };
        try self.fnTable.put(lispKey, .{
            .func = inputValue,
            .type = .external,
        });
    }

    pub fn addVar(self: *Self, key: []const u8, value: MalType) !void {
        try self.data.put(key, value);
    }

    pub fn getVar(self: *Self, key: []const u8) !MalType {
        var optional_env: ?*LispEnv = self;

        while (optional_env) |env| {
            const optional_value = env.data.get(key);

            if (optional_value) |value| {
                return value;
            }
            optional_env = env.outer;
        }

        // TODO: Return error signal
        return MalType{ .boolean = false };
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
            if (std.hash_map.eqlString(fnName, "let*")) {
                mal_param = _mal;
            } else

            // TODO: Simple, lazy and hacky way for checking "special" form
            if (SPECIAL_ENV_EVAL_TABLE.has(fnName)) {
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

        var optional_env: ?*LispEnv = self;

        while (optional_env) |env| {
            var key = MalType{ .symbol = fnName };
            if (env.fnTable.get(&key)) |funcWithAttr| {
                const func = funcWithAttr.func;
                var fnValue: MalType = undefined;
                switch (func) {
                    .simple => |simple_func| {
                        fnValue = try @call(.auto, simple_func, .{params.items});
                    },
                    .with_env => |env_func| {
                        fnValue = try @call(.auto, env_func, .{ params.items, self });
                    },
                }

                return fnValue;
            }
            optional_env = env.outer;
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
        const env = LispEnv.init_root(allocator);
        defer env.deinit();

        const plus1_value = try env.apply(plus1);
        const plus1_value_number = plus1_value.as_number() catch unreachable;
        try testing.expectEqual(3, plus1_value_number.value);
    }
}
