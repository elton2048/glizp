const std = @import("std");
const ArrayList = std.ArrayList;

const utils = @import("utils.zig");

// TODO: Provide check for termios based on OS
const posix = std.posix;

const cc_VTIME = 5;
const cc_VMIN = 6;

const Frontend = @import("Frontend.zig");
const Position = Frontend.Position;

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    /// Standard input in terminal instance
    stdin: std.fs.File,
    stdin_fd: *const posix.fd_t,
    orig_termios: posix.termios,
    prog_termios: *posix.termios,

    stdout: std.fs.File,

    /// Terminal escape control statement
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

    /// Corresponding vtable for interface functions
    const vtable = &Frontend.VTable{
        .print = _print,
        .deinit = deinit,
        .move = _move,
        .insert = insert,
        .deleteBackwardChar = deleteBackwardChar,
        .readCursorPos = _readCursorPos,
    };

    /// Move function by a number of steps in certain direction.
    pub fn move(self: Terminal, steps: usize, direction: Frontend.Direction) !void {
        const stdout_file = self.stdout.writer();
        var bw = std.io.bufferedWriter(stdout_file);
        const stdout_writer = bw.writer();

        const statement = std.fmt.allocPrint(self.allocator, TERM_MOVE_CURSOR, .{ steps, @intFromEnum(direction) }) catch unreachable;
        defer self.allocator.free(statement);

        try stdout_writer.writeAll(statement);

        try bw.flush();
    }

    /// Get the current frame (window in modern term) size.
    /// In later stage when resize action is detected it should also be
    /// called to refresh the information back to the Terminal.
    /// Reference: https://viewsourcecode.org/snaptoken/kilo/03.rawInputAndOutput.html#window-size-the-hard-way
    fn getFrameSize(self: *Terminal) !Position {
        const originalPosition = try self.readCursorPos();
        // NOTE: Shortcut for now.
        // Probably not updating the buffer cursor here if there are multiple
        // windows implemented.
        // self.buffer_cursor = originalPosition;

        try self.move(TERM_MAX_STEPS, .Right);
        try self.move(TERM_MAX_STEPS, .Down);

        const frameSize = try self.readCursorPos();

        try self.move(frameSize.x - originalPosition.x, .Left);
        try self.move(frameSize.y - originalPosition.y, .Up);

        return frameSize;
    }

    /// Read current cursor position.
    /// Return the result from terminal command perform such request.
    fn readCursorPos(self: *Terminal) !Position {
        const reader = self.stdin.reader();

        const stdout_file = self.stdout.writer();
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

    /// Insert byte on the frontend as well as the optional underlying
    /// array list for the string on particular pos.
    fn insert(context: *const anyopaque, optional_arrayList: ?*ArrayList(u8), byte: u8, pos: usize) !void {
        const self: *const Terminal = @ptrCast(@alignCast(context));

        if (optional_arrayList) |arrayList| {
            try arrayList.insert(pos, byte);
        }
        const stdout_file = self.stdout.writer();
        var bw = std.io.bufferedWriter(stdout_file);
        const stdout_writer = bw.writer();

        if (optional_arrayList) |arrayList| {
            var temp_allocator = std.heap.GeneralPurposeAllocator(.{}){};
            const allocator = temp_allocator.allocator();

            if (pos > 0) {
                const moveStatement = std.fmt.allocPrint(allocator, TERM_MOVE_CURSOR_LEFT, .{pos}) catch unreachable;
                defer allocator.free(moveStatement);

                try stdout_writer.writeAll(moveStatement);
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

    /// General delete char function
    /// delete char function aligns both stdout and array list to store byte.
    /// wrapped corresponding params into struct later.
    /// TODO: For multiple bytes case it is incorrect now, like emoji input.
    /// This is handled using CHARPOS and BYTEPOS in Emacs, which helps mapping
    /// to the correct position.
    // fn deleteChar(self: Terminal, optional_arrayList: ?*ArrayList(u8), pos: usize) !void {

    // }

    fn deleteBackwardChar(context: *const anyopaque, optional_arrayList: ?*ArrayList(u8), pos: usize) !void {
        const self: *const Terminal = @ptrCast(@alignCast(context));

        const charIndex = pos - 1;

        // Erase the previous byte
        if (optional_arrayList) |arrayList| {
            _ = arrayList.*.orderedRemove(charIndex);
        }

        const stdout_file = self.stdout.writer();
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

                const moveStatement = std.fmt.allocPrint(allocator, TERM_MOVE_CURSOR_LEFT, .{steps}) catch unreachable;
                defer allocator.free(moveStatement);

                try stdout_writer.writeAll(moveStatement);
            }
        }

        try bw.flush();
    }

    /// Print the string in terminal.
    fn print(self: Terminal, string: []const u8) !void {
        const writer = self.stdout.writer();
        var bw = std.io.bufferedWriter(writer);
        const stdout_writer = bw.writer();

        try stdout_writer.print("{s}", .{string});

        try bw.flush(); // don't forget to flush
    }

    // TODO: Better structure for interface functions
    fn _print(context: *const anyopaque, string: []const u8) !void {
        const self: *const Terminal = @ptrCast(@alignCast(context));
        try self.print(string);
    }

    // TODO: Better structure for interface functions
    fn _move(context: *const anyopaque, steps: usize, direction: Frontend.Direction) !void {
        const self: *const Terminal = @ptrCast(@alignCast(context));
        try self.move(steps, direction);
    }

    // TODO: Better structure for interface functions
    fn deinit(context: *const anyopaque) void {
        const self: *Terminal = @constCast(@ptrCast(@alignCast(context)));
        self.disableRawMode() catch @panic("deinit Terminal failed");
        self.allocator.destroy(self);
    }

    fn _readCursorPos(context: *const anyopaque) !Position {
        const self: *Terminal = @constCast(@ptrCast(@alignCast(context)));
        return self.readCursorPos();
    }

    /// Set the terminal to be in raw mode.
    // FIXME: enableRawMode could only be run within init now as it will
    // keeps the I/O busy s.t. the shell is struck.
    fn enableRawMode(self: Terminal) !void {
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

    /// Unset raw mode in the terminal.
    fn disableRawMode(self: *Terminal) !void {
        const stdin_fd = self.*.stdin_fd;
        const orig_termios = self.*.orig_termios;
        try posix.tcsetattr(stdin_fd.*, .NOW, orig_termios);
    }

    pub fn init(allocator: std.mem.Allocator) *Terminal {
        const self = allocator.create(Terminal) catch @panic("OOM");
        const stdin = std.io.getStdIn();
        const stdin_fd = stdin.handle;

        const orig_termios = posix.tcgetattr(stdin_fd) catch @panic("Cannot access termios");
        var prog_termios: posix.termios = undefined;
        prog_termios = orig_termios;

        self.* = Terminal{
            .allocator = allocator,
            .stdin = stdin,
            .stdin_fd = &stdin_fd,
            .orig_termios = orig_termios,
            .prog_termios = &prog_termios,
            .stdout = std.io.getStdOut(),
        };

        return self;
    }

    /// Return the frontend instance to perform generic function required.
    pub fn frontend(self: *Terminal) Frontend {
        self.enableRawMode() catch unreachable;

        const frameSize = self.getFrameSize() catch unreachable;
        return .{
            .context = self,
            .vtable = vtable,
            .frame_size = frameSize,
        };
    }
};
