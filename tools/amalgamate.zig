const std = @import("std");

const usage =
    \\Usage: ./amalgamate [options]
    \\
    \\Amalgamtes C/C++ header and source files together, removing includes.
    \\
    \\Options [*=required]:
    \\* -h, --headers: Indicates the following arguments are paths to header files.
    \\* -s, --sources: Indicates the following arguments are paths to source files.
    \\* -hO, --header-output: Where to write the amalgamated header.
    \\* -sO, --source-output: Where to write the amalgamated source.
    \\  -H, --header-only: Outputs only a header file [default=false].
    \\  -A, --additionally: Indicates the following arguments are not-previosly supplied
    \\                      include paths that should be removed.
    \\
    \\Notes:
    \\  If a path is surrounded in double-quotes, it is interpreted as a string to
    \\  be amalgamated.
    \\
;

pub fn main() void {
    // Create an allocator.

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create out program state.

    var header_contents = std.ArrayList([]const u8).init(allocator);
    var source_contents = std.ArrayList([]const u8).init(allocator);
    var header_output: ?[]const u8 = null;
    var source_output: ?[]const u8 = null;
    var header_only = false;

    // Process command-line arguments.

    var mode: enum { headers, sources, additionally } = undefined;
    var includes_to_remove = std.ArrayList([]const u8).init(allocator);

    var args = std.process.argsWithAllocator(allocator) catch fatal("OOM", .{});
    _ = args.skip();

    var arg_n: usize = 0;
    while (args.next()) |arg| : (arg_n += 1) {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--headers")) {
            mode = .headers;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--sources")) {
            mode = .sources;
        } else if (std.mem.eql(u8, arg, "-A") or std.mem.eql(u8, arg, "--additionally")) {
            mode = .additionally;
        } else if (std.mem.eql(u8, arg, "-hO") or std.mem.eql(u8, arg, "--header-output")) {
            header_output = args.next() orelse fatalWithUsage("-hO and --header-output require a path after it.", .{});
        } else if (std.mem.eql(u8, arg, "-sO") or std.mem.eql(u8, arg, "--source-output")) {
            source_output = args.next() orelse fatalWithUsage("-sO and --source-output require a path after it.", .{});
        } else if (std.mem.eql(u8, arg, "-H")) {
            header_only = true;
        } else {
            if (mode == .additionally) {
                includes_to_remove.append(arg) catch fatal("OOM", .{});
                continue;
            }
            const contents = outer: {
                if (arg[0] == '"' and arg[arg.len - 1] == '"') {
                    break :outer arg[1 .. arg.len - 1];
                } else {
                    const file = std.fs.cwd().openFile(arg, .{}) catch fatal("Failed to open: \"{s}\"", .{arg});
                    defer file.close();
                    includes_to_remove.append(std.fs.path.basename(arg)) catch fatal("OOM", .{});
                    break :outer file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch fatal("OOM", .{});
                }
            };
            switch (mode) {
                .headers => header_contents.append(contents) catch fatal("OOM", .{}),
                .sources => source_contents.append(contents) catch fatal("OOM", .{}),
                else => unreachable,
            }
        }
    }

    // Print usage with context if something is wrong.

    if (arg_n == 0) fatalWithUsage("No arguments supplied!", .{});
    if (header_contents.items.len == 0 and source_contents.items.len == 0)
        fatalWithUsage("At least one file is required for either headers or sources!", .{});
    if ((header_contents.items.len != 0 and header_output == null) or
        (source_contents.items.len != 0 and source_output == null))
        fatalWithUsage("Supplied header and/or source files need outputs to write to!", .{});

    // Amalgamate the files.

    const amal_header_contents = amalgamate(allocator, header_contents.items, includes_to_remove.items);
    const amal_source_contents = amalgamate(allocator, source_contents.items, includes_to_remove.items);

    // Write to the output files.

    writeToOutput(header_output, amal_header_contents, "header");
    writeToOutput(source_output, amal_source_contents, "source");

    return std.process.cleanExit();
}

fn amalgamate(allocator: std.mem.Allocator, file_contents: [][]const u8, includes_to_remove: [][]const u8) []const u8 {
    var amal_contents = std.ArrayList(u8).init(allocator);
    for (file_contents) |contents| {
        amal_contents.appendSlice("\n\n// -- START AMALGAMATED -- //\n\n") catch fatal("OOM", .{});

        amal_contents.ensureUnusedCapacity(contents.len + 1) catch fatal("OOM", .{});
        var lines = std.mem.splitScalar(u8, contents, '\n');
        outer: while (lines.next()) |line| {
            const trimmed_line = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (std.mem.startsWith(u8, trimmed_line, "#include \"") and
                trimmed_line[trimmed_line.len - 1] == '"')
            {
                const include = trimmed_line[("#include \"".len)..(trimmed_line.len - 1)];
                for (includes_to_remove) |remove| if (std.mem.eql(u8, remove, include)) {
                    amal_contents.appendSlice("// [AMALGAMATED] ") catch fatal("OOM", .{});
                    amal_contents.appendSlice(line) catch fatal("OOM", .{});
                    amal_contents.append('\n') catch fatal("OOM", .{});
                    continue :outer;
                };
            }
            amal_contents.appendSlice(line) catch fatal("OOM", .{});
            amal_contents.append('\n') catch fatal("OOM", .{});
        }

        amal_contents.appendSlice("\n\n// -- END AMALGAMATED -- //\n\n") catch fatal("OOM", .{});
    }
    return amal_contents.items;
}

fn writeToOutput(output_path: ?[]const u8, contents: []const u8, context: []const u8) void {
    if (output_path) |path| {
        const output_dir = if (std.fs.path.dirname(path)) |dir|
            std.fs.cwd().makeOpenPath(dir, .{}) catch fatal("Failed to open the {s} output directory!", .{context})
        else
            std.fs.cwd();
        const file = output_dir.createFile(std.fs.path.basename(path), .{}) catch fatal("Failed to create {s} output file!", .{context});
        const bytes = file.write(contents) catch fatal("Failed to write to {s} output file!", .{context});
        if (bytes != contents.len) fatal("Failed to write to {s} output file!", .{context});
        file.close();
    }
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
