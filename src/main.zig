const std = @import("std");

const logz = @import("logz");

const utils = @import("utils.zig");
const keymap = @import("keymap_macos.zig");
const constants = @import("constants.zig");
const u8_MAX = constants.u8_MAX;

const token_reader = @import("reader.zig");
const printer = @import("printer.zig");
const data = @import("data.zig");

const ArrayList = std.ArrayList;
const MalType = token_reader.MalType;

// TODO: Provide check for termios based on OS
const posix = std.posix;

const cc_VTIME = 5;
const cc_VMIN = 6;
const INPUT_INTERVAL_IN_MS = 1000;

// NOTE: Shall be OS-dependent, to support different emoji it may require
// to be 8 too.
const INPUT_BYTE_SIZE = 4;

// This isn't really an error case but a special case to be handled in
// parsing byte
const ByteParsingError = error{
    EndOfStream,
};

/// Terminal escape control statement
/// These shall be abstracted into Terminal layer later, see #12
/// Move cursor up by {d} lines
const TERM_MOVE_CURSOR_UP = "\x1b[{d}A";
/// Move cursor down by {d} lines
const TERM_MOVE_CURSOR_DOWN = "\x1b[{d}B";
/// Move cursor right by {d} columns
const TERM_MOVE_CURSOR_RIGHT = "\x1b[{d}C";
/// Move cursor left by {d} columns
const TERM_MOVE_CURSOR_LEFT = "\x1b[{d}D";

/// Command to move cursor in terminal in general
const TERM_MOVE_CURSOR = "\x1b[{d}{c}";

/// Command to erase from cursor position
const TERM_ERASE_FROM_CURSOR = "\x1b[0K";

/// Command to get current cursor position
const TERM_REQ_CURSOR_POS = "\x1b[6n";

/// Max steps for the terminal to move. Used to check the frame size
const TERM_MAX_STEPS: usize = 999;

/// Available direction in two-dimension. The internal representation
/// is for terminal movement.
pub const Direction = enum(u8) {
    Up = 'A',
    Down = 'B',
    Right = 'C',
    Left = 'D',
};

/// Two-dimensional position representation.
pub const Position = struct {
    x: usize,
    y: usize,
};

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

// backspace function aligns both stdout and array list to store byte.
// wrapped corresponding params into struct later.
// TODO: For multiple bytes case it is incorrect now, like emoji input.
fn backspace(stdout: std.fs.File, optional_arrayList: ?*ArrayList(u8), pos: usize) !void {
    const charIndex = pos - 1;

    // Erase the previous byte
    if (optional_arrayList) |arrayList| {
        _ = arrayList.*.orderedRemove(charIndex);
    }

    const stdout_file = stdout.writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout_writer = bw.writer();

    // terminal display; assume to be in raw mode
    try stdout_writer.writeByte('\u{0008}');
    try stdout_writer.writeByte('\u{0020}');
    try stdout_writer.writeByte('\u{0008}');

    if (optional_arrayList) |arrayList| {
        var temp_allocator = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = temp_allocator.allocator();

        // Adjustment for the string after cursor
        const steps = arrayList.items.len - charIndex;
        if (steps > 0) {
            try stdout_writer.writeAll(TERM_ERASE_FROM_CURSOR);
            try stdout_writer.writeAll(arrayList.items[charIndex..]);

            const move = std.fmt.allocPrint(allocator, TERM_MOVE_CURSOR_LEFT, .{steps}) catch unreachable;
            defer allocator.free(move);

            try stdout_writer.writeAll(move);
        }
    }

    try bw.flush();
}

// wrapped corresponding params into struct later.
fn appendByte(stdout: std.fs.File, optional_arrayList: ?*ArrayList(u8), byte: u8, pos: usize) !void {
    if (optional_arrayList) |arrayList| {
        try arrayList.insert(pos, byte);
    }
    const stdout_file = stdout.writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout_writer = bw.writer();

    if (optional_arrayList) |arrayList| {
        var temp_allocator = std.heap.GeneralPurposeAllocator(.{}){};
        const allocator = temp_allocator.allocator();

        if (pos > 0) {
            const move = std.fmt.allocPrint(allocator, TERM_MOVE_CURSOR_LEFT, .{pos}) catch unreachable;
            defer allocator.free(move);

            try stdout_writer.writeAll(move);
            // Clear the line
            try stdout_writer.writeAll(TERM_ERASE_FROM_CURSOR);
        }
        try stdout_writer.writeAll(arrayList.items);

        // Adjust the cursor if necessary
        const steps = arrayList.items.len - pos - 1;
        if (steps > 0) {
            const adjust_move = std.fmt.allocPrint(allocator, TERM_MOVE_CURSOR_LEFT, .{steps}) catch unreachable;
            defer allocator.free(adjust_move);

            try stdout_writer.writeAll(adjust_move);
        }
    } else {
        try stdout_writer.writeByte(byte);
    }
    try bw.flush();
}

pub fn main() !void {
    var gpa_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const general_allocator = gpa_allocator.allocator();

    const shell = Shell.init(general_allocator);
    // FIXME: Running enableRawMode through shell causing issue now. It
    // keeps the I/O busy s.t. the shell is struck. Mode setting is now
    // being done from init process, which makes the setting less dynamic.
    // try shell.enableRawMode();
    try shell.run();
}

pub const Shell = struct {
    allocator: std.mem.Allocator,
    stdin: std.fs.File,
    stdin_fd: *const posix.fd_t,
    orig_termios: posix.termios,
    prog_termios: *posix.termios,

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
        /// Denote the frame size of the shell.
        frame_size: Position,
    };

    // FIXME: enableRawMode could only be run within init now as it will
    // keeps the I/O busy s.t. the shell is struck.
    fn enableRawMode(self: Shell) !void {
        const stdin_fd = self.stdin_fd;
        var prog_termios = self.prog_termios;
        prog_termios.lflag = posix.tc_lflag_t{
            // .ICANON = true, // ICANON is disabled, requires manual handling
            .ECHO = false,
        };

        prog_termios.cc[cc_VMIN] = 0;
        prog_termios.cc[cc_VTIME] = 0;

        posix.tcsetattr(stdin_fd.*, .NOW, prog_termios.*) catch @panic("Cannot access termios");
    }

    fn disableRawMode(self: *Shell) !void {
        const stdin_fd = self.*.stdin_fd;
        const orig_termios = self.*.orig_termios;
        try posix.tcsetattr(stdin_fd.*, .NOW, orig_termios);
    }

    /// TODO: Related to terminal part, shall be extracted to be in Terminal
    /// struct later, see #12
    fn term_move(self: *Shell, stdout: std.fs.File, steps: usize, direction: Direction) !void {
        const stdout_file = stdout.writer();
        var bw = std.io.bufferedWriter(stdout_file);
        const stdout_writer = bw.writer();

        const statement = std.fmt.allocPrint(self.allocator, TERM_MOVE_CURSOR, .{ steps, @intFromEnum(direction) }) catch unreachable;
        defer self.allocator.free(statement);

        try stdout_writer.writeAll(statement);

        try bw.flush();
    }

    fn moveLeft(self: *Shell, stdout: std.fs.File) !void {
        if (self.buffer_pos > 0) {
            try self.term_move(stdout, 1, .Left);

            self.buffer_pos -= 1;

            const cursor = try self.readCursorPos(stdout);
            self.buffer_cursor = cursor;
        }
    }

    fn moveRight(self: *Shell, stdout: std.fs.File, buffer: ArrayList(u8)) !void {
        if (self.buffer_pos < buffer.items.len) {
            const prevCursor = try self.readCursorPos(stdout);

            if (prevCursor.x == self.config.frame_size.x) {
                // Handle the case when cursor is at the end of window
                try self.term_move(stdout, prevCursor.x - 1, .Left);
                try self.term_move(stdout, 1, .Down);
            } else {
                try self.term_move(stdout, 1, .Right);
            }

            self.buffer_pos += 1;

            const cursor = try self.readCursorPos(stdout);
            self.buffer_cursor = cursor;
        }
    }

    /// Get the current frame (window in modern term) size.
    /// In later stage when resize action is detected it should also be
    /// called to refresh the information back to the Shell.
    /// Reference: https://viewsourcecode.org/snaptoken/kilo/03.rawInputAndOutput.html#window-size-the-hard-way
    fn getFrameSize(self: *Shell, stdout: std.fs.File) !Position {
        const originalPosition = try self.readCursorPos(stdout);
        // NOTE: Shortcut for now.
        // Probably not updating the buffer cursor here if there are multiple
        // windows implemented.
        self.buffer_cursor = originalPosition;

        try self.term_move(stdout, TERM_MAX_STEPS, .Right);
        try self.term_move(stdout, TERM_MAX_STEPS, .Down);

        const frameSize = try self.readCursorPos(stdout);

        try self.term_move(stdout, frameSize.x - originalPosition.x, .Left);
        try self.term_move(stdout, frameSize.y - originalPosition.y, .Up);

        return frameSize;
    }

    fn readCursorPos(self: *Shell, stdout: std.fs.File) !Position {
        const reader = self.*.stdin.reader();

        const stdout_file = stdout.writer();
        var bw = std.io.bufferedWriter(stdout_file);
        const stdout_writer = bw.writer();

        try stdout_writer.writeAll(TERM_REQ_CURSOR_POS);

        try bw.flush();

        // Reference for delimiter: https://vt100.net/docs/vt100-ug/chapter3.html#CPR
        _ = try reader.readBytesNoEof(2);
        const row_str = reader.readUntilDelimiterAlloc(self.allocator, 59, 8) catch unreachable;
        const column_str = reader.readUntilDelimiterAlloc(self.allocator, 'R', 8) catch unreachable;

        const row = utils.parseU64(row_str, 10) catch @panic("Unexpected non number value");
        const column = utils.parseU64(column_str, 10) catch @panic("Unexpected non number value");

        return Position{
            .x = column,
            .y = row,
        };
    }

    pub fn init(allocator: std.mem.Allocator) *Shell {
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
        const stdin_fd = stdin.handle;

        const orig_termios = posix.tcgetattr(stdin_fd) catch @panic("Cannot access termios");
        var prog_termios: posix.termios = undefined;
        prog_termios = orig_termios;

        const historyArrayList = ArrayList([]u8).init(allocator);
        // errdefer {
        //     historyArrayList.deinit();
        // }

        const config = allocator.create(ShellConfig) catch @panic("OOM");
        config.* = ShellConfig{
            .set = false,
            .frame_size = Position{
                .x = 0,
                .y = 0,
            },
        };

        const self = allocator.create(Shell) catch @panic("OOM");
        self.* = Shell{
            .allocator = allocator,
            .stdin = stdin,
            .stdin_fd = &stdin_fd,
            .orig_termios = orig_termios,
            .prog_termios = &prog_termios,
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
        };

        try self.enableRawMode();

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

        const stdout = std.io.getStdOut();
        const frameSize = self.getFrameSize(stdout) catch unreachable;
        self.config.frame_size = frameSize;
    }

    fn deinit(self: *Shell) void {
        // NOTE: Intel macOS does not require free the config memory.
        // Align the behaviour later.
        self.allocator.destroy(self.config);
        self.*.disableRawMode() catch @panic("deinit failed");
    }

    fn rep(self: *Shell) !void {
        var current_gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const current_gpa_allocator = current_gpa.allocator();

        const read_result = try self.*.read(current_gpa_allocator);

        try self.*.eval(self.curr_read.ast_root);
        try self.*.print(read_result);

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
        const stdout = std.io.getStdOut();
        const stdout_file = stdout.writer();
        try stdout_file.writeAll("\nuser> ");

        var arrayList = ArrayList(u8).init(allocator);
        errdefer {
            arrayList.deinit();
        }

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

                            try backspace(stdout, &arrayList, self.buffer_pos);
                            if (self.buffer_pos > 0) {
                                self.buffer_pos -= 1;
                            }
                        } else if (inputEvent.ctrl and key == .J) {
                            const statement = try arrayList.toOwnedSlice();

                            // TODO: Shift-RET case is not handled yet. It returns same byte
                            // as only RET case, which needs to refer to io part.
                            // NOTE: Need to handle \n byte better
                            try appendByte(stdout, null, '\n', self.buffer_pos);
                            try backspace(stdout, null, self.buffer_pos);
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
                                    try self.*.clearLine(stdout, &arrayList);
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
                                    try appendByte(stdout, &arrayList, byte, self.buffer_pos);
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
                                try appendByte(stdout, &arrayList, byte, self.buffer_pos);
                                self.buffer_pos += 1;
                            }
                        }
                    },
                    .functional => |key| {
                        // NOTE: Restrict for left and right only. No function
                        // yet on buffer.
                        if (key == .ArrowLeft) {
                            try self.moveLeft(stdout);
                        } else if (key == .ArrowRight) {
                            try self.moveRight(stdout, arrayList);
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

    fn clearLine(self: *Shell, stdout: std.fs.File, arrayList: *ArrayList(u8)) !void {
        // TODO: Provide efficient way for this one
        for (0..arrayList.items.len) |_| {
            try backspace(stdout, arrayList, self.buffer_pos);

            self.buffer_pos -= 1;
        }
    }

    fn eval(self: *Shell, item: MalType) !void {
        _ = self;
        switch (item) {
            .list => |list| {
                // NOTE: Check if the first item is a symbol,
                // search the function table to see if it is a valid
                // function to run, append the params into the function
                // For non-symbol type, treat the whole items as a simple list
                const params = list.items[1..];
                switch (list.items[0]) {
                    .symbol => |symbol| {
                        if (data.EVAL_TABLE.get(symbol)) |func| {
                            const fnValue: MalType = try @call(.auto, func, .{params});
                            // TODO: Wrap this in Terminal struct
                            const stdout = std.io.getStdOut();
                            const stdout_file = stdout.writer();
                            try stdout_file.writeAll(printer.pr_str(fnValue, true));
                            try stdout_file.writeAll("\n");
                        } else {
                            utils.log("SYMBOL", "Not implemented");
                        }
                    },
                    else => {},
                }
            },
            else => {},
        }
    }

    fn print(self: *Shell, string: []const u8) !void {
        _ = self;
        const stdout_file = std.io.getStdOut().writer();
        var bw = std.io.bufferedWriter(stdout_file);
        const stdout = bw.writer();

        try stdout.print("{s}", .{string});

        try bw.flush(); // don't forget to flush
    }

    pub fn quit(self: *Shell) void {
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

test {
    var leaking_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const leaking_allocator = leaking_gpa.allocator();
    try logz.setup(leaking_allocator, .{ .pool_size = 5, .level = .None });

    std.testing.refAllDecls(@This());
}
