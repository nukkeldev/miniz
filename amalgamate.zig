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

const AmalgameeFlags = struct {
    name: []const u8,
    remove_includes: bool = true,
};

pub fn main() void {
    // Create an allocator.

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Create out program state.

    var header_file_flags = std.ArrayList(AmalgameeFlags).init(allocator);
    var header_contents = std.ArrayList([]const u8).init(allocator);
    var source_file_flags = std.ArrayList(AmalgameeFlags).init(allocator);
    var source_contents = std.ArrayList([]const u8).init(allocator);
    var header_output: ?[]const u8 = null;
    var source_output: ?[]const u8 = null;
    var header_only = false;

    // Process command-line arguments.

    var mode: enum { headers, sources, additionally } = undefined;
    var includes_to_remove = std.ArrayList([]const u8).init(allocator);

    var args = std.process.argsWithAllocator(allocator) catch oom();
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
                includes_to_remove.append(arg) catch oom();
                continue;
            }

            const string = arg[0] == '"' and arg[arg.len - 1] == '"';
            const contents = outer: {
                if (string) {
                    break :outer arg[1 .. arg.len - 1];
                } else {
                    const file = std.fs.cwd().openFile(arg, .{}) catch fatal("Failed to open: \"{s}\"", .{arg});
                    defer file.close();

                    includes_to_remove.append(std.fs.path.basename(arg)) catch oom();
                    break :outer file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch oom();
                }
            };

            if (std.mem.trim(u8, contents, &std.ascii.whitespace).len == 0) continue;

            (if (mode == .headers) header_file_flags else source_file_flags).append(.{
                .name = if (string) "inline" else arg,
                .remove_includes = !string,
            }) catch oom();

            switch (mode) {
                .headers => header_contents.append(contents) catch oom(),
                .sources => source_contents.append(contents) catch oom(),
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

    const amal_header_contents: []const u8, const amal_source_contents: []const u8 = outer: {
        if (header_only) {
            header_contents.appendSlice(source_contents.items) catch oom();
            header_file_flags.appendSlice(source_file_flags.items) catch oom();
            break :outer .{ amalgamate(allocator, header_contents.items, header_file_flags.items, includes_to_remove.items), undefined };
        } else {
            break :outer .{
                amalgamate(allocator, header_contents.items, header_file_flags.items, includes_to_remove.items),
                amalgamate(allocator, source_contents.items, source_file_flags.items, includes_to_remove.items),
            };
        }
    };

    // Write to the output files.

    if (header_contents.items.len != 0) writeToOutput(header_output, amal_header_contents, "header");
    if (!header_only and source_contents.items.len != 0) writeToOutput(source_output, amal_source_contents, "source");

    return std.process.cleanExit();
}

fn amalgamate(
    allocator: std.mem.Allocator,
    file_contents: []const []const u8,
    file_flags: []const AmalgameeFlags,
    includes_to_remove: []const []const u8,
) []const u8 {
    var amal_contents = std.ArrayList(u8).init(allocator);
    for (file_contents, 0..) |contents, i| {
        const flags = file_flags[i];

        // TODO: Replace with .count -> .ensureUnusedCapacity ->
        // TODO:                        .appendSliceAssumeCapacity
        amal_contents.appendSlice(
            std.fmt.allocPrint(allocator, "\n// -- [Start] {s} -- //\n\n", .{flags.name}) catch oom(),
        ) catch oom();

        amal_contents.ensureUnusedCapacity(contents.len + 1) catch oom();
        var lines = std.mem.splitScalar(u8, std.mem.trim(u8, contents, &std.ascii.whitespace), '\n');
        outer: while (lines.next()) |line| {
            const trimmed_line = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (flags.remove_includes and
                std.mem.startsWith(u8, trimmed_line, "#include \"") and
                trimmed_line[trimmed_line.len - 1] == '"')
            {
                const include = trimmed_line[("#include \"".len)..(trimmed_line.len - 1)];
                for (includes_to_remove) |remove| if (std.mem.eql(u8, remove, include)) {
                    amal_contents.appendSlice("// [AMALGAMATED] ") catch oom();
                    amal_contents.appendSlice(line) catch oom();
                    amal_contents.append('\n') catch oom();
                    continue :outer;
                };
            }
            amal_contents.appendSlice(line) catch oom();
            amal_contents.append('\n') catch oom();
        }

        amal_contents.appendSlice(
            std.fmt.allocPrint(allocator, "\n// -- [End] {s} -- //\n\n", .{flags.name}) catch oom(),
        ) catch oom();
    }
    return std.mem.trim(u8, amal_contents.items, &std.ascii.whitespace);
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

fn oom() noreturn {
    fatal("Out-Of-Memory", .{});
}

fn fatalWithUsage(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format ++ "\n\n", args);
    std.debug.print(usage, .{});
    std.process.exit(1);
}
