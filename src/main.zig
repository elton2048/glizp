const std = @import("std");

const ArrayList = std.ArrayList;

// TODO: Provide check for termios based on OS
const posix = std.posix;

// This isn't really an error case but a special case to be handled in
// parsing byte
const ByteParsingError = error{
    EndOfStream,
    EndOfLine,
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
fn parsing_byte(reader: std.fs.File.Reader) anyerror!u8 {
    // TODO: Possible refactoring for using keymap.
    const byte = reader.readByte() catch |err| switch (err) {
        error.EndOfStream => return ByteParsingError.EndOfStream,
        else => |e| return e,
    };

    // Check if escape character
    if (byte == '\u{001b}') {
        const byte_after = reader.readByte() catch |err| switch (err) {
            else => |e| return e,
        };
        // Prepare for returning case about composited key binding
        _ = byte_after;
    }
    if (byte == '\u{0004}') return ByteParsingError.EndOfStream;
    // TODO: Shift-RET case is not handled yet. It returns same byte
    // as only RET case, which needs to refer to io part.
    if (byte == '\n') return ByteParsingError.EndOfLine;

    return byte;
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

    // NOTE: history is now disabled.
    // history: ArrayList([]const u8),

    // FIXME: enableRawMode could only be run within init now as it will
    // keeps the I/O busy s.t. the shell is struck.
    fn enableRawMode(self: Shell) !void {
        const stdin_fd = self.stdin_fd;
        var prog_termios = self.prog_termios;
        prog_termios.lflag = posix.tc_lflag_t{
            // .ICANON = true, // ICANON is disabled, requires manual handling
            .ECHO = false,
        };

        posix.tcsetattr(stdin_fd.*, .NOW, prog_termios.*) catch @panic("Cannot access termios");
    }

    fn disableRawMode(self: *Shell) !void {
        const stdin_fd = self.*.stdin_fd;
        const orig_termios = self.*.orig_termios;
        try posix.tcsetattr(stdin_fd.*, .NOW, orig_termios);
    }

    pub fn init(allocator: std.mem.Allocator) *Shell {
        const stdin = std.io.getStdIn();
        const stdin_fd = stdin.handle;

        const orig_termios = posix.tcgetattr(stdin_fd) catch @panic("Cannot access termios");
        var prog_termios: posix.termios = undefined;
        prog_termios = orig_termios;

        const self = allocator.create(Shell) catch @panic("OOM");
        self.* = Shell{
            .stdin = stdin,
            .stdin_fd = &stdin_fd,
            .orig_termios = orig_termios,
            .prog_termios = &prog_termios,
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
        // _ = self;
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
            if (parsing_byte(reader)) |byte| {
                // Backspace handling
                if (byte == '\u{007f}') {
                    if (arrayList.items.len == 0) {
                        continue;
                    }

                    try backspace(stdout, &arrayList);

                    continue;
                }

                // NOTE: Show the byte as in non-ECHO mode, part in Shell later
                try appendByte(stdout, &arrayList, byte);
            } else |err| switch (err) {
                ByteParsingError.EndOfLine => {
                    try appendByte(stdout, null, '\n');
                    reading = false;
                },
                else => |e| return e,
            }
        }

        return arrayList.toOwnedSlice();
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
