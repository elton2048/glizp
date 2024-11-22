const std = @import("std");

const logz = @import("logz");

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

// NOTE: Shall be OS-dependent, to support different emoji it may require
// to be 8 too.
const INPUT_BYTE_SIZE = 4;

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
    var buffer = [INPUT_BYTE_SIZE]u8{ u8_MAX, u8_MAX, u8_MAX, u8_MAX };

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
        .fmt("[LOG]", "print: {any}", .{str})
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

    history: ArrayList([]u8),
    history_curr: usize,
    /// Denotes where the buffer cursor position is at to perform append
    /// and delete action from that point.
    buffer_pos: usize,
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

    pub fn init(allocator: std.mem.Allocator, terminal: *Terminal) *Shell {
        // NOTE: Currently the logger cannot be configured to log in
        // multiple outputs (like stdout then file)
        logz.setup(allocator, .{
            .pool_size = 2,
            .buffer_size = 4096,
            .level = .Debug,
            // .output = .stdout,
            .output = .{ .file = "glizp.log" },
        }) catch @panic("cannot initialize log manager");

        const logger = logz.logger().pool;
        // defer logz.deinit();

        const stdin = std.io.getStdIn();

        const historyArrayList = ArrayList([]u8).init(allocator);
        // errdefer {
        //     historyArrayList.deinit();
        // }

        const config = allocator.create(ShellConfig) catch @panic("OOM");
        config.* = ShellConfig{
            .set = false,
        };

        const frontend = terminal.frontend();

        const env = LispEnv.init_root(allocator);

        const self = allocator.create(Shell) catch @panic("OOM");
        self.* = Shell{
            .allocator = allocator,
            .stdin = stdin,
            .history = historyArrayList,
            .history_curr = 0,
            .logger = logger,
            .buffer_pos = 0,
            .buffer_cursor = Position{
                .x = 0,
                .y = 0,
            },
            .curr_read = undefined,
            .config = config,
            .frontend = frontend,
            .env = env,
        };

        self.initConfig();

        self.logConfig();

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

    fn deinit(self: *Shell) void {
        // NOTE: Intel macOS does not require free the config memory.
        // Align the behaviour later.
        self.allocator.destroy(self.config);
    }

    fn rep(self: *Shell) !void {
        var current_gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const current_gpa_allocator = current_gpa.allocator();

        const read_result = try self.*.read(current_gpa_allocator);

        try self.*.eval(self.curr_read.ast_root);
        // try self.*.print(read_result);

        current_gpa_allocator.free(read_result);
    }

    // read from stdin and store the result via provided allocator.
    fn read(self: *Shell, allocator: std.mem.Allocator) ![]const u8 {
        // NOTE: The reading from stdin is now having two writer for different
        // ends. One is for stdout to display; Another is Arraylist to store
        // the string. Is this a good way to handle?
        //
        // The display one need to address byte-by-byte such that user can
        // have WYSIWYG.

        try self.frontend.print("\nuser> ");

        var arrayList = ArrayList(u8).init(allocator);
        errdefer {
            arrayList.deinit();
        }

        // TODO: Some mechanism to get the frontend input(generic way)
        // for parsing
        const stdin = self.*.stdin;
        const reader = stdin.reader();
        var reading = true;

        while (reading) {
            if (parsing_byte(reader)) |inputEvent| {
                self.logger.logger()
                    .fmt("[LOG]", "InputEvent: {any}", .{inputEvent})
                    .level(.Debug)
                    .log();

                switch (inputEvent.key) {
                    .char => |key| {
                        if (inputEvent.ctrl and key == .D) {
                            reading = false;

                            // TODO: Prevent using error to handle this?
                            return ByteParsingError.EndOfStream;
                        }

                        // Backspace handling
                        if (key == .Backspace) {
                            // TODO: Functional key instead?
                            if (arrayList.items.len == 0) {
                                continue;
                            }

                            try self.frontend.deleteBackwardChar(&arrayList, self.buffer_pos);
                            if (self.buffer_pos > 0) {
                                self.buffer_pos -= 1;
                            }
                        } else if (inputEvent.ctrl and key == .J) {
                            const statement = try arrayList.toOwnedSlice();

                            // TODO: Shift-RET case is not handled yet. It returns same byte
                            // as only RET case, which needs to refer to io part.
                            // NOTE: Need to handle \n byte better
                            try self.frontend.insert(null, '\n', self.buffer_pos);
                            try self.frontend.deleteBackwardChar(null, self.buffer_pos);
                            reading = false;

                            if (statement.len == 0) {
                                continue;
                            }

                            // TODO: Parsing the latest statement and store
                            // in the Shell within the function. This makes
                            // function non-pure such that it makes testing
                            // more difficult. Need a more modular approach
                            // for this.
                            self.*.curr_read = parsing_statement(statement);

                            try self.*.history.append(statement);
                            // Reset history
                            self.*.history_curr = self.*.history.items.len - 1;
                            // Reset cursor
                            self.buffer_pos = 0;

                            continue;
                        } else if (inputEvent.alt) {
                            // Fetch history result, the current history cursor
                            // points to the last one if there is no history
                            // navigating function run before.
                            if (key == .N or key == .P) {
                                if (arrayList.items.len != 0) {
                                    try self.*.clearLine(&arrayList);
                                }

                                const history_len = self.*.history.items.len;
                                if (history_len == 0) {
                                    continue;
                                }

                                // Return the next one
                                if (key == .N) {
                                    self.*.history_curr += 1;
                                    if (self.*.history_curr == history_len) {
                                        self.*.history_curr -= 1;
                                        continue;
                                    }
                                }

                                self.buffer_pos = 0;
                                const result = self.*.getHistoryItem(self.*.history_curr);
                                for (result) |byte| {
                                    try self.frontend.insert(&arrayList, byte, self.buffer_pos);
                                    self.buffer_pos += 1;
                                }

                                // Set to the previous one
                                if (key == .P) {
                                    if (self.*.history_curr > 0) {
                                        self.*.history_curr -= 1;
                                    }
                                }
                            }
                        } else {
                            if (inputEvent.ctrl) {
                                continue;
                            }
                            const bytes = inputEvent.raw;
                            for (bytes) |byte| {
                                try self.frontend.insert(&arrayList, byte, self.buffer_pos);
                                self.buffer_pos += 1;
                            }
                        }
                    },
                    .functional => |key| {
                        // NOTE: Restrict for left and right only. No function
                        // yet on buffer.
                        if (key == .ArrowLeft) {
                            if (self.buffer_pos > 0) {
                                try self.frontend.move(1, .Left);

                                self.buffer_pos -= 1;

                                const cursor = try self.frontend.readCursorPos();
                                self.buffer_cursor = cursor;
                            }
                        } else if (key == .ArrowRight) {
                            if (self.buffer_pos < arrayList.items.len) {
                                const prevCursor = try self.frontend.readCursorPos();

                                if (prevCursor.x == self.frontend.frame_size.x) {
                                    // Handle the case when cursor is at the end of window
                                    try self.frontend.move(prevCursor.x - 1, .Left);
                                    try self.frontend.move(1, .Down);
                                } else {
                                    try self.frontend.move(1, .Right);
                                }

                                self.buffer_pos += 1;

                                const cursor = try self.frontend.readCursorPos();
                                self.buffer_cursor = cursor;
                            }
                        }
                    },
                }
            } else |err| switch (err) {
                else => |e| return e,
            }

            logz.debug()
                .fmt("[CURSOR]", "length: {d}", .{self.buffer_pos})
                .log();
        }

        return arrayList.toOwnedSlice();
    }

    fn getHistoryItem(self: Shell, index: usize) []const u8 {
        return self.history.items[index];
    }

    fn clearLine(self: *Shell, arrayList: *ArrayList(u8)) !void {
        // TODO: Provide efficient way for this one
        for (0..arrayList.items.len) |_| {
            try self.frontend.deleteBackwardChar(arrayList, self.buffer_pos);

            self.buffer_pos -= 1;
        }
    }

    fn eval(self: *Shell, item: MalType) !void {
        const fnValue = self.env.apply(item) catch |err| switch (err) {
            // Silently suppress the error
            MalTypeError.IllegalType => return,
            else => return err,
        };
        try self.frontend.print(printer.pr_str(fnValue, true));
        try self.frontend.print("\n");
    }

    pub fn quit(self: *Shell) void {
        self.*.frontend.deinit();
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

test "Shell" {
    const allocator = testing.allocator;
    const env = LispEnv.init_root(allocator);
    defer env.deinit();

    // Test for parsing string to Lisp result.
    // apply function cases
    // TODO: This part should be in Shell, it requires testing frontend
    // for such case
    {
        // List cases
        var l1 = Reader.init(allocator, "(+ 1 2 3)");
        defer l1.deinit();

        try testing.expect(l1.ast_root == .list);

        const l1_value = try env.apply(l1.ast_root);
        const l1_value_number = l1_value.as_number() catch unreachable;
        try testing.expectEqual(6, l1_value_number.value);

        // List within list cases
        var l2 = Reader.init(allocator, "(+ 1 (+ 2 3))");
        defer l2.deinit();

        try testing.expect(l2.ast_root == .list);

        const l2_value = try env.apply(l2.ast_root);
        const l2_value_number = l2_value.as_number() catch unreachable;
        try testing.expectEqual(6, l2_value_number.value);

        // Unexpected non-symbol case.
        // TODO: This may be changed if list type for non-symbol first item is implemented.
        var ns1 = Reader.init(allocator, "(1 2)");
        defer ns1.deinit();

        try testing.expect(ns1.ast_root == .list);

        if (env.apply(ns1.ast_root)) |_| {} else |err| {
            try testing.expectEqual(MalTypeError.IllegalType, err);
        }
    }

    // def case in environment
    {
        var def1 = Reader.init(allocator, "(def! a 1)");
        defer def1.deinit();

        try testing.expect(def1.ast_root == .list);

        const def1_value = try env.apply(def1.ast_root);
        const def1_value_number = def1_value.as_number() catch unreachable;
        try testing.expectEqual(1, def1_value_number.value);

        // def case with list eval
        var def2 = Reader.init(allocator, "(def! a (+ 2 1))");
        defer def2.deinit();

        try testing.expect(def2.ast_root == .list);

        const def2_value = try env.apply(def2.ast_root);
        const def2_value_number = def2_value.as_number() catch unreachable;
        try testing.expectEqual(3, def2_value_number.value);
    }

    // let* case in environment
    {
        var letx1 = Reader.init(allocator, "(let* ((a 2)) (+ a 3))");
        defer letx1.deinit();

        try testing.expect(letx1.ast_root == .list);

        const letx1_value = try env.apply(letx1.ast_root);
        const letx1_value_number = letx1_value.as_number() catch unreachable;
        try testing.expectEqual(5, letx1_value_number.value);

        // multiple let* case
        var letx2 = Reader.init(allocator, "(let* ((a 2)) (let* ((b 3)) (+ a b)))");
        defer letx2.deinit();

        try testing.expect(letx2.ast_root == .list);

        const letx2_value = try env.apply(letx2.ast_root);
        const letx2_value_number = letx2_value.as_number() catch unreachable;
        try testing.expectEqual(5, letx2_value_number.value);
    }
}
