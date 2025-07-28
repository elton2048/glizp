/// Plugin for print purpose, this requires to access frontend such that
/// this separates function in env.zig, which those core functions shall require
/// no frontend access at all.
const std = @import("std");
const lisp = @import("types/lisp.zig");

const Frontend = @import("Frontend.zig");
const printer = @import("printer.zig");

const core_env = @import("env_ptr.zig");

const ArrayList = std.ArrayList;

const MalType = lisp.MalType;
const MalTypeError = lisp.MalTypeError;
const LispFunctionWithOpaque = lisp.LispFunctionWithOpaque;

const EVAL_TABLE = std.StaticStringMap(LispFunctionWithOpaque).initComptime(.{
    .{ "prn", &prnFunc },
    .{ "println", &printlnFunc },
});

fn prnFunc(params: []*MalType, env: *anyopaque) MalTypeError!*MalType {
    const pluginEnv: *PluginPrint = @ptrCast(@alignCast(env));

    const result = try core_env.strPrintImpl(pluginEnv.allocator, params, .{
        .join_with_space = true,
        .print_readably = true,
    });

    // TODO: Need error handling
    pluginEnv.frontend.print(printer.pr_str(result, false)) catch unreachable;
    pluginEnv.frontend.print("\n") catch unreachable;

    return MalType.new_boolean_ptr(false);
}

fn printlnFunc(params: []*MalType, env: *anyopaque) MalTypeError!*MalType {
    const pluginEnv: *PluginPrint = @ptrCast(@alignCast(env));

    const result = try core_env.strPrintImpl(pluginEnv.allocator, params, .{
        .join_with_space = true,
        .print_readably = false,
    });

    // TODO: Need error handling
    pluginEnv.frontend.print(printer.pr_str(result, false)) catch unreachable;
    pluginEnv.frontend.print("\n") catch unreachable;

    return MalType.new_boolean_ptr(false);
}

pub const PluginPrint = struct {
    _fnTable: std.StaticStringMap(LispFunctionWithOpaque),
    /// Allocator
    allocator: std.mem.Allocator,
    /// Frontend interface
    frontend: Frontend,

    pub fn init(allocator: std.mem.Allocator, frontend: Frontend) *PluginPrint {
        const self = allocator.create(PluginPrint) catch @panic("OOM");

        self.* = .{
            ._fnTable = EVAL_TABLE,
            .allocator = allocator,
            .frontend = frontend,
        };

        return self;
    }
};
