const std = @import("std");

const usage =
    \\Usage: copy <from> <to>
    \\
    \\Copies a file <from> here <to> there.
    \\
;

pub fn main() void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = std.process.argsAlloc(allocator) catch fatal("OOM", .{});
    if (args.len != 3) fatalWithUsage("Too many or too few arguments.", .{});

    const from = args[1];
    const to = args[2];

    std.fs.cwd().copyFile(from, std.fs.cwd(), to, .{}) catch fatal("Failed to copy file!", .{});
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

fn fatalWithUsage(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format ++ "\n\n", args);
    std.debug.print(usage, .{});
    std.process.exit(1);
}
