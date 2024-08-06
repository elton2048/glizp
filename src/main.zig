const std = @import("std");
const ArrayList = std.ArrayList;

fn log(comptime message: []const u8) !void {
    std.debug.print("[LOG] {s}\n", .{message});
}

fn read() ![]const u8 {
    const stdout = std.io.getStdOut();
    try stdout.writeAll("\nuser> ");

    // TODO: Currently it reads until the delimiter and put content into
    // memory. And such reading EOF (e.g. C-d) cannot be done yet.
    var mem_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = mem_allocator.allocator();
    var arrayList = ArrayList(u8).init(allocator);

    const stdin = std.io.getStdIn();
    _ = try stdin.reader().readUntilDelimiterArrayList(&arrayList, '\n', 255);

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
    const read_result = try read();
    try eval();
    try print(read_result);
}

pub fn main() !void {
    while (true) {
        try rep();
    }
}
