const std = @import("std");
const builtin = @import("builtin");
const logz = @import("logz");

const xev = @import("xev");

const ArrayList = std.ArrayList;

const data = @import("data.zig");
const utils = @import("utils.zig");
const fs = @import("fs.zig");

const lisp = @import("types/lisp.zig");
const MalType = lisp.MalType;
const MalTypeError = lisp.MalTypeError;
const LispFunction = lisp.LispFunction;
const LispFunctionWithEnv = lisp.LispFunctionWithEnv;
const LispFunctionWithTail = lisp.LispFunctionWithTail;
const LispFunctionWithOpaque = lisp.LispFunctionWithOpaque;
const GenericLispFunction = lisp.GenericLispFunction;

const MessageQueue = @import("message_queue.zig").MessageQueue;

const PrefixStringHashMap = @import("prefix-string-hash-map.zig").PrefixStringHashMap;

const Plugin = @import("types/plugin.zig");

const PluginHashMap = std.StringHashMap(Plugin);

const STOCK_REFERENCE = "stock";

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
    .{ "lambda", &lambdaFunc },
    // TODO: See if need to extract this out?
    .{ "list", &listFunc },
    .{ "listp", &isListFunc },
    .{ "emptyp", &isEmptyFunc },
    .{ "count", &countFunc },

    .{ "vector", &vectorFunc },
    .{ "vectorp", &isVectorFunc },
    .{ "aref", &arefFunc },

    // NOTE: lread.c in original Emacs
    // Original "load" function includes to read and execute a file of Lisp code
    // Whereas this just loads the content
    .{ "fs-load", &fsLoadFunc },
    .{ "load", &loadFunc },

    // NOTE: This is more of testing purpose now. It simply sends a message
    // to a queue and consumed in a loop. This architecture is expected
    // to be expanded for plugin usage.
    .{ "msg-append", &messageAppend },
});

/// Tail optimization implementation requires more testing and evaluation
/// to ensure it works properly.
pub const SPECIAL_ENV_WITH_TAIL_EVAL_TABLE = std.StaticStringMap(LispFunctionWithTail).initComptime(.{
    .{ "if*", &ifTailFunc },
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
    reference: []const u8,
};

const LAMBDA_FUNCTION_INTERNAL_VARIABLE_KEY = "LAMBDA_FUNCTION_INTERNAL_VARIABLE_KEY";
const LAMBDA_FUNCTION_INTERNAL_FUNCTION_KEY = "LAMBDA_FUNCTION_INTERNAL_FUNCTION_KEY";

fn listFunc(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    var list = ArrayList(MalType).init(env.allocator);

    for (params) |param| {
        const mal_item = param.clone();
        list.append(mal_item) catch @panic("test");
    }

    const mal = MalType{ .list = list };

    return mal;
}

fn isListFunc(params: []MalType, env: *LispEnv) MalTypeError!MalType {
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

// NOTE: See if support vector case
fn isEmptyFunc(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    const isList = try (try isListFunc(params, env)).as_boolean();

    if (isList) {
        const mal = get(params, env) catch |err| switch (err) {
            error.IllegalType => blk: {
                break :blk params[0];
            },
            else => {
                return err;
            },
        };

        const list = try mal.as_list();
        const empty = list.items.len == 0;

        return .{ .boolean = empty };
    }

    return .{ .boolean = false };
}

fn countFunc(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    const isList = try (try isListFunc(params, env)).as_boolean();

    if (isList) {
        const mal = get(params, env) catch |err| switch (err) {
            error.IllegalType => blk: {
                break :blk params[0];
            },
            else => {
                return err;
            },
        };

        const list = try mal.as_list();
        return .{ .number = .{ .value = @floatFromInt(list.items.len) } };
    }

    return .{ .boolean = false };
}

fn vectorFunc(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    var vector = ArrayList(MalType).init(env.allocator);

    vector.insertSlice(0, params) catch |err| switch (err) {
        error.OutOfMemory => return MalTypeError.IllegalType,
    };

    const mal = MalType{ .vector = vector };

    return mal;
}

fn isVectorFunc(params: []MalType, env: *LispEnv) MalTypeError!MalType {
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
    return vectorLikeFunc(result);
}

fn arefFunc(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    const array = get(params, env) catch |err| switch (err) {
        error.IllegalType => blk: {
            break :blk params[0];
        },
        else => {
            return err;
        },
    };
    const vector = try array.as_vector();
    const index_num = try params[1].as_number();
    const index = try index_num.to_usize();

    var result: MalType = MalType{ .boolean = false };

    if (index < vector.items.len) {
        result = vector.items[index];
    }

    return result;
}

fn messageAppend(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    const msg = try params[0].as_string();

    const result = std.fmt.allocPrint(env.allocator, "{s}", .{msg.items}) catch @panic("allocator error");

    env.messageQueue.append(result) catch |err| switch (err) {
        else => {
            return MalTypeError.Unhandled;
        },
    };

    env.messageQueue.notify() catch |err| switch (err) {
        error.MachMsgFailed => return MalTypeError.Unhandled,
    };

    return MalType{ .boolean = true };
}

fn listLikeFunc(params: MalType) MalTypeError!MalType {
    if (params.as_list()) |_| {
        return MalType{ .boolean = true };
    } else |_| {
        return MalType{ .boolean = false };
    }

    return MalType{ .boolean = false };
}

fn vectorLikeFunc(params: MalType) MalTypeError!MalType {
    if (params.as_vector()) |_| {
        return MalType{ .boolean = true };
    } else |_| {
        return MalType{ .boolean = false };
    }

    return MalType{ .boolean = false };
}

fn set(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    std.debug.assert(params.len == 2);

    const key = try params[0].as_symbol();
    const value = env.apply(params[1], false) catch |err| switch (err) {
        error.IllegalType => return MalTypeError.IllegalType,
        error.Unhandled => return MalTypeError.Unhandled,
        else => return MalTypeError.Unhandled,
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

    // NOTE: All envs are now deinit along with the root one.
    // The init function hooks the env back to the new one, which allows
    // newly created env to be accessed by the root.
    const newEnv = LispEnv.init(env.allocator, env);

    for (bindings.items) |binding| {
        // NOTE: Using list for binding
        const list = try binding.as_list();

        _ = try set(list.items, newEnv);
    }

    return newEnv.apply(eval_arg, false);
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

    const condition = (try env.apply(condition_arg, false)).as_boolean() catch true;
    if (!condition) {
        return env.apply(statement_false, false);
    }
    return env.apply(statement_true, false);
}

fn ifTailFunc(params: []*MalType, first_arg: **MalType, env: *LispEnv) MalTypeError!void {
    const condition_arg = params[0];
    const statement_true = params[1];
    // NOTE: In elisp the last params corresponds to false case,
    // it is not the case right now.
    // i.e. (if (= 1 2) 1 2 3 4) => 4
    var statement_false: *MalType = undefined;

    if (params.len == 1) {
        // TODO: Better error type
        return MalTypeError.IllegalType;
    }

    if (params.len == 2) {
        statement_false = @constCast(&MalType{ .boolean = false });
    } else {
        statement_false = params[2];
    }

    const condition = (try env.apply(condition_arg.*, false)).as_boolean() catch true;
    if (!condition) {
        first_arg.* = statement_false;

        return;
    }
    first_arg.* = statement_true;

    return;
}

fn lambdaFunc(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    const newEnv = LispEnv.init(env.allocator, env);
    // TODO: When to deinit?
    // defer newEnv.deinit();

    const fn_params = try params[0].as_list();
    for (fn_params.items) |param| {
        const param_symbol = try param.as_symbol();
        newEnv.addVar(param_symbol, .Undefined) catch unreachable;
    }

    const eval_params = params[1];
    newEnv.addVar(LAMBDA_FUNCTION_INTERNAL_VARIABLE_KEY, eval_params) catch unreachable;

    const inner_fn = struct {
        pub fn func(_params: []MalType, _env: *LispEnv) MalTypeError!MalType {
            // NOTE: deinit the LispEnv when it is done
            // defer _env.deinit();

            // NOTE: deinit for the statement is controlled in applyList
            // function
            const eval_statement = _env.getVar(LAMBDA_FUNCTION_INTERNAL_VARIABLE_KEY) catch unreachable;

            _env.removeVar(LAMBDA_FUNCTION_INTERNAL_VARIABLE_KEY);

            var iter = _env.data.iterator();
            var index: usize = 0;

            while (iter.next()) |entry| {
                _ = _env.setVar(entry.key_ptr.*, _params[index]) catch unreachable;
                index += 1;
            }

            return _env.apply(eval_statement, false);
        }
    }.func;

    newEnv.addFnWithEnv(LAMBDA_FUNCTION_INTERNAL_FUNCTION_KEY, &inner_fn) catch unreachable;

    return MalType{ .function = newEnv };
}

fn fsLoadFunc(params: []MalType, env: *LispEnv) MalTypeError!MalType {
    std.debug.assert(params.len == 1);

    const sub_path = try params[0].as_string();

    const result = fs.loadFile(env.allocator, sub_path.items) catch |err| switch (err) {
        error.FileNotFound => return MalTypeError.FileNotFound,
        else => return MalTypeError.Unhandled,
    };

    const al_result = ArrayList(u8).fromOwnedSlice(env.allocator, result);

    return MalType{ .string = al_result };
}

fn loadFunc(params: []MalType, env: *LispEnv) MalTypeError!MalType {
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
    defer reader.deinit();

    const result = try env.apply(reader.ast_root, false);

    return result;
}

pub const LispEnv = struct {
    // Inner reference, used for root to deinit all environments.
    inner: ?*LispEnv,
    outer: ?*LispEnv,
    allocator: std.mem.Allocator,
    data: std.StringHashMap(MalType),
    fnTable: lisp.LispHashMap(FunctionWithAttributes),
    // Internal storage for data parsed outside
    internalData: ArrayList(MalType),
    // Data collection point which holds the reference, intends to be a
    // garbage collector.
    dataCollector: PrefixStringHashMap(MalType),
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
                item.value_ptr.deinit();
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
            item.value_ptr.deinit();
        }
        self.dataCollector.deinit();
        self.allocator.destroy(self);
    }

    const ThreadData = struct {
        messageQueue: *MessageQueue,
        plugins: *PluginHashMap,
        data: u8,
    };

    fn loop_thread_func(loopData: ThreadData) !void {
        var loop = try xev.Loop.init(.{});
        defer loop.deinit();

        // 5s timer
        var c: xev.Completion = undefined;
        const time_interval = 5000;

        loopData.messageQueue.wait(&loop, &c, ThreadData, @constCast(&loopData), (struct {
            fn callback(
                userdata: ?*ThreadData,
                inner_loop: *xev.Loop,
                completion: *xev.Completion,
                result: xev.Async.WaitError!void,
            ) xev.CallbackAction {
                if (userdata) |inner_userdata| {
                    // TODO: Filter out test environment to run this
                    // as this will cause panic case now.
                    if (!builtin.is_test) {
                        if (inner_userdata.messageQueue.getLastOrNull()) |item| {
                            var iter = inner_userdata.plugins.valueIterator();
                            while (iter.next()) |plugin| {
                                plugin.subscribeEvent() catch @panic("plugin subscribeEvent");
                            }

                            utils.log("CB", item);
                        }
                    }

                    utils.log("WAIT", inner_userdata.data);
                }

                _ = inner_loop;
                _ = completion;
                _ = result catch @panic("testing");

                return .rearm;
            }
        }).callback);

        var c1: xev.Completion = undefined;
        loop.timer(&c1, time_interval, @constCast(&loopData), (struct {
            fn callback(
                userdata: ?*anyopaque,
                inner_loop: *xev.Loop,
                completion: *xev.Completion,
                result: xev.Result,
            ) xev.CallbackAction {
                _ = result;
                const inner_userdata: *ThreadData = @ptrCast(@alignCast(userdata.?));
                inner_userdata.data = inner_userdata.data + 1;

                inner_loop.timer(completion, time_interval, userdata, &callback);
                return .disarm;
            }
        }).callback);

        try loop.run(.until_done);
    }

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

    pub fn init_root(allocator: std.mem.Allocator) *Self {
        const self = allocator.create(Self) catch @panic("OOM");

        const envData = std.StringHashMap(MalType).init(allocator);

        const messageQueue = MessageQueue.initSPSC(allocator);

        const plugins = PluginHashMap.init(allocator);

        // Expected to modify the pointer through function to setup
        // initial function table.
        const fnTable = @constCast(&lisp.LispHashMap(FunctionWithAttributes).init(allocator));
        readFromFnMap(LispFunction, fnTable, data.EVAL_TABLE, STOCK_REFERENCE);
        readFromFnMap(LispFunctionWithEnv, fnTable, SPECIAL_ENV_EVAL_TABLE, STOCK_REFERENCE);
        readFromFnMap(LispFunctionWithTail, fnTable, SPECIAL_ENV_WITH_TAIL_EVAL_TABLE, STOCK_REFERENCE);

        const internalData = ArrayList(MalType).init(allocator);

        const dataCollector = PrefixStringHashMap(MalType).init(allocator, dataCollectorKeyPrefix);

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

        self.logFnTable();

        global_env_ptr = self;

        const threadData = ThreadData{
            .data = 0,
            .messageQueue = messageQueue,
            .plugins = &self.plugins,
        };

        // Test for another thread
        const loop_thread = std.Thread.spawn(.{}, loop_thread_func, .{threadData}) catch @panic("testing");
        loop_thread.detach();

        return self;
    }

    fn init(allocator: std.mem.Allocator, outer: *Self) *Self {
        const self = allocator.create(Self) catch @panic("OOM");

        const envData = std.StringHashMap(MalType).init(allocator);

        const fnTable = lisp.LispHashMap(FunctionWithAttributes).init(allocator);

        const internalData = ArrayList(MalType).init(allocator);

        const dataCollector = PrefixStringHashMap(MalType).init(allocator, dataCollectorKeyPrefix);

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
            // TODO: Set the corresponding reference
            .reference = "",
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
            // TODO: Set the corresponding reference
            .reference = "",
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

    /// apply function returns the Lisp object according to the type of
    /// the object. It evals further when it is a list or symbol.
    ///
    /// For list, it evals in the runtime environment and return the result.
    /// For symbol, it checks if the environment contains such value and
    /// return accordingly.
    ///
    /// The caller handles the memory allocated, check if the result is handled properly.
    pub fn apply(self: *Self, mal: MalType, nested: bool) !MalType {
        const apply_mal_ref = self.allocator.create(MalType) catch @panic("OOM");
        defer self.allocator.destroy(apply_mal_ref);
        // self.dataCollector.put(apply_mal_ref.*) catch @panic("");
        apply_mal_ref.* = mal;
        // var apply_mal_ref = @constCast(&mal);
        // utils.log_pointer(apply_mal_ref);

        base: while (true) {
            switch (apply_mal_ref.*) {
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
                    var lambda_function_pointer: ?*LispEnv = null;
                    var mal_param: MalType = undefined;
                    var lambda_func_run_checker: bool = true;
                    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
                    const allocator = gpa.allocator();

                    var params = ArrayList(MalType).init(allocator);
                    defer {
                        params.deinit();
                        // const check = gpa.deinit();
                        // std.debug.assert(check == .ok);
                    }

                    for (list.items, 0..) |_mal, i| {
                        if (i == 0) {
                            switch (_mal) {
                                .symbol => |symbol| {
                                    fnName = symbol;
                                },
                                .function => |_lambda| {
                                    _ = _lambda;
                                    // TODO: Stub to by-pass the further eval steps
                                    // and proceed to generate params for the function.
                                    // A more sophisticated way is preferred later
                                    fnName = "";
                                },
                                .list => |_list| {
                                    // TODO: Grap the MalType out and apply further.
                                    // const innerLisp = try self.applyList(_list, true);
                                    _ = _list;
                                    const innerLisp = try self.apply(_mal, true);
                                    if (innerLisp.as_function()) |_lambda| {
                                        lambda_function_pointer = _lambda;
                                        fnName = "";
                                    } else |_| {}
                                },
                                else => {
                                    utils.log("ERROR", "Illegal type to be evaled");
                                    return MalTypeError.IllegalType;
                                },
                            }
                            continue;
                        }

                        // TODO: Simple and lazy way for checking "special" form
                        if (std.hash_map.eqlString(fnName, "lambda")) {
                            // TODO: apply nested elsewhere
                            if (!nested) {
                                lambda_func_run_checker = false;
                            }
                            mal_param = _mal;
                        } else

                        // TODO: Simple and lazy way for checking "special" form
                        if (std.hash_map.eqlString(fnName, "let*")) {
                            mal_param = _mal;
                        } else

                        // TODO: Simple and lazy way for checking "special" form
                        if (std.hash_map.eqlString(fnName, "def!")) {
                            switch (_mal) {
                                .list => {
                                    // for def! case, should not eval the list
                                    mal_param = _mal;
                                    // // TODO: Need more assertion
                                    // // Assume the return type fits with the function
                                    // mal_param = try self.apply(_mal, false);

                                    // if (mal_param == .Incompleted) {
                                    //     return MalTypeError.IllegalType;
                                    // }
                                },
                                else => {
                                    mal_param = _mal;
                                },
                            }
                        } else

                        // TODO: Simple and lazy way for checking "special" form
                        if (SPECIAL_ENV_EVAL_TABLE.has(fnName)) {
                            switch (_mal) {
                                .list => {
                                    // TODO: Need more assertion
                                    // Assume the return type fits with the function
                                    mal_param = try self.apply(_mal, false);

                                    self.dataCollector.put(mal_param) catch |err| switch (err) {
                                        else => return MalTypeError.Unhandled,
                                    };
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
                                    mal_param = try self.apply(_mal, false);
                                    defer mal_param.deinit();

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
                        logz.info()
                            .fmt("[env_test]", "{s}", .{fnName})
                            .level(.Debug)
                            .log();

                        var key = MalType{ .symbol = fnName };

                        if (env.fnTable.get(&key)) |funcWithAttr| {
                            const func = funcWithAttr.func;
                            // NOTE: Entry point to store MalType created within
                            // apply function
                            var fnValue: MalType = undefined;
                            switch (func) {
                                .simple => |simple_func| {
                                    fnValue = try @call(.auto, simple_func, .{
                                        params.items,
                                    });
                                },
                                .with_env => |env_func| {
                                    fnValue = try @call(.auto, env_func, .{
                                        params.items,
                                        self,
                                    });
                                },
                                .with_tail => |tail_func| {
                                    // NOTE: To apply tail call optimization, pointer has to be used to keep the
                                    // the call. In general however, other functions are using value to keep the
                                    // implementation more simple, without handling the underlying allocation
                                    // for MalType form.
                                    // In this case a new array list holding the pointer of MalType is copied
                                    // from value, and modifying the pointer of MalType to achieve potential
                                    // optimization. Afterwards copy the value back to original ref.
                                    // Handling memory allocation of MalType v.s. Separate branch implementaion like this
                                    var params_ref = ArrayList(*MalType).init(allocator);
                                    defer params_ref.deinit();

                                    for (params.items) |*item| {
                                        params_ref.append(item) catch @panic("Unhandled");
                                    }

                                    const ref = env.allocator.create(*MalType) catch @panic("");
                                    defer env.allocator.destroy(ref);

                                    ref.* = apply_mal_ref;

                                    try @call(.auto, tail_func, .{
                                        params_ref.items,
                                        ref,
                                        self,
                                    });

                                    // Modifying apply_mal_ref directly causing corruption
                                    // Copy the value back to ref.
                                    apply_mal_ref.* = ref.*.*;
                                    continue :base;
                                },
                                .plugin => |plugin_func| {
                                    const reference = funcWithAttr.reference;
                                    const plugin = @constCast(self.plugins.get(reference).?.context);

                                    fnValue = try @call(.auto, plugin_func, .{
                                        params.items,
                                        plugin,
                                    });
                                },
                            }

                            if (!lambda_func_run_checker) {
                                // Put the item into data collector for garbage collection
                                self.dataCollector.put(fnValue) catch |err| switch (err) {
                                    else => return MalTypeError.Unhandled,
                                };
                            }

                            logz.info()
                                .fmt("[LISP_ENV]", "eval {any}", .{fnValue})
                                .level(.Debug)
                                .log();

                            return fnValue;
                        }

                        // For lambda function case, excepted to have an inner eval
                        // of the lambda function already.
                        else if (lambda_function_pointer) |lambda| {
                            // TODO: This may not be useful at all
                            lambda_func_run_checker = true;
                            var _key = MalType{ .symbol = LAMBDA_FUNCTION_INTERNAL_FUNCTION_KEY };
                            defer _key.deinit();

                            if (lambda.fnTable.get(&_key)) |funcWithAttr| {
                                const func = funcWithAttr.func;
                                var fnValue: MalType = undefined;

                                switch (func) {
                                    .with_env => |env_func| {
                                        fnValue = try @call(.auto, env_func, .{ params.items, lambda });
                                    },
                                    else => unreachable,
                                }
                                return fnValue;
                            }
                        }
                        optional_env = env.outer;
                    }

                    return apply_mal_ref.*;
                    // NOTE: deinit on the item inside the hash map and the env
                    // is different
                    // If a value is evaled further it will be kept without
                    // direct access. At the deinit stage of the env it cannot
                    // be accessed as the direct access is lost.
                    // Thus deinit the value after each lisp is applied/evaled
                    // for now.
                    // TODO: Should keep such value within the env and further
                    // handle afterwards? Then this is a simple GC job.
                    // return result;
                },
                .symbol => |symbol| {
                    return self.getVar(symbol);
                },
                else => return apply_mal_ref.*,
            }
        }
    }
};

const testing = std.testing;
const Reader = @import("reader.zig").Reader;

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

        const plus1_value = try env.apply(plus1, false);
        const plus1_value_number = plus1_value.as_number() catch unreachable;
        try testing.expectEqual(3, plus1_value_number.value);
    }

    // Data structure: Vector
    {
        var vector1 = Reader.init(allocator, "(vector 1 2)");
        defer vector1.deinit();

        const env = LispEnv.init_root(allocator);
        defer env.deinit();

        const vector1_value = try env.apply(vector1.ast_root, false);
        const vector1_value_vector = vector1_value.as_vector() catch unreachable;
        defer vector1_value_vector.deinit();

        const first = vector1_value_vector.items[0].as_number() catch unreachable;
        try testing.expectEqual(1, first.value);

        const second = vector1_value_vector.items[1].as_number() catch unreachable;
        try testing.expectEqual(2, second.value);
    }
}
