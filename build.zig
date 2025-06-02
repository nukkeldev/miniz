//! Copyright (c) 2025 nukkeldev
//!
//! CHANGES:
//! - `-DINSTALL_PROJECT` was removed.
//! - `-Dlinkage` is prefered to `-DBUILD_SHARED_LIBS`.
//! -  The sources are not currently zipped with the build.
//!
//! This script is MIT licensed; see [LICENSE] for the full text.

const std = @import("std");

const Step = std.Build.Step;
const LP = std.Build.LazyPath;

var target: std.Build.ResolvedTarget = undefined;

pub fn build(b: *std.Build) void {
    // Get the upstream's file tree.
    const upstream = b.dependency("upstream", .{}).path(".");
    if (b.verbose) std.log.info("Upstream Path: {}", .{upstream.dependency.dependency.builder.build_root});

    // Get the version from the `build.zig.zon`.
    const miniz_version = getVersion(b.allocator);
    std.log.info("Configuring build for `miniz` version {}!", .{miniz_version});

    // Get the standard build options.
    target = b.standardTargetOptions(.{});

    // Set the default optimization mode to `.ReleaseFast` instead of `.Debug`.
    b.release_mode = .fast;
    const optimize = b.standardOptimizeOption(.{});

    // Get miniz's options.

    // const build_examples = b.option(bool, "BUILD_EXAMPLES", "Build examples") orelse false;
    // const build_fuzzers = b.option(bool, "BUILD_FUZZERS", "Build fuzz targets") orelse false;
    var amalgamate_sources = b.option(bool, "AMALGAMATE_SOURCES", "Amalgamate sources into miniz.h/c") orelse false;
    const build_header_only = b.option(bool, "BUILD_HEADER_ONLY", "Build a header-only version") orelse false;

    // NOTE: `-DBUILD_SHARED_LIBS` has been replaced with `-Dlinkage`, but the
    // NOTE: original option is still kept for purity-sake with less priority
    // NOTE: than `-Dlinkage`.
    const linkage = b: {
        var linkage = b.option(std.builtin.LinkMode, "linkage", "How to build miniz");
        if (linkage == null) {
            const build_shared_libs = b.option(
                bool,
                "BUILD_SHARED_LIBS",
                "Build shared library instead of static (prefer `-Dlinkage`)",
            );
            linkage = if (build_shared_libs orelse false) .dynamic else .static;
        }
        break :b linkage orelse unreachable;
    };

    const build_no_stdio = b.option(bool, "BUILD_NO_STDIO", "Build a without stdio version") orelse false;
    // const build_tests = b.option(bool, "BUILD_TESTS", "Build tests") orelse false;

    // Make sure to amalgamate sources if we are only building a header.
    if (build_header_only) amalgamate_sources = true;

    // Create the module and library.
    const mod = b.addModule("miniz", .{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "miniz",
        .root_module = mod,
        .version = miniz_version,
        .linkage = linkage,
    });
    b.installArtifact(lib);

    if (amalgamate_sources) {
        // Amalgamate the source files into `miniz.c/h`.
        const amalgamated = amalgamate(
            b,
            &.{
                .{ .string = "#ifndef MINIZ_EXPORT\n#define MINIZ_EXPORT\n#endif\n" },
                .{ .lazy_path = upstream.path(b, "miniz.h") },
                .{ .lazy_path = upstream.path(b, "miniz_common.h") },
                .{ .lazy_path = upstream.path(b, "miniz_tdef.h") },
                .{ .lazy_path = upstream.path(b, "miniz_tinfl.h") },
                .{ .lazy_path = upstream.path(b, "miniz_zip.h") },
            },
            &.{
                .{ .string = if (build_header_only) "\n#ifndef MINIZ_HEADER_FILE_ONLY\n" else "#include \"miniz.h\"\n" },
                .{ .lazy_path = upstream.path(b, "miniz.c") },
                .{ .lazy_path = upstream.path(b, "miniz_tdef.c") },
                .{ .lazy_path = upstream.path(b, "miniz_tinfl.c") },
                .{ .lazy_path = upstream.path(b, "miniz_zip.c") },
                .{ .string = if (build_header_only) "\n#endif // MINIZ_HEADER_FILE_ONLY\n" else "" },
            },
            &.{
                "miniz_export.h",
            },
            build_header_only,
        );

        // Copy the files to `zig-out`.
        const wf_copy = b.addWriteFiles();
        lib.step.dependOn(&wf_copy.step);
        const gen = wf_copy.addCopyFile(amalgamated.header_output, "amalgamation/miniz.h");
        _ = wf_copy.addCopyFile(amalgamated.header_output, "miniz.h");
        if (!build_header_only) {
            const source = wf_copy.addCopyFile(amalgamated.source_output, "amalgamation/miniz.c");
            lib.addCSourceFile(.{ .file = source });
        }

        // Add include paths.
        lib.addIncludePath(gen.dirname());
        lib.installHeadersDirectory(gen.dirname(), "", .{ .include_extensions = &.{"h"} });

        // TODO: Add functionality to zip the source files.
    } else {
        // Create export file.
        const wf_export = b.addWriteFiles();
        const miniz_export = wf_export.add("miniz_export.h", MINIZ_EXPORT_H);

        // Add source files.
        lib.addCSourceFiles(.{
            .root = upstream,
            .files = &.{
                "miniz.c",
                "miniz_tdef.c",
                "miniz_tinfl.c",
                "miniz_zip.c",
            },
        });

        // Add include paths.
        lib.addIncludePath(upstream);
        lib.addIncludePath(miniz_export.dirname());

        lib.installHeader(upstream.path(b, "miniz.h"), "miniz.h");
        lib.installHeader(upstream.path(b, "miniz_common.h"), "miniz_common.h");
        lib.installHeader(upstream.path(b, "miniz_tdef.h"), "miniz_tdef.h");
        lib.installHeader(upstream.path(b, "miniz_tinfl.h"), "miniz_tinfl.h");
        lib.installHeader(upstream.path(b, "miniz_zip.h"), "miniz_zip.h");
        lib.installHeader(miniz_export, "miniz_export.h");
    }

    // If specifed, add definition to disable `stdio` usage.
    if (build_no_stdio) {
        mod.addCMacro("MINIZ_NO_STDIO", "");
    }

    // -- Other Steps --

    // Create an unpack step to view the source code we are using.
    const unpack = b.step("unpack", "Installs the unpacked source");
    unpack.dependOn(&b.addInstallDirectory(.{
        .source_dir = upstream,
        .install_dir = .{ .custom = "unpacked" },
        .install_subdir = "",
    }).step);

    // Remove the `zig-out` folder.
    const clean = b.step("clean", "Deletes the `zig-out` folder");
    clean.dependOn(&b.addRemoveDirTree(b.path("zig-out")).step);
}

// Version

/// Get the .version field of the `build.zig.zon`.
fn getVersion(allocator: std.mem.Allocator) std.SemanticVersion {
    const @"build.zig.zon" = @embedFile("build.zig.zon");
    var lines = std.mem.splitScalar(u8, @"build.zig.zon", '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), ".version")) {
        const end = std.mem.lastIndexOfScalar(u8, line, '"').?;
        const start = std.mem.lastIndexOfScalar(u8, line[0..end], '"').? + 1;
        const version = allocator.dupe(u8, line[start..end]) catch oom();
        return std.SemanticVersion.parse(version) catch unreachable;
    };
    unreachable;
}

// Tools

const LazyPathOrString = union(enum) { lazy_path: LP, string: []const u8 };
const Amalgamated = struct { step: *Step, header_output: LP, source_output: LP };

fn amalgamate(
    b: *std.Build,
    headers: []const LazyPathOrString,
    sources: []const LazyPathOrString,
    additional_includes: []const []const u8,
    header_only: bool,
) Amalgamated {
    const mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .root_source_file = b.path("amalgamate.zig"),
    });
    const exe = b.addExecutable(.{ .name = "amalgamate", .root_module = mod });

    const run = b.addRunArtifact(exe);
    if (header_only) run.addArg("--header-only");

    run.addArg("--headers");
    for (headers) |item| switch (item) {
        .lazy_path => |lp| run.addFileArg(lp),
        .string => |s| run.addArg(b.fmt("\"{s}\"", .{s})),
    };

    run.addArg("--sources");
    for (sources) |item| switch (item) {
        .lazy_path => |lp| run.addFileArg(lp),
        .string => |s| run.addArg(b.fmt("\"{s}\"", .{s})),
    };

    run.addArg("--additionally");
    run.addArgs(additional_includes);

    run.addArg("--header-output");
    const header_output = outer: {
        const gen = b.allocator.create(std.Build.GeneratedFile) catch oom();
        gen.* = .{ .step = &run.step, .path = ".zig-cache/generated/miniz/miniz.h" };
        break :outer LP{ .generated = .{ .file = gen } };
    };
    run.addArg(".zig-cache/generated/miniz/miniz.h");

    run.addArg("--source-output");
    const source_output = outer: {
        const gen = b.allocator.create(std.Build.GeneratedFile) catch oom();
        gen.* = .{ .step = &run.step, .path = ".zig-cache/generated/miniz/miniz.c" };
        break :outer LP{ .generated = .{ .file = gen } };
    };
    run.addArg(".zig-cache/generated/miniz/miniz.c");

    return .{
        .step = &run.step,
        .header_output = header_output,
        .source_output = source_output,
    };
}

// Logging

fn oom() noreturn {
    fatalNoData("Out-Of-Memory");
}

fn fatalNoData(comptime format: []const u8) noreturn {
    const stderr = std.io.getStdErr();
    const w = stderr.writer();

    const tty_config = std.io.tty.detectConfig(stderr);
    tty_config.setColor(w, .red) catch {};
    stderr.writeAll("error: " ++ format) catch {};
    tty_config.setColor(w, .reset) catch {};

    std.process.exit(1);
}

// Constants

const MINIZ_EXPORT_H =
    \\ #ifndef MINIZ_EXPORT_H
    \\ #define MINIZ_EXPORT_H
    \\ 
    \\ #ifdef MINIZ_STATIC_DEFINE
    \\ #  define MINIZ_EXPORT
    \\ #  define MINIZ_NO_EXPORT
    \\ #else
    \\ #  ifndef MINIZ_EXPORT
    \\ #    ifdef miniz_EXPORTS
    \\         /* We are building this library */
    \\ #      define MINIZ_EXPORT
    \\ #    else
    \\         /* We are using this library */
    \\ #      define MINIZ_EXPORT
    \\ #    endif
    \\ #  endif
    \\ 
    \\ #  ifndef MINIZ_NO_EXPORT
    \\ #    define MINIZ_NO_EXPORT
    \\ #  endif
    \\ #endif
    \\ 
    \\ #ifndef MINIZ_DEPRECATED
    \\ #  define MINIZ_DEPRECATED __attribute__ ((__deprecated__))
    \\ #endif
    \\ 
    \\ #ifndef MINIZ_DEPRECATED_EXPORT
    \\ #  define MINIZ_DEPRECATED_EXPORT MINIZ_EXPORT MINIZ_DEPRECATED
    \\ #endif
    \\ 
    \\ #ifndef MINIZ_DEPRECATED_NO_EXPORT
    \\ #  define MINIZ_DEPRECATED_NO_EXPORT MINIZ_NO_EXPORT MINIZ_DEPRECATED
    \\ #endif
    \\ 
    \\ /* NOLINTNEXTLINE(readability-avoid-unconditional-preprocessor-if) */
    \\ #if 0 /* DEFINE_NO_DEPRECATED */
    \\ #  ifndef MINIZ_NO_DEPRECATED
    \\ #    define MINIZ_NO_DEPRECATED
    \\ #  endif
    \\ #endif
    \\ 
    \\ #endif /* MINIZ_EXPORT_H */
;
