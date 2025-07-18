const std = @import("std");

const logz = @import("logz");
const zeit = @import("zeit");

const utils = @import("utils.zig");
const keymap = @import("keymap_macos.zig");
const constants = @import("constants.zig");
const u8_MAX = constants.u8_MAX;

const token_reader = @import("reader.zig");
const printer = @import("printer.zig");
const data = @import("data.zig");
const lisp = @import("types/lisp.zig");

const ArrayList = std.ArrayList;
const Reader = token_reader.Reader;
const MalType = lisp.MalType;
const MalTypeError = lisp.MalTypeError;

const LispEnv = @import("env.zig").LispEnv;

const Frontend = @import("Frontend.zig");
const Terminal = @import("terminal.zig").Terminal;

const PluginExample = @import("plugin-example.zig").PluginExample;
const PluginHistory = @import("plugin-history.zig").PluginHistory;
const PluginEditing = @import("plugin-editing.zig").PluginEditing;

const INIT_CONFIG_FILE = "init.el";

// NOTE: Shall be OS-dependent, to support different emoji it may require
// to be u64 too.
// TODO: Expand this elsewhere
const BASE_BYTES_TYPE_FOR_KEY = u32;

const INPUT_BYTE_SIZE = @sizeOf(BASE_BYTES_TYPE_FOR_KEY);

// This isn't really an error case but a special case to be handled in
// parsing byte
const ByteParsingError = error{
    EndOfStream,
};

const Position = Frontend.Position;

// Currently for macOS. Can this cater for other OS?
// NOTE: How many bytes to represent an input makes sense?
// Assume key input are in four bytes now.
// Case: M-n (2 bytes)
// Case: Arrow key (3 bytes)
// Case: F5 (5 bytes)
fn read(reader: std.fs.File.Reader) [INPUT_BYTE_SIZE]u8 {
    var buffer = [_]u8{u8_MAX} ** INPUT_BYTE_SIZE;

    _ = reader.read(&buffer) catch |err| switch (err) {
        else => return buffer,
    };

    return buffer;
}

/// Parsing the statament into AST using PCRE/JSON encoder/decoder.
/// Can this potentially use tree-sitter?
fn parsing_statement(statement: []const u8) *token_reader.Reader {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const general_allocator = gpa_allocator.allocator();

    // TODO: Potential cache for statement -> Reader
    const read_result = token_reader.Reader.init(general_allocator, statement);

    const str = printer.pr_str(read_result.ast_root, true);

    logz.info()
        .fmt("[LOG]", "print: \"{s}\"", .{str})
        .log();

    return read_result;
}

/// Parsing function, which could be a part of Parser later
/// Currently it is actually "reading" function.
/// Reading byte is complicated in "terminal" environment,
/// it involves queue the user input and further processing later into
/// editor environment. In interactive intrepreter(II) case it shall be
/// easier as it doesn't have to handle keymap to support different
/// actions in editor, but this shall be extended as II contains both
/// simple editor and language parser which could be two components.
///
/// Check Emacs and Neovim for how reading byte is being done.
/// Generally it polls the input, perform parse and read operation later.
///
/// In Emacs, it polls for a period of input, check the length of input
/// byte and map that into an input event struct, it uses bitwise
/// operation to mask the bit to decide whether the key input is special
/// or not.
///
/// See make_ctrl_char in src/keyboard.c
/// See wait_reading_process_output in src/process.c
///
/// In Neovim, it inits a RStream as a reading stream from a handle,
/// format the input into <X>, and the reading and parsing process
/// are based on this format for mapping it into keycode representation
///
/// See tui/input.c and os/input.c for more.
/// For keycode, see keycodes.h
fn parsing_byte(reader: std.fs.File.Reader) anyerror!keymap.InputEvent {
    const bytes = read(reader);
    const inputEvent = keymap.InputEvent.init(&bytes);

    return inputEvent;
}

pub fn main() !void {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const general_allocator = gpa_allocator.allocator();

    // Check quit method in Shell for frontend deinit. Currenly Terminal
    // is the frontend
    const terminal = Terminal.init(general_allocator);

    const shell = Shell.init(general_allocator, terminal);

    try shell.run();
}

pub const Shell = struct {
    allocator: std.mem.Allocator,
    stdin: std.fs.File,

    /// Denotes the buffer cursor.
    buffer_cursor: Position,
    /// Current reader instance
    curr_read: *token_reader.Reader,

    /// Config info about the shell
    config: *ShellConfig,
    /// Frontend of the shell
    frontend: Frontend,
    /// Lisp environment of the shell,
    env: *LispEnv,

    // As (logz) logger is not thread-safe, using a pool for the use
    // of the logger.
    // It is the same as calling the pool
    // (by calling "logz" method directly, e.g. logz.info())
    // and log accordingly.
    // TODO: Using a generic logger to decouple with logz if needed,
    // for example supporting log/metrics through network service?
    logger: *logz.Pool,

    const ShellConfig = struct {
        /// Denote whether the initial config is read
        set: bool,
    };

    /// Return log file name. The format should be a date containg year,
    /// month and day, with a suffix behind.
    fn log_filename(allocator: std.mem.Allocator) []u8 {
        const now = zeit.instant(.{}) catch |err| switch (err) {
            else => @panic("Unexpected error to get current time"),
        };
        const dt_now = now.time();

        var date_al = ArrayList(u8).init(allocator);
        defer date_al.deinit();

        dt_now.strftime(date_al.writer(), "%Y-%m-%d") catch |err| switch (err) {
            error.InvalidFormat => @panic("InvalidFormat"),
            error.Overflow => @panic("Year overflow"),
            error.UnsupportedSpecifier => @panic("Unexpected UnsupportedSpecifier error, check the original library"),
            error.UnknownSpecifier => @panic("Unexpected UnknownSpecifier error, check the original library"),

            // zig fmt: off
            // TODO: Generalize memory/space issue error
            error.NoSpaceLeft,
            error.OutOfMemory => @panic("Memory issue"),
            // zig fmt: on
        };

        return std.fmt.allocPrint(allocator, "glizp-{s}.log", .{date_al.items}) catch |err| switch (err) {
            error.OutOfMemory => @panic("Memory issue"),
        };
    }

    pub fn init(allocator: std.mem.Allocator, terminal: *Terminal) *Shell {
        // NOTE: Currently the logger cannot be configured to log in
        // multiple outputs (like stdout then file). Using multiple
        // writers may solve this issue.

        const filename = log_filename(allocator);

        logz.setup(allocator, .{
            .pool_size = 2,
            .buffer_size = 4096,
            .level = .Debug,
            // .output = .stdout,
            .output = .{ .file = filename },
        }) catch @panic("cannot initialize log manager");

        const logger = logz.logger().pool;
        // defer logz.deinit();

        const stdin = std.io.getStdIn();

        const config = allocator.create(ShellConfig) catch @panic("OOM");
        config.* = ShellConfig{
            .set = false,
        };

        const frontend = terminal.frontend();

        const env = LispEnv.init_root(allocator);

        const plugin_example = PluginExample.init(allocator);
        env.*.registerPlugin(plugin_example) catch @panic("OOM");

        const plugin_history = PluginHistory.init(allocator);
        env.*.registerPlugin(plugin_history) catch @panic("OOM");

        const plugin_editing = PluginEditing.init(allocator, frontend);
        env.*.registerPlugin(plugin_editing) catch @panic("OOM");

        const self = allocator.create(Shell) catch @panic("OOM");
        self.* = Shell{
            .allocator = allocator,
            .stdin = stdin,
            .logger = logger,
            .buffer_cursor = Position{
                .x = 0,
                .y = 0,
            },
            .curr_read = undefined,
            .config = config,
            .frontend = frontend,
            .env = env,
        };

        self.loadInitConfigFile() catch @panic("Unexpected error");

        self.initConfig();

        self.logConfig();

        // TODO: For keymap, consider provide default value
        self.eval_statement("(load \"global-keymap.lisp\")", false);

        return self;
    }

    /// Log config info
    fn logConfig(self: *Shell) void {
        self.logger.logger()
            .fmt("[LOG]", "Config info: {any}", .{self.config})
            .level(.Debug)
            .log();
    }

    fn initConfig(self: *Shell) void {
        if (self.config.set) {
            @panic("Initial config is set already. Unexpect to set again.");
        }
        self.config.set = true;
    }

    /// Eval statement directly, worked as a macro
    // TODO: Consider adding error handling
    fn eval_statement(self: Shell, statement: []const u8, print: bool) void {
        const statement_reader = parsing_statement(statement);

        // TODO: Handle deinit the result
        const result = self.env.apply(statement_reader.ast_root, false) catch |err| {
            utils.log("ERR", "{any}", .{err}, .{});
            return;
        };
        // defer result.deinit();

        if (print) {
            const str = printer.pr_str(result, true);
            utils.log("EVAL", "{any}", .{str}, .{});
        }

        return;
    }

    fn eval_statement_and_return(self: Shell, statement: []const u8) []u8 {
        const statement_reader = parsing_statement(statement);

        // TODO: Handle deinit the result
        const result = self.env.apply(statement_reader.ast_root, false) catch |err| {
            utils.log("ERRR", "{any}", .{err}, .{});
            return "";
        };
        // defer result.deinit();

        const str = printer.pr_str(result, true);
        return str;
    }

    fn loadInitConfigFile(self: *Shell) !void {
        const load_statement = std.fmt.comptimePrint("(load \"{s}\")", .{INIT_CONFIG_FILE});
        const load_statement_reader = parsing_statement(load_statement);

        const result = self.env.apply(load_statement_reader.ast_root, false) catch |err| {
            utils.log("ERR", "{any}", .{err}, .{});
            return;
        };
        defer result.deinit();

        self.logger.logger()
            .fmt("[LOG]", "Loaded \"{s}\" config file", .{INIT_CONFIG_FILE})
            .level(.Debug)
            .log();
    }

    fn deinit(self: *Shell) void {
        // NOTE: Intel macOS does not require free the config memory.
        // Align the behaviour later.
        self.allocator.destroy(self.config);
    }

    fn rep(self: *Shell) !void {
        var current_gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const current_gpa_allocator = current_gpa.allocator();

        // TODO: Consider making reading statement and parsing separated.(#42)
        const read_result = try self.*.read(current_gpa_allocator);

        try self.*.eval(self.curr_read.ast_root);
        // try self.*.print(read_result);

        _ = read_result;
        // current_gpa_allocator.free(read_result);
    }

    // read from stdin and store the result via provided allocator.
    fn read(self: *Shell, allocator: std.mem.Allocator) ![]const u8 {
        _ = allocator;
        // NOTE: The reading from stdin is now having two writer for different
        // ends. One is for stdout to display; Another is Arraylist to store
        // the string. Is this a good way to handle?
        //
        // The display one need to address byte-by-byte such that user can
        // have WYSIWYG.

        try self.frontend.print("\nuser> ");

        // TODO: Some mechanism to get the frontend input(generic way)
        // for parsing
        const stdin = self.*.stdin;
        const reader = stdin.reader();
        var reading = true;
        var statement: []u8 = "";

        var history_plugin: ?*PluginHistory = null;
        if (self.*.env.plugins.get("PluginHistory")) |plugin| {
            history_plugin = @constCast(@ptrCast(@alignCast(plugin.context)));
        }

        var editing_plugin: ?*PluginEditing = null;
        if (self.*.env.plugins.get("PluginEditing")) |plugin| {
            editing_plugin = @constCast(@ptrCast(@alignCast(plugin.context)));
        }

        // To implement keymap feature, it is required to load keymap-related
        // feature, when key is read, it searches through the corresponding
        // keymap, and execute the function through the env (self.env.apply)
        // Flow: A -> [insert] -> eval("(insert "A")")
        // Flow: Transfer key to definition -> get keymap result -> eval
        // e.g. ^[[D -> bind to "left" -> (left . move-backward) -> eval(move-backward)
        while (reading) {
            var plugin_full_statement = editing_plugin.?.buffer;
            if (parsing_byte(reader)) |inputEvent| {
                self.logger.logger()
                    .fmt("[LOG]", "InputEvent: {any}", .{inputEvent})
                    .level(.Debug)
                    .log();

                switch (inputEvent.key) {
                    .char => |key| {
                        if (inputEvent.ctrl and key == .C) {
                            self.quit();
                        }
                        // New entry point
                        if (inputEvent.ctrl and key == .J) {
                            var copied_statement = try plugin_full_statement.clone();
                            defer copied_statement.deinit();
                            statement = try copied_statement.toOwnedSlice();

                            // TODO: Shift-RET case is not handled yet. It returns same byte
                            // as only RET case, which needs to refer to io part.
                            try self.frontend.refresh(editing_plugin.?.buffer.items.len, 0, &[_]u8{'\n'});
                            reading = false;

                            // TODO(#42): Parsing the latest statement and store
                            // in the Shell within the function. This makes
                            // function non-pure such that it makes testing
                            // more difficult. Need a more modular approach
                            // for this.
                            self.*.curr_read = parsing_statement(statement);

                            try self.frontend.clearContent(0);

                            if (statement.len == 0) {
                                continue;
                            }

                            if (history_plugin) |plugin| {
                                try plugin.history.append(statement);
                                // Reset history
                                plugin.history_curr = plugin.history.items.len - 1;
                            }

                            // Reset cursor
                            editing_plugin.?.clear();

                            continue;
                        } else if (inputEvent.alt) {
                            // Fetch history result, the current history cursor
                            // points to the last one if there is no history
                            // navigating function run before.
                            if (key == .N or key == .P) {
                                if (plugin_full_statement.items.len != 0) {
                                    // NOTE: For clearContent, keeps as a
                                    // separate function now as to generalize to be
                                    // refresh is complicated
                                    try self.frontend.clearContent(editing_plugin.?.pos);
                                    editing_plugin.?.clear();
                                }

                                if (history_plugin) |plugin| {
                                    const history_len = plugin.history.items.len;
                                    if (history_len == 0) {
                                        continue;
                                    }

                                    // Return the next one
                                    if (key == .N) {
                                        plugin.history_curr += 1;

                                        if (plugin.history_curr == history_len) {
                                            plugin.history_curr -= 1;
                                            continue;
                                        }
                                    }
                                }

                                if (history_plugin) |plugin| {
                                    const result = plugin.getHistoryItem(plugin.history_curr);

                                    for (result) |byte| {
                                        if (editing_plugin) |_editing_plugin| {
                                            try _editing_plugin.insert(_editing_plugin.pos, byte);

                                            _editing_plugin.moveForward(1);

                                            try self.frontend.refresh(editing_plugin.?.pos - 1, 0, &[_]u8{byte});
                                        }
                                    }
                                }
                                // Set to the previous one
                                if (key == .P) {
                                    if (history_plugin) |plugin| {
                                        if (plugin.history_curr > 0) {
                                            plugin.history_curr -= 1;
                                        }
                                    }
                                }
                            }
                        } else {
                            const bytes = inputEvent.raw;
                            for (bytes) |byte| {
                                const aref_statement = try std.fmt.allocPrint(self.allocator, "(aref keymap {d})", .{byte});
                                const result_statement = self.eval_statement_and_return(aref_statement);
                                // Skip for nil
                                // TODO: Mechanism to determine whether params is required
                                // e.g. insert function.
                                // For a simple approach, use basic if clause checking
                                if (!std.mem.eql(u8, result_statement, "nil")) {
                                    var final_statement: []u8 = undefined;
                                    var str: []const u8 = &[_]u8{byte};
                                    if (byte == '"' or byte == '\\') {
                                        str = &[_]u8{ '\\', byte };
                                    }

                                    if (std.mem.eql(u8, result_statement, "insert")) {
                                        final_statement = try std.fmt.allocPrint(self.allocator, "({s} \"{s}\")", .{
                                            result_statement,
                                            str,
                                        });
                                    } else {
                                        final_statement = try std.fmt.allocPrint(self.allocator, "({s})", .{
                                            result_statement,
                                        });
                                    }

                                    self.eval_statement(final_statement, false);
                                }
                            }
                        }
                    },
                    .functional => |key| {
                        // NOTE: Restrict for left and right only. No function
                        // yet on buffer.
                        // NOTE: Resize frame case is not yet handled
                        if (key == .ArrowLeft) {
                            if (editing_plugin.?.pos > 0) {
                                self.eval_statement("(backward-char)", false);

                                const cursor = try self.frontend.readCursorPos();
                                self.buffer_cursor = cursor;
                            }
                        } else if (key == .ArrowRight) {
                            if (editing_plugin.?.pos < plugin_full_statement.items.len) {
                                self.eval_statement("(forward-char)", false);

                                const cursor = try self.frontend.readCursorPos();
                                self.buffer_cursor = cursor;
                            }
                        }
                    },
                }
            } else |err| switch (err) {
                else => |e| return e,
            }
        }

        return statement;
    }

    fn eval(self: *Shell, item: MalType) !void {
        const fnValue = self.env.apply(item, false) catch |err| switch (err) {
            // Silently suppress the error
            MalTypeError.IllegalType => return,
            else => return err,
        };
        try self.frontend.print(printer.pr_str(fnValue, true));
        try self.frontend.print("\n");
    }

    pub fn quit(self: *Shell) void {
        self.*.frontend.deinit();
        self.*.env.deinit();
        self.*.deinit();
        std.process.exit(0);
    }

    pub fn run(self: *Shell) !void {
        while (true) {
            self.*.rep() catch |err| switch (err) {
                ByteParsingError.EndOfStream => {
                    self.*.quit();
                },
                else => |e| return e,
            };
        }
    }
};

const testing = std.testing;

test {
    var leaking_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const leaking_allocator = leaking_gpa.allocator();
    try logz.setup(leaking_allocator, .{ .pool_size = 5, .level = .None });

    std.testing.refAllDecls(@This());
}
