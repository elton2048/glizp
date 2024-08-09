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

fn parsing_byte(reader: std.fs.File.Reader) anyerror!u8 {
    // TODO: Shift-RET case is not handled yet. It returns same byte
    // as only RET case, which needs to refer to io part.
    const byte = reader.readByte() catch |err| switch (err) {
        error.EndOfStream => return ByteParsingError.EndOfStream,
        else => |e| return e,
    };
    if (byte == '\n') return ByteParsingError.EndOfLine;

    return byte;
}

// read from stdin and store the result via provided allocator.
fn read(allocator: std.mem.Allocator) ![]const u8 {
    const stdout = std.io.getStdOut();
    try stdout.writeAll("\nuser> ");

    var arrayList = ArrayList(u8).init(allocator);
    errdefer {
        arrayList.deinit();
    }

    const writer = arrayList.writer();
    const stdin = std.io.getStdIn();
    const reader = stdin.reader();

    while (true) {
        const byte = parsing_byte(reader) catch |err| switch (err) {
            ByteParsingError.EndOfLine => break,
            ByteParsingError.EndOfStream => {
                std.process.exit(0);
            },
            else => |e| return e,
        };
        try writer.writeByte(byte);
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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const read_result = try read(allocator);
    try eval();
    try print(read_result);

    allocator.free(read_result);
}

pub fn main() !void {
    while (true) {
        try rep();
    }
}
