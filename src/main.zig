const std = @import("std");
const ArrayList = std.ArrayList;

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

// Parsing function, which could be a part of Parser later
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

fn read(current_gpa_allocator: std.mem.Allocator) ![]const u8 {
// read from stdin and store the result via provided allocator.
    // NOTE: The reading from stdin is now having two writer for different
    // ends. One is for stdout to display; Another is Arraylist to store
    // the string. Is this a good way to handle?
    //
    // The display one need to address byte-by-byte such that user can
    // have WYSIWYG.
    const stdout = std.io.getStdOut();
    const stdout_file = stdout.writer();
    try stdout_file.writeAll("\nuser> ");

    var arrayList = ArrayList(u8).init(current_gpa_allocator);
    errdefer {
        arrayList.deinit();
    }

    const stdin = std.io.getStdIn();
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

fn eval() !void {
    // TODO: eval logic
    // A more robust design would be reading all the input one-by-one
    // In emacs the reading is done by each char level
}

fn print(string: []const u8) !void {
    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const stdout = bw.writer();

    try stdout.print("{s}", .{string});

    try bw.flush(); // don't forget to flush
}

pub fn rep() !void {
    var current_gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const current_gpa_allocator = current_gpa.allocator();

    const read_result = try read(current_gpa_allocator);

    try eval();
    try print(read_result);

    current_gpa_allocator.free(read_result);
}

pub fn enableRawMode(handle: std.posix.fd_t, termios: *std.posix.termios) !void {
    // termios.iflag = std.posix.tc_iflag_t{ .BRKINT = false };
    termios.lflag = std.posix.tc_lflag_t{
        // .ICANON = true,  // ICANON is disabled, requires manual handling
        .ECHO = false,
    };

    try std.posix.tcsetattr(handle, .NOW, termios.*);
}

pub fn disableRawMode(handle: std.posix.fd_t, termios: std.posix.termios) !void {
    try std.posix.tcsetattr(handle, .NOW, termios);
}

pub fn main() !void {
    // Prepare the termios configuration
    const stdin = std.io.getStdIn();
    const stdin_fd = stdin.handle;

    // TODO: posix case shall be refined later.
    const orig_termios = try std.posix.tcgetattr(stdin_fd);
    // Note: Init with a different pointer such that modifying the termios
    // will not affect the original one.
    var termios: std.posix.termios = undefined;
    termios = orig_termios;

    try enableRawMode(stdin_fd, &termios);

    while (true) {
        rep() catch |err| switch (err) {
            ByteParsingError.EndOfStream => {
                try disableRawMode(stdin_fd, orig_termios);
                std.process.exit(0);
            },
            else => |e| return e,
        };
    }
}
