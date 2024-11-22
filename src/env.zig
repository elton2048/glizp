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
    .{ "if", &ifFunc },
    .{ "lambda", &lambdaFuncUsingEnv },
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
        // NOTE: Using list for binding
        const list = try binding.as_list();

        _ = try set(list.items, newEnv);
    }

    return newEnv.apply(eval_arg);
}

fn ifFunc(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    const condition_arg = params[0];
    const statement_true = params[1];
    // NOTE: In elisp the last params corresponds to false case,
    // it is not the case right now.
    // i.e. (if (= 1 2) 1 2 3 4) => 4
    var statement_false: MalType = undefined;

    if (params.len == 1) {
        // TODO: Better error type
        return MalTypeError.IllegalType;
    }

    if (params.len == 2) {
        statement_false = MalType{ .boolean = false };
    } else {
        statement_false = params[2];
    }

    const condition = (try env.apply(condition_arg)).as_boolean() catch true;
    utils.log("IF", "return");
    if (!condition) {
        return env.apply(statement_false);
    }
    return env.apply(statement_true);
}

pub const Lambda = struct {
    allocator: std.mem.Allocator,
    params: []MalType,
    // inner_env: *LispEnv,
    inner_func: *const fn (*Lambda, []MalType, []MalType) MalTypeError!MalType,
    const Self = @This();
    // pub fn func(self: Lambda, inner_params: []MalType) MalTypeError!MalType {
    //     utils.log("INNER FUNC", self.params);
    //     utils.log("FUNC", inner_params[0]);

    //     return MalType{ .boolean = false };
    // }

    pub fn init(allocator: std.mem.Allocator, params: []MalType, func: *const fn (*Lambda, []MalType, []MalType) MalTypeError!MalType) *Lambda {
        const self = allocator.create(Self) catch @panic("OOM");

        self.* = Lambda{
            .allocator = allocator,
            .params = params,
            .inner_func = func,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }
};

fn lambdaFuncUsingEnv(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    const newEnv = LispEnv.init(env.allocator, env);
    // defer newEnv.deinit();

    const fn_params = try params[0].as_list();
    for (fn_params.items) |param| {
        const param_symbol = try param.as_symbol();
        env.addVar(param_symbol, .Undefined) catch unreachable;
    }

    const eval_params = try params[1].as_list();
    utils.log("func", eval_params.items[0]);
    // env.apply(eval_params);
    const inner_fn = struct {
        pub fn func(_params: []MalType) MalTypeError!MalType {
            utils.log("func with env", _params[0]);

            return MalType{ .boolean = false };
        }
    }.func;

    // TODO: Align the internal key for the function
    newEnv.addFn("_", &inner_fn) catch unreachable;

    return MalType{ .functionUsingEnv = newEnv };
}

// TODO
fn lambdaFunc(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    utils.log("LAMBDA", "enter");
    utils.log_pointer(params);
    utils.log_pointer(env);

    const _params = env.allocator.dupe(MalType, params) catch @panic("Unexpected OOM");
    utils.log_pointer(_params);
    // defer env.allocator.free(_params);

    const lambda = Lambda.init(env.allocator, _params, struct {
        pub fn func(inner_env: *Lambda, outer_params: []MalType, inner_params: []MalType) MalTypeError!MalType {
            utils.log_pointer(inner_env);
            utils.log_pointer(inner_env.params);
            const _fn_params = try inner_env.params[0].as_list();
            for (_fn_params.items) |param| {
                const symbol = try param.as_symbol();
                utils.log("INNER FUNC PARAMS", symbol);
            }

            const _fn_expression = try inner_env.params[1].as_list();
            for (_fn_expression.items) |param| {
                const symbol = try param.as_symbol();
                utils.log("INNER FUNC EXPRESSION", symbol);
            }

            // const lambda_params = try self.params.*[0].as_list();
            const fn_params = try outer_params[0].as_list();
            for (fn_params.items) |param| {
                const symbol = try param.as_symbol();
                utils.log("INNER FUNC", symbol);
            }
            // utils.log("INNER FUNC", outer_params[0]);
            // utils.log("INNER FUNC", self.params.*[0]);
            utils.log("FUNC", inner_params[0]);

            return MalType{ .boolean = false };
        }
    }.func);
    // TODO: When to deinit the struct pointer?
    // defer lambda.deinit();

    // lambda.params = @constCast(&_params);
    // utils.log_pointer(lambda.params);
    // utils.log("LAMBDA", lambda.params.*[0]);

    // lambda.inner_func = struct {
    //     pub fn func(outer_params: []MalType, inner_params: []MalType) MalTypeError!MalType {
    //         // utils.log_pointer(self.params);
    //         // const lambda_params = try self.params.*[0].as_list();
    //         const fn_params = try outer_params[0].as_list();
    //         for (fn_params.items) |param| {
    //             const symbol = try param.as_symbol();
    //             utils.log("INNER FUNC", symbol);
    //         }
    //         // utils.log("INNER FUNC", outer_params[0]);
    //         // utils.log("INNER FUNC", self.params.*[0]);
    //         utils.log("FUNC", inner_params[0]);

    //         return MalType{ .boolean = false };
    //     }
    // }.func;

    const newEnv = LispEnv.init(env.allocator, env);
    defer newEnv.deinit();

    const fn_params = try params[0].as_list();
    for (fn_params.items) |param| {
        const symbol = try param.as_symbol();
        utils.log("LAMBDA symbol", symbol);
    }

    const eval_expression = try params[1].as_list();
    _ = eval_expression;

    utils.log("LAMBDA", "return");
    // const _Lambda = struct {
    //     pub fn internal_func(inner_params: []MalType, outer_env: *LispEnv) MalTypeError!MalType {
    //         // const inner_env = LispEnv.init(outer_env.allocator, outer_env);
    //         // defer inner_env.deinit();

    //         utils.log("FUNC", inner_params[0]);
    //         return letX(inner_params, outer_env);
    //     }

    //     pub fn func(_inner_env: *LispEnv) LispFunction {
    //         _ = _inner_env;
    //         // utils.log("INNER FUNC", inner_env);
    //         return internal_func;
    //     }
    // };
    // _ = _Lambda;

    // lambda.* = Lambda{
    //     .inner_env = newEnv,
    //     .inner_func = &_Lambda.func(newEnv),
    // };
    // _ = lambda;
    return MalType{ .function = lambda };
    // return MalType{ .function = &_Lambda.internal_func };
}

pub const LispEnv = struct {
    outer: ?*LispEnv,
    allocator: std.mem.Allocator,
    data: std.StringHashMap(MalType),
    fnTable: lisp.LispHashMap(FunctionWithAttributes),

    const Self = @This();

    fn readFromStaticMap(baseTable: *lisp.LispHashMap(FunctionWithAttributes), map: std.StaticStringMap(LispFunction)) void {
        for (map.keys()) |key| {
            const optional_func = map.get(key);
            if (optional_func) |func| {
                const value = FunctionWithAttributes{
                    .type = .internal,
                    .func = GenericLispFunction{ .simple = func },
                };

                const lispKey = baseTable.allocator.create(MalType) catch @panic("OOM");
                defer baseTable.allocator.destroy(lispKey);

                lispKey.* = MalType{
                    .symbol = key,
                };

                baseTable.put(lispKey, value) catch @panic("Unexpected error when putting KV pair from static map to env map");
            }
        }
    }

    fn readFromEnvStaticMap(baseTable: *lisp.LispHashMap(FunctionWithAttributes), map: std.StaticStringMap(LispFunctionWithEnv)) void {
        for (map.keys()) |key| {
            const optional_func = map.get(key);
            if (optional_func) |func| {
                const value = FunctionWithAttributes{
                    .type = .internal,
                    .func = GenericLispFunction{ .with_env = func },
                };

                const lispKey = baseTable.allocator.create(MalType) catch @panic("OOM");
                defer baseTable.allocator.destroy(lispKey);

                lispKey.* = MalType{
                    .symbol = key,
                };

                baseTable.put(lispKey, value) catch @panic("Unexpected error when putting KV pair from static map to env map");
            }
        }
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit();
        self.fnTable.deinit();
        self.allocator.destroy(self);
    }

    pub fn init_root(allocator: std.mem.Allocator) *Self {
        const self = allocator.create(Self) catch @panic("OOM");

        const envData = std.StringHashMap(MalType).init(allocator);

        // Expected to modify the pointer through function to setup
        // initial function table.
        const fnTable = @constCast(&lisp.LispHashMap(FunctionWithAttributes).init(allocator));
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

        const fnTable = lisp.LispHashMap(FunctionWithAttributes).init(allocator);

        self.* = Self{
            .outer = outer,
            .allocator = allocator,
            .data = envData,
            .fnTable = fnTable,
        };

        return self;
    }

    fn logFnTable(self: *Self) void {
        var newfnTableIter = self.fnTable.hash_map.keyIterator();
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
        defer self.allocator.destroy(lispKey);
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
        defer self.allocator.destroy(lispKey);
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

    pub fn setVar(self: *Self, key: []const u8, value: MalType) !void {
        const var_exists = self.data.get(key);
        std.debug.assert(var_exists.? == .Undefined);

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
            // .function => |func| {
            //     // TODO: Shall return function symbol in print function
            // },
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
        var lambda_function_pointer: ?*LispEnv = null;
        // var lambda_function_pointer: ?*const fn (Lambda, []MalType) MalTypeError!MalType = null;
        // var lambda_function_pointer: ?LispFunctionWithEnv = null;
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
                utils.log("LOG", _mal);
                switch (_mal) {
                    .symbol => |symbol| {
                        fnName = symbol;
                    },
                    .function => |_lambda| {
                        _ = _lambda;
                        // utils.log("TEST", "1");
                        // lambda_function_pointer = _lambda.func;
                        // utils.log("TEST", "2");
                        // TODO: Stub to by-pass the further eval steps
                        // and proceed to generate params for the function.
                        // A more sophisticated way is preferred later
                        fnName = "";
                    },
                    .list => |_list| {
                        // TODO: Eval one more time to check if it is function to run
                        utils.log("LIST", _list.items[0]);
                        // TODO: Grap the MalType out and apply further.
                        const innerLisp = try self.applyList(_list);
                        utils.log("LIST b", innerLisp);
                        if (innerLisp.as_function()) |_lambda| {
                            lambda_function_pointer = _lambda;
                            fnName = "";
                        } else |_| {}
                        // const first_symbol = _list.items[0].as_symbol() catch |err| switch (err) {
                        //     MalTypeError.IllegalType => {
                        //         utils.log("ERROR", "Illegal type to be evaled");
                        //         return err;
                        //     },
                        //     else => {
                        //         utils.log("ERROR", "Unexpected error");
                        //         return err;
                        //     },
                        // };
                        // _ = first_symbol;
                    },
                    else => {
                        utils.log("ERROR", "Illegal type to be evaled");
                        return MalTypeError.IllegalType;
                    },
                }
                continue;
            }

            // TODO: Simple, lazy and hacky way for checking "special" form
            if (std.hash_map.eqlString(fnName, "lambda")) {
                mal_param = _mal;
            } else

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
                        if (std.hash_map.eqlString("lambda", try key.as_symbol())) {
                            utils.log("parse lambda", params.items[0]);
                        }
                        fnValue = try @call(.auto, env_func, .{ params.items, self });
                    },
                }

                return fnValue;
            }

            // TODO
            else if (lambda_function_pointer) |lambda| {
                utils.log("run lambda", "1");
                // TODO: Align the internal key for the function
                var _key = MalType{ .symbol = "_" };
                const optional_funcWithAttr = lambda.fnTable.get(&_key);
                if (optional_funcWithAttr) |funcWithAttr| {
                    const func = funcWithAttr.func;
                    var fnValue: MalType = undefined;

                    switch (func) {
                        .simple => |simple_func| {
                            fnValue = try @call(.auto, simple_func, .{params.items});
                        },
                        else => unreachable,
                    }
                    // utils.log_pointer(lambda.inner_func);
                    // utils.log("ENTER LAMBDA LOG", params.items[0]);
                    // utils.log("ENTER LAMBDA LOG", lambda.params.*[0]);
                    // const fnValue = try @call(.auto, lambda.inner_func, .{ lambda, lambda.params, params.items });
                    utils.log("LOG", fnValue);
                    return fnValue;
                }
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
