const std = @import("std");
const assert = std.debug.assert;

const logz = @import("logz");

const utils = @import("utils.zig");
const keymap = @import("keymap_macos.zig");

const ArrayList = std.ArrayList;

// TODO: Provide check for termios based on OS
const posix = std.posix;

const cc_VTIME = 5;
const cc_VMIN = 6;
const INPUT_INTERVAL_IN_MS = 1000;
const u8_MAX = 255;

// This isn't really an error case but a special case to be handled in
// parsing byte
const ByteParsingError = error{
    EndOfStream,
};

fn log(comptime message: []const u8) !void {
    std.debug.print("[LOG] {s}\n", .{message});
}

fn log_as_utf8(byte: u8) !void {
    var byte_out = [4]u8{ 0, 0, 0, 0 };
    _ = try std.unicode.utf8Encode(byte, &byte_out);
    std.debug.print("[LOG] {x}\n", .{byte_out});
}

fn log_pointer(ptr: anytype) !void {
    std.debug.print("[LOG] {*}\n", .{ptr});
}

// Currently for macOS. Can this cater for other OS?
// NOTE: How many bytes to represent an input makes sense?
// Assume key input are in four bytes now.
// Case: M-n (2 bytes)
// Case: Arrow key (3 bytes)
// Case: F5 (5 bytes)
fn read(reader: std.fs.File.Reader) [4]u8 {
    var buffer = [4]u8{ u8_MAX, u8_MAX, u8_MAX, u8_MAX };

    _ = reader.read(&buffer) catch |err| switch (err) {
        else => return buffer,
    };

    return buffer;
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
/// TODO: Support emoji case, which is not KeyCode actually.
fn parsing_byte(reader: std.fs.File.Reader) anyerror!keymap.KeyCode {
    const bytes = read(reader);
    const keyCode = keymap.mapByteToKeyCode(bytes);

    return keyCode;
}

// backspace function aligns both stdout and array list to store byte.
// wrapped corresponding params into struct later.
fn backspace(stdout: std.fs.File, arrayList: *ArrayList(u8)) !void {
    const stdout_file = stdout.writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout_writer = bw.writer();
    // terminal display; assume to be in raw mode
    try stdout_writer.writeByte('\u{0008}');
    try stdout_writer.writeByte('\u{0020}');
    try stdout_writer.writeByte('\u{0008}');

    try bw.flush();

    // Erase the previous byte
    _ = arrayList.*.pop();
}

// wrapped corresponding params into struct later.
fn append(stdout: std.fs.File, arrayList: *ArrayList(u8), bytes: []const u8) !void {
    const stdout_file = stdout.writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout_writer = bw.writer();

    _ = try stdout_writer.write(bytes);
    try bw.flush();
    _ = try arrayList.*.writer().write(bytes);
}

// wrapped corresponding params into struct later.
fn appendByte(stdout: std.fs.File, optional_arrayList: ?*ArrayList(u8), byte: u8) !void {
    const stdout_file = stdout.writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout_writer = bw.writer();

    try stdout_writer.writeByte(byte);
    try bw.flush();
    if (optional_arrayList) |arrayList| {
        try arrayList.*.writer().writeByte(byte);
    }
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
    stdin: std.fs.File,
    stdin_fd: *const posix.fd_t,
    orig_termios: posix.termios,
    prog_termios: *posix.termios,

    history: ArrayList([]u8),
    history_curr: usize,

    // As (logz) logger is not thread-safe, using a pool for the use
    // of the logger.
    // It is the same as calling the pool
    // (by calling "logz" method directly, e.g. logz.info())
    // and log accordingly.
    // TODO: Using a generic logger to decouple with logz if needed,
    // for example supporting log/metrics through network service?
    logger: *logz.Pool,

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

        const self = allocator.create(Shell) catch @panic("OOM");
        self.* = Shell{
            .stdin = stdin,
            .stdin_fd = &stdin_fd,
            .orig_termios = orig_termios,
            .prog_termios = &prog_termios,
            .history = historyArrayList,
            .history_curr = 0,
            .logger = logger,
        };

        try self.enableRawMode();
        return self;
    }

    fn deinit(self: *Shell) void {
        self.*.disableRawMode() catch @panic("deinit failed");
    }

    fn rep(self: *Shell) !void {
        var current_gpa = std.heap.GeneralPurposeAllocator(.{}){};
        const current_gpa_allocator = current_gpa.allocator();

        const read_result = try self.*.read(current_gpa_allocator);

        try self.*.eval();
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
            if (parsing_byte(reader)) |keycode| {
                self.logger.logger()
                    .fmt("[LOG]", "keycode: {any}", .{keycode})
                    .level(.Debug)
                    .log();

                if (keycode == .EndOfStream) {
                    reading = false;

                    // TODO: Prevent using error to handle this?
                    return ByteParsingError.EndOfStream;
                }
                // Backspace handling
                if (keycode == .Backspace) {
                    if (arrayList.items.len == 0) {
                        continue;
                    }

                    try backspace(stdout, &arrayList);
                } else if (keycode == .Enter) {
                    const input_result = try arrayList.toOwnedSlice();

                    // TODO: Shift-RET case is not handled yet. It returns same byte
                    // as only RET case, which needs to refer to io part.
                    // NOTE: Need to handle \n byte better
                    try appendByte(stdout, &arrayList, '\n');
                    try backspace(stdout, &arrayList);
                    reading = false;

                    if (input_result.len == 0) {
                        continue;
                    }

                    try self.*.history.append(input_result);
                    // Reset history
                    self.*.history_curr = self.*.history.items.len - 1;

                    continue;
                } else if (keycode == .MetaN) {
                    if (arrayList.items.len != 0) {
                        try self.*.clearLine(stdout, &arrayList);
                    }

                    const history_len = self.*.history.items.len;
                    if (history_len == 0) {
                        continue;
                    }

                    self.*.history_curr += 1;
                    if (self.*.history_curr == history_len) {
                        self.*.history_curr -= 1;
                        continue;
                    }

                    const result = self.*.getHistoryItem(self.*.history_curr);
                    for (result) |byte| {
                        try appendByte(stdout, &arrayList, byte);
                    }
                } else if (keycode == .MetaP) {
                    if (arrayList.items.len != 0) {
                        try self.*.clearLine(stdout, &arrayList);
                    }

                    const history_len = self.*.history.items.len;
                    if (history_len == 0) {
                        continue;
                    }

                    const result = self.*.getHistoryItem(self.*.history_curr);
                    if (self.*.history_curr > 0) {
                        self.*.history_curr -= 1;
                    }

                    for (result) |byte| {
                        try appendByte(stdout, &arrayList, byte);
                    }
                } else {
                    // NOTE: Show the byte as in non-ECHO mode, part in Shell later
                    const byte = @tagName(keycode);
                    try appendByte(stdout, &arrayList, byte[0]);
                }
            } else |err| switch (err) {
                else => |e| return e,
            }
        }

        return arrayList.toOwnedSlice();
    }

    fn getHistoryItem(self: Shell, index: usize) []const u8 {
        return self.history.items[index];
    }

    fn clearLine(self: Shell, stdout: std.fs.File, arrayList: *ArrayList(u8)) !void {
        _ = self;
        for (0..arrayList.items.len) |_| {
            try backspace(stdout, arrayList);
        }
    }

    fn eval(self: *Shell) !void {
        _ = self;
        // TODO: eval logic
        // A more robust design would be reading all the input one-by-one
        // In emacs the reading is done by each char level
        // This is actually not a part of the shell.
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
