/// Test for the environment using pointer for lisp apply function,
/// based on env implementation
const std = @import("std");
const builtin = @import("builtin");
const logz = @import("logz");

const xev = @import("xev");

const ArrayList = std.ArrayList;

const data = @import("data_ptr.zig");
const utils = @import("utils.zig");
const fs = @import("fs.zig");
const Reader = @import("reader.zig").Reader;

const lisp = @import("types/lisp.zig");
const MalType = lisp.MalType;
const MalTypeError = lisp.MalTypeError;
const LispFunction = lisp.LispFunction;
const LispFunctionWithEnv = lisp.LispFunctionWithEnv;
const LispFunctionPtrWithEnv = lisp.LispFunctionPtrWithEnv;
const LispFunctionWithTail = lisp.LispFunctionWithTail;
const LispFunctionWithOpaque = lisp.LispFunctionWithOpaque;
const GenericLispFunction = lisp.GenericLispFunction;

const MessageQueue = @import("message_queue.zig").MessageQueue;

const PrefixStringHashMap = @import("prefix-string-hash-map.zig").PrefixStringHashMap;

const Plugin = @import("types/plugin.zig");

const PluginHashMap = std.StringHashMap(Plugin);

const STOCK_REFERENCE = "stock";

pub const FunctionType = union(enum) {
    /// Denote the function is defined in core system.
    internal,
    /// Denote the function is defined in from Lisp.
    external,
};

pub const FunctionWithAttributes = struct {
    type: FunctionType,
    func: GenericLispFunction,
    reference: []const u8,
};

const LAMBDA_FUNCTION_INTERNAL_VARIABLE_KEY = "LAMBDA_FUNCTION_INTERNAL_VARIABLE_KEY";
const LAMBDA_FUNCTION_INTERNAL_FUNCTION_KEY = "LAMBDA_FUNCTION_INTERNAL_FUNCTION_KEY";

pub const SPECIAL_ENV_EVAL_TABLE = std.StaticStringMap(LispFunctionPtrWithEnv).initComptime(.{
    // According to MAL, not in Emacs env
    .{ "def!", &set },
    .{ "let*", &letX },

    // TODO: See if need to extract this out?
    .{ "list", &listFunc },
    .{ "listp", &isListFunc },

    .{ "vector", &vectorFunc },
    .{ "aref", &arefFunc },

    // NOTE: lread.c in original Emacs
    // Original "load" function includes to read and execute a file of Lisp code
    // Whereas this just loads the content
    .{ "fs-load", &fsLoadFunc },
    .{ "load", &loadFunc },
});

fn set(params: []*MalType, env: *LispEnv) MalTypeError!*MalType {
    std.debug.assert(params.len == 2);

    const key = try params[0].as_symbol();
    const eval_value = params[1];
    eval_value.incref();
    const value = env.apply(eval_value, false) catch |err| switch (err) {
        error.IllegalType => return MalTypeError.IllegalType,
        error.Unhandled => return MalTypeError.Unhandled,
        else => return MalTypeError.Unhandled,
    };

    env.addVar(key, value) catch |err| switch (err) {
        error.OutOfMemory => return MalTypeError.IllegalType,
    };

    return value;
}

fn get(params: []*MalType, env: *LispEnv) MalTypeError!*MalType {
    const key = try params[0].as_symbol();

    return env.getVar(key);
}

fn letX(params: []*MalType, env: *LispEnv) MalTypeError!*MalType {
    const binding_arg = params[0];
    const eval_arg = params[1];

    binding_arg.incref();
    eval_arg.incref();

    utils.log("letX", "binding: {any}; eval: {any}", .{ binding_arg, eval_arg }, .{ .test_only = true });

    const bindings = try binding_arg.as_list();

    // NOTE: All envs are now deinit along with the root one.
    // The init function hooks the env back to the new one, which allows
    // newly created env to be accessed by the root.
    const newEnv = LispEnv.init(env.allocator, env);

    for (bindings.items) |binding| {
        // NOTE: Using list for binding
        const list = try binding.as_list_ptr();

        _ = try set(list.items, newEnv);
    }

    return newEnv.apply(eval_arg, false);
}

fn listLikeFunc(params: *MalType) MalTypeError!*MalType {
    if (params.as_list()) |_| {
        return @constCast(&MalType{ .boolean = true });
    } else |_| {
        return @constCast(&MalType{ .boolean = false });
    }

    return @constCast(&MalType{ .boolean = false });
}

fn listFunc(params: []*MalType, env: *LispEnv) MalTypeError!*MalType {
    var list = ArrayList(*MalType).init(env.allocator);

    for (params) |param| {
        const mal_param = param;
        mal_param.incref();
        utils.log("listFunc", "{*}; {any}", .{ mal_param, mal_param }, .{ .color = .Green });
        list.append(mal_param) catch @panic("test");
    }

    const mal = MalType.new_list_ptr(env.allocator, list);

    return mal;
}

fn isListFunc(params: []*MalType, env: *LispEnv) MalTypeError!*MalType {
    // TODO: return better error.
    std.debug.assert(params.len == 1);

    const result = get(params, env) catch |err| switch (err) {
        error.IllegalType => blk: {
            break :blk params[0];
        },
        else => {
            return err;
        },
    };
    return listLikeFunc(result);
}

fn vectorFunc(params: []*MalType, env: *LispEnv) MalTypeError!*MalType {
    var vector = ArrayList(*MalType).init(env.allocator);

    vector.insertSlice(0, params) catch |err| switch (err) {
        error.OutOfMemory => return MalTypeError.IllegalType,
    };

    const mal = MalType.new_vector_ptr(env.allocator, vector);

    return mal;
}

fn arefFunc(params: []*MalType, env: *LispEnv) MalTypeError!*MalType {
    const array = get(params, env) catch |err| switch (err) {
        error.IllegalType => blk: {
            break :blk params[0];
        },
        else => {
            return err;
        },
    };
    const vector = try array.as_vector_ptr();
    const index_num = try params[1].as_number();
    const index = try index_num.to_usize();

    var result: *MalType = @constCast(&MalType{ .boolean = false });

    if (index < vector.items.len) {
        result = vector.items[index];
    }

    return result;
}

fn fsLoadFunc(params: []*MalType, env: *LispEnv) MalTypeError!*MalType {
    std.debug.assert(params.len == 1);

    const sub_path = try params[0].as_string();

    const result = fs.loadFile(env.allocator, sub_path.items) catch |err| switch (err) {
        error.FileNotFound => return MalTypeError.FileNotFound,
        else => return MalTypeError.Unhandled,
    };

    const al_result = ArrayList(u8).fromOwnedSlice(env.allocator, result);

    const mal_ptr = env.allocator.create(MalType) catch @panic("OOM");
    mal_ptr.* = MalType.new_string(al_result);

    return mal_ptr;
}

fn loadFunc(params: []*MalType, env: *LispEnv) MalTypeError!*MalType {
    // NOTE: The content shall be holded within the whole env,
    // therefore the deinit process should not be done within the function,
    // but in the env deinit part. Otherwise there will be memory corruption
    // for non-primitive type.
    // One common case is to set variable in the env, For example setting "a" to 1.
    // Since string is in the form of character pointer, it is not a primitive type.
    // In this case the key "a" is the character pointer. If the pointer content
    // is clear, the corresponding key will be invalidated as well, causing
    // getting key "a" returns no value.
    const file_content = try fsLoadFunc(params, env);

    env.internalData.append(file_content) catch |err| switch (err) {
        // TODO: Meaningful error for such case
        error.OutOfMemory => return MalTypeError.Unhandled,
    };

    const content = try file_content.as_string();
    const reader = Reader.init(env.allocator, content.items);
    // defer reader.deinit();

    const result = try env.apply(reader.ast_root, false);

    return result;
}

pub const LispEnv = struct {
    // Inner reference, used for root to deinit all environments.
    inner: ?*LispEnv,
    outer: ?*LispEnv,
    allocator: std.mem.Allocator,
    data: std.StringHashMap(*MalType),
    fnTable: lisp.LispHashMap(FunctionWithAttributes),
    // Internal storage for data parsed outside
    internalData: ArrayList(*MalType),
    // Data collection point which holds the reference, intends to be a
    // garbage collector.
    dataCollector: PrefixStringHashMap(*MalType),
    plugins: PluginHashMap,
    messageQueue: *MessageQueue,

    const Self = @This();

    const dataCollectorKeyPrefix = "__data-collector";

    fn generateFunctionWithAttributes(comptime T: type, func: T, reference: []const u8) FunctionWithAttributes {
        var value: FunctionWithAttributes = undefined;
        switch (T) {
            LispFunction => {
                value = .{
                    .type = .internal,
                    .func = .{ .simple = func },
                    .reference = reference,
                };
            },
            LispFunctionWithEnv => {
                value = .{
                    .type = .internal,
                    .func = .{ .with_env = func },
                    .reference = reference,
                };
            },
            LispFunctionPtrWithEnv => {
                value = .{
                    .type = .internal,
                    .func = .{ .with_ptr = func },
                    .reference = reference,
                };
            },
            LispFunctionWithTail => {
                value = .{
                    .type = .internal,
                    .func = .{ .with_tail = func },
                    .reference = reference,
                };
            },
            LispFunctionWithOpaque => {
                value = .{
                    .type = .external,
                    .func = .{ .plugin = func },
                    .reference = reference,
                };
            },
            else => @panic("Not implemented"),
        }

        return value;
    }

    fn readFromFnMap(
        comptime T: type,
        baseTable: *lisp.LispHashMap(FunctionWithAttributes),
        map: std.StaticStringMap(T),
        reference: []const u8,
    ) void {
        for (map.keys()) |key| {
            const optional_func = map.get(key);
            if (optional_func) |func| {
                const value = generateFunctionWithAttributes(T, func, reference);

                const lispKey = MalType.new_symbol(baseTable.allocator, key);
                defer lispKey.deinit();

                baseTable.put(lispKey, value) catch @panic("Unexpected error when putting KV pair from static map to env map");
            }
        }
    }

    fn init(allocator: std.mem.Allocator, outer: *Self) *Self {
        const self = allocator.create(Self) catch @panic("OOM");

        const envData = std.StringHashMap(*MalType).init(allocator);

        var fnTable = lisp.LispHashMap(FunctionWithAttributes).init(allocator);

        var outEnvFnTableIter = outer.fnTable.hash_map.iterator();

        while (outEnvFnTableIter.next()) |entry| {
            fnTable.put(entry.key_ptr.*, entry.value_ptr.*) catch @panic("OOM");
        }

        const internalData = ArrayList(*MalType).init(allocator);

        const dataCollector = PrefixStringHashMap(*MalType).init(allocator, dataCollectorKeyPrefix);

        const plugins = PluginHashMap.init(allocator);

        const messageQueue = MessageQueue.initSPSC(allocator);

        self.* = Self{
            .inner = null,
            .outer = outer,
            .allocator = allocator,
            .data = envData,
            .fnTable = fnTable,
            .internalData = internalData,
            .dataCollector = dataCollector,
            .plugins = plugins,
            .messageQueue = messageQueue,
        };

        outer.inner = self;

        return self;
    }

    // Public functions

    /// Register plugin. This will provide the environment data and message
    /// queue to the plugin such that it allows the plugin to access such
    /// information. The plugin shall implement its fnTable in
    /// "std.StaticStringMap(LispFunctionWithOpaque)" type to denote
    /// extra functions within the plugin.
    /// The lisp functions denoted will be added into the lisp environment.
    /// When these functions executeds, the corresponding plugin will be
    /// pluged in, allowing data manipulation on the plugin.
    /// TODO - Way to check if the plugin fulfills some requirement?
    pub fn registerPlugin(self: *Self, extension: anytype) !void {
        // TODO: Any way to check the extension fulfilling the requirement?
        const plugin = Plugin.init(extension, &self.data, self.messageQueue);

        logz.info()
            .fmt("[LISP_ENV]", "Plugin name: '{s}' registered.", .{plugin.name})
            .level(.Debug)
            .log();

        self.plugins.put(plugin.name, plugin) catch |err| switch (err) {
            error.OutOfMemory => {},
        };

        // Put the plugin functions in the lisp environment
        if (plugin.fnTable) |fnTable| {
            readFromFnMap(LispFunctionWithOpaque, &self.fnTable, fnTable, plugin.name);
        }
    }

    pub fn deinit(self: *Self) void {
        utils.log("deinit for env", "===with inner: {any}===", .{self.inner != null}, .{ .color = .BrightGreen });

        // Deinit the env. Note that it is likely means it is for root
        // case.
        // For lambda function, it returns the Lisp object with function
        // type, which holds the env, as a result this makes the deinit
        // of the type conflicts, as a result disable the corresponding case.
        var inner_env = self.inner;
        while (inner_env) |env| {
            defer env.deinit();

            inner_env = env.inner;
            env.inner = null;
        }

        self.messageQueue.deinit();
        var dataIter = self.data.iterator();
        while (dataIter.next()) |item| {
            // For lambda variables, they are deinit within the function.
            if (!std.mem.eql(u8, item.key_ptr.*, LAMBDA_FUNCTION_INTERNAL_VARIABLE_KEY)) {
                item.value_ptr.*.decref();
            }
        }
        self.data.deinit();

        self.fnTable.deinit();
        for (self.internalData.items) |item| {
            item.deinit();
        }
        self.internalData.deinit();
        var iter = self.dataCollector.iterator();
        while (iter.next()) |item| {
            // Only free those with implicit keys. i.e. not created from user
            // directly
            if (std.mem.startsWith(u8, item.key_ptr.*, dataCollectorKeyPrefix)) {
                self.allocator.free(item.key_ptr.*);
            }
            utils.log("DATA COLLECTOR", "{*}; {any}", .{ item.value_ptr.*, item.value_ptr.* }, .{});
            // NOTE: causing trace trap for let* case
            item.value_ptr.*.decref();
        }
        self.dataCollector.deinit();
        self.allocator.destroy(self);
    }

    pub fn init_root(allocator: std.mem.Allocator) *Self {
        const self = allocator.create(Self) catch @panic("OOM");

        const envData = std.StringHashMap(*MalType).init(allocator);

        const messageQueue = MessageQueue.initSPSC(allocator);

        const plugins = PluginHashMap.init(allocator);

        // Expected to modify the pointer through function to setup
        // initial function table.
        const fnTable = @constCast(&lisp.LispHashMap(FunctionWithAttributes).init(allocator));
        readFromFnMap(LispFunction, fnTable, data.EVAL_TABLE, STOCK_REFERENCE);
        readFromFnMap(LispFunctionPtrWithEnv, fnTable, SPECIAL_ENV_EVAL_TABLE, STOCK_REFERENCE);
        // readFromFnMap(LispFunctionWithTail, fnTable, SPECIAL_ENV_WITH_TAIL_EVAL_TABLE, STOCK_REFERENCE);

        const internalData = ArrayList(*MalType).init(allocator);

        const dataCollector = PrefixStringHashMap(*MalType).init(allocator, dataCollectorKeyPrefix);

        self.* = Self{
            .inner = null,
            .outer = null,
            .allocator = allocator,
            .data = envData,
            .fnTable = fnTable.*,
            .internalData = internalData,
            .dataCollector = dataCollector,
            .plugins = plugins,
            .messageQueue = messageQueue,
        };

        // self.logFnTable();

        // NOTE: Thread loop is not in test scope now.
        // const threadData = ThreadData{
        //     .data = 0,
        //     .messageQueue = messageQueue,
        //     .plugins = &self.plugins,
        // };

        // // Test for another thread
        // const loop_thread = std.Thread.spawn(.{}, loop_thread_func, .{threadData}) catch @panic("testing");
        // loop_thread.detach();

        return self;
    }

    pub fn addVar(self: *Self, key: []const u8, value: *MalType) !void {
        try self.data.put(key, value);
    }

    pub fn setVar(self: *Self, key: []const u8, value: *MalType) !void {
        const var_exists = self.data.get(key);
        std.debug.assert(var_exists.? == .Undefined);

        try self.data.put(key, value);
    }

    pub fn getVar(self: *Self, key: []const u8) !*MalType {
        var optional_env: ?*LispEnv = self;

        while (optional_env) |env| {
            const optional_value = env.data.get(key);

            if (optional_value) |value| {
                return value;
            }
            optional_env = env.outer;
        }

        // TODO: Return error signal
        return @constCast(&MalType{ .boolean = false });
    }

    pub fn removeVar(self: *Self, key: []const u8) void {
        const success = self.data.remove(key);
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

    pub fn apply(self: *Self, mal: *MalType, nested: bool) !*MalType {
        _ = nested;

        base: while (true) {
            switch (mal.*) {
                .list => |list| {
                    // Apply function for a list, which eval the list and return the result,
                    // it takes the first param (which should be in symbol form) as
                    // function name and apply latter to be params.
                    // It checks if all the params on the layer needs further apply first,
                    // return the result to be the param.
                    // e.g. For (+ 1 2 (+ 2 3))
                    // -> (+ 1 2 5) ;; Eval (+ 2 3) in recursion
                    // -> 8
                    // TODO: Consider if continuous apply is suitable, possible and more scalable
                    // e.g. For (+ 1 2 (+ 2 3))
                    // -> (+ 3 (+ 2 3))         ;; Hit (+ 1 2), call add function with accum = 1 and param = 2
                    // -> (+ 3 5)               ;; Hit the list (+2 3); Eval (+ 2 3), perhaps in new thread?
                    // -> 8

                    var fnName: []const u8 = undefined;
                    var mal_ptr_param: *MalType = undefined;
                    // var lambda_function_pointer: ?*LispEnv = null;
                    const lambda_func_run_checker: bool = true;
                    const allocator = self.allocator;

                    var ptr_params = ArrayList(*MalType).init(allocator);
                    defer {
                        logz.info()
                            .fmt("[apply] deinit", "", .{})
                            .level(.Debug)
                            .log();

                        // Pop all the items out and put into data collector
                        // deinit the array list

                        // ---------------
                        while (ptr_params.pop()) |item| {
                            utils.log("ptr_params", "{any}", .{item}, .{ .color = .BrightWhite, .test_only = true });
                            switch (item.*) {
                                .list => {
                                    self.dataCollector.put(item) catch unreachable;
                                },
                                else => {},
                            }
                        }
                        // ---------------
                        ptr_params.deinit();
                    }

                    for (list.data.items, 0..) |mal_item, i| {
                        if (i == 0) {
                            switch (mal_item.*) {
                                .symbol => |symbol| {
                                    fnName = symbol.data;
                                },
                                .function => |_lambda| {
                                    _ = _lambda;
                                    // TODO: Stub to by-pass the further eval steps
                                    // and proceed to generate params for the function.
                                    // A more sophisticated way is preferred later
                                    fnName = "";
                                },
                                .list => |_list| {
                                    _ = _list;
                                    const innerLisp = try self.apply(mal_item, true);
                                    if (innerLisp.as_function()) |_lambda| {
                                        _ = _lambda;
                                        // lambda_function_pointer = _lambda;
                                        fnName = "";
                                    } else |_| {}
                                },
                                else => {
                                    utils.log("ERROR", "Illegal type to be evaled", .{}, .{ .color = .Red });
                                    return MalTypeError.IllegalType;
                                },
                            }

                            continue;
                        }

                        // TODO: Simple and lazy way for checking "special" form
                        if (std.hash_map.eqlString(fnName, "let*")) {
                            mal_ptr_param = mal_item;
                        } else

                        // TODO: Simple and lazy way for checking "special" form
                        if (std.hash_map.eqlString(fnName, "def!")) {
                            switch (mal_item.*) {
                                .list => {
                                    // for def! case, should not eval the list
                                    mal_ptr_param = mal_item;
                                    // // TODO: Need more assertion
                                    // // Assume the return type fits with the function
                                    // mal_ptr_param = try self.apply(_mal, false);

                                    // if (mal_ptr_param == .Incompleted) {
                                    //     return MalTypeError.IllegalType;
                                    // }
                                },
                                else => {
                                    mal_ptr_param = mal_item;
                                },
                            }
                        } else

                        // TODO: Simple and lazy way for checking "special" form
                        if (SPECIAL_ENV_EVAL_TABLE.has(fnName)) {
                            switch (mal_item.*) {
                                .list => {
                                    // TODO: Need more assertion
                                    // Assume the return type fits with the function
                                    mal_ptr_param = try self.apply(mal_item, false);

                                    if (mal_ptr_param.* == .Incompleted) {
                                        return MalTypeError.IllegalType;
                                    }
                                },
                                else => {
                                    mal_ptr_param = mal_item;
                                },
                            }
                        } else {
                            switch (mal_item.*) {
                                .list, .symbol => {
                                    // TODO: Need more assertion
                                    // Assume the return type fits with the function
                                    mal_ptr_param = try self.apply(mal_item, false);

                                    if (mal_ptr_param.* == .Incompleted) {
                                        return MalTypeError.IllegalType;
                                    }
                                },
                                else => {
                                    mal_ptr_param = mal_item;
                                },
                            }
                        }

                        ptr_params.append(mal_ptr_param) catch |err| switch (err) {
                            error.OutOfMemory => return MalTypeError.Unhandled,
                        };
                    }

                    var optional_env: ?*LispEnv = self;

                    while (optional_env) |env| {
                        logz.info()
                            .fmt("[env_test]", "{s}", .{fnName})
                            .level(.Debug)
                            .log();

                        var key = MalType.new_symbol(env.allocator, fnName);
                        defer key.deinit();

                        if (env.fnTable.get(key)) |funcWithAttr| {
                            logz.info()
                                .fmt("[env_test]", "{any}", .{ptr_params})
                                .level(.Debug)
                                .log();
                            const func = funcWithAttr.func;
                            // NOTE: Entry point to store MalType created within
                            // apply function
                            var fnValue: *MalType = undefined;
                            const params_items = ptr_params.items;
                            switch (func) {
                                .simple => |simple_func| {
                                    // TODO: Skip this now
                                    // _ = simple_func;
                                    const value: MalType = try @call(.auto, simple_func, .{
                                        params_items,
                                    });

                                    const numberValue = value.as_number() catch unreachable;

                                    fnValue = MalType.new_number(env.allocator, numberValue.value);
                                },
                                // NOTE: This should be disabled in ptr version
                                .with_env => |env_func| {
                                    _ = env_func;
                                    @panic("Non-pointer return is disabled in this env.");
                                },
                                .with_ptr => |ptr_func| {
                                    fnValue = try @call(.auto, ptr_func, .{
                                        params_items,
                                        self,
                                    });
                                },
                                .with_tail => |tail_func| {
                                    _ = tail_func;
                                    // NOTE: To apply tail call optimization, pointer has to be used to keep the
                                    // the call. In general however, other functions are using value to keep the
                                    // implementation more simple, without handling the underlying allocation
                                    // for MalType form.
                                    // In this case a new array list holding the pointer of MalType is copied
                                    // from value, and modifying the pointer of MalType to achieve potential
                                    // optimization. Afterwards copy the value back to original ref.
                                    // Handling memory allocation of MalType v.s. Separate branch implementaion like this
                                    // var params_ref = ArrayList(*MalType).init(allocator);
                                    // defer params_ref.deinit();

                                    // for (ptr_params.items) |*item| {
                                    //     params_ref.append(item) catch @panic("Unhandled");
                                    // }

                                    // const ref = env.allocator.create(*MalType) catch @panic("");
                                    // defer env.allocator.destroy(ref);

                                    // // ref.* = apply_mal_ref;

                                    // try @call(.auto, tail_func, .{
                                    //     params_ref.items,
                                    //     ref,
                                    //     self,
                                    // });

                                    // Modifying apply_mal_ref directly causing corruption
                                    // Copy the value back to ref.
                                    // apply_mal_ref.* = ref.*.*;
                                    continue :base;
                                },
                                .plugin => |plugin_func| {
                                    const reference = funcWithAttr.reference;
                                    const plugin = @constCast(self.plugins.get(reference).?.context);

                                    fnValue = try @call(.auto, plugin_func, .{
                                        params_items,
                                        plugin,
                                    });
                                },
                            }

                            if (!lambda_func_run_checker) {
                                // NOTE: lambda function is not yet handled.
                                // Put the item into data collector for garbage collection
                                // self.dataCollector.put(fnValue) catch |err| switch (err) {
                                //     else => return MalTypeError.Unhandled,
                                // };
                            }

                            logz.info()
                                .fmt("[LISP_ENV]", "eval {any}", .{fnValue})
                                .level(.Debug)
                                .log();

                            return fnValue;
                        } else {
                            return @constCast(&MalType{ .boolean = false });
                        }

                        // For lambda function case, excepted to have an inner eval
                        // of the lambda function already.
                        // else if (lambda_function_pointer) |lambda| {
                        //     // TODO: This may not be useful at all
                        //     lambda_func_run_checker = true;
                        //     var _key = MalType{ .symbol = LAMBDA_FUNCTION_INTERNAL_FUNCTION_KEY };
                        //     defer _key.deinit();

                        //     if (lambda.fnTable.get(&_key)) |funcWithAttr| {
                        //         const func = funcWithAttr.func;
                        //         var fnValue: MalType = undefined;

                        //         switch (func) {
                        //             .with_env => |env_func| {
                        //                 _ = env_func;
                        //                 // fnValue = try @call(.auto, env_func, .{ params.items, lambda });
                        //             },
                        //             else => unreachable,
                        //         }
                        //         return fnValue;
                        //     }
                        // }
                        optional_env = env.outer;
                    }

                    return mal;
                },
                .symbol => |symbol| {
                    return self.getVar(symbol.data);
                },
                else => return mal,
            }
        }
    }
};
