//! Copyright (c) 2025 nukkeldev
//!
//! AYC Faithful Recreation (FR): `miniz`
//! FR = When possible, all previous functionality is made available to the
//!      user. This does not prevent additional features being added nor bugs
//!      being fixed.
//!
//! Faithfully recreated from the applicable portions of `CMakeLists.txt`
//! (source 1) and `amalgamate.sh` (source 2). Portions not relevent are not
//! included below, but those that are relevant have their lines commented
//! _above_ the corresponding zig code prefixed with "[up#]" where "#" is the
//! source's number.
//!
//! Styling Guide:
//! - All comments **MUST** not exceed 80 columns UNLESS it is an included
//!   portion of a source.
//! - All lines-of-code **MUST** not exceed 120 columns.
//! - Comments without whitespace below them refer **ONLY** to the subsequent
//!   line, whereas those that have a whitespace below them refer to the
//!   subsequent section of lines.
//! - Any differences from the original build script **MUST** be noted with
//!   "NOTE: ..." comments.
//! - Comments that include portions of a source **MUST** seperate the portion
//!   with **AT LEAST ONE EMPTY** comment line above and below.
//! - **ALL** used system commands **MUST** be listed in the "Required System
//!   Commands" section below.
//! - System commands **MUST** use the long version of arguments when available.
//!
//! This script is MIT licensed, see [LICENSE] for the full text.

const std = @import("std");

const Step = std.Build.Step;

var target: std.Build.ResolvedTarget = undefined;

var upstream: std.Build.LazyPath = undefined;
var lupstream: std.Build.LazyPath = undefined;

// TODO: Remove `try`s for panics.
pub fn build(b: *std.Build) !void {
    // Get the upstream's file tree.
    upstream = b.dependency("upstream", .{}).path(".");
    if (b.verbose) std.log.info("Upstream Path: {}", .{upstream.dependency.dependency.builder.build_root});

    // [up1] Get the `miniz` version. (lines 27-31)
    //
    // set(MINIZ_API_VERSION 3)
    // set(MINIZ_MINOR_VERSION 0)
    // set(MINIZ_PATCH_VERSION 2)
    // set(MINIZ_VERSION
    //     ${MINIZ_API_VERSION}.${MINIZ_MINOR_VERSION}.${MINIZ_PATCH_VERSION})
    //
    // NOTE: Rather than being set in the script itself, the version is pulled
    // NOTE: from `build.zig.zon`.

    const miniz_version = getVersion(b.allocator);
    std.log.info("Building `miniz` version {}!", .{miniz_version});

    // Get the build target.
    target = b.standardTargetOptions(.{});

    // [up1] Get the optimization mode (BUILD_TYPE). (lines 33-39)
    //
    // if(CMAKE_BUILD_TYPE STREQUAL "")
    //   # CMake defaults to leaving CMAKE_BUILD_TYPE empty. This screws up
    //   # differentiation between debug and release builds.
    //   set(CMAKE_BUILD_TYPE "Release" CACHE STRING
    //     "Choose the type of build, options are: None (CMAKE_CXX_FLAGS or \
    // CMAKE_C_FLAGS used) Debug Release RelWithDebInfo MinSizeRel." FORCE)
    // endif ()
    //
    // NOTE: [up1] (lines 20-24)
    // NOTE: Define the compliation flags for CMake's  `None` target to which we
    // NOTE: don't have an equivalent.

    // Set the default optimization mode to `.ReleaseFast` instead of `.Debug`.
    b.release_mode = .fast;
    const optimize = b.standardOptimizeOption(.{});

    // Create our module.
    const mod = b.addModule("miniz", .{
        .target = target,
        .optimize = optimize,
    });

    // [up1] Get `miniz`'s options. (lines 41-48)
    //
    // option(BUILD_EXAMPLES "Build examples" ${MINIZ_STANDALONE_PROJECT})
    // option(BUILD_FUZZERS "Build fuzz targets" OFF)
    // option(AMALGAMATE_SOURCES "Amalgamate sources into miniz.h/c" OFF)
    // option(BUILD_HEADER_ONLY "Build a header-only version" OFF)
    // option(BUILD_SHARED_LIBS "Build shared library instead of static" OFF)
    // option(BUILD_NO_STDIO" Build a without stdio version" OFF)
    // option(BUILD_TESTS "Build tests" ${MINIZ_STANDALONE_PROJECT})
    // option(INSTALL_PROJECT "Install project" ${MINIZ_STANDALONE_PROJECT})
    //

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
    const install_project = b.option(bool, "INSTALL_PROJECT", "Install project") orelse false;

    // [up1] Ensure the proper `miniz` option dependencies are set.
    // (lines 56-58)
    //
    // if(BUILD_HEADER_ONLY)
    //   set(AMALGAMATE_SOURCES ON CACHE BOOL "Build a header-only version" FORCE)
    // endif(BUILD_HEADER_ONLY)
    //

    if (build_header_only) amalgamate_sources = true;

    // Create a locally cached copy of the project before we start generating
    // files.

    const wf_lupstream_step = outer: {
        const step = b.addWriteFiles();
        step.step.name = "copy upstream";
        lupstream = step.addCopyDirectory(upstream, "", .{});
        break :outer if (b.verbose) &LogWriteFilesStep.init(b, step).step else &step.step;
    };

    // [up1] amalgamate /ə-măl′gə-māt″/: intransitive verb
    //         To combine into a unified or integrated whole; unite.
    // (lines 61-167)

    if (amalgamate_sources) {
        // [up2] Create the amalgamation folder. (line 5)
        //
        // mkdir -p amalgamation
        //
        // [up1] Copy `miniz.h` to the amalgamation folder. (line 62)
        //
        //   file(COPY miniz.h DESTINATION ${CMAKE_CURRENT_BINARY_DIR}/amalgamation/)
        //
        // [up1] Amalgamate all the header files into `amalgamation/miniz.h`.
        // (lines 63-69)
        //
        //   file(READ miniz.h MINIZ_H)
        //   file(READ miniz_common.h MINIZ_COMMON_H)
        //   file(READ miniz_tdef.h MINIZ_TDEF_H)
        //   file(READ miniz_tinfl.h MINIZ_TINFL_H)
        //   file(READ miniz_zip.h MINIZ_ZIP_H)
        //   file(APPEND ${CMAKE_CURRENT_BINARY_DIR}/amalgamation/miniz.h
        //      "${MINIZ_COMMON_H} ${MINIZ_TDEF_H} ${MINIZ_TINFL_H} ${MINIZ_ZIP_H}")
        //
        // [up1] Amalgamate all the c files into `amalgamation/miniz.c`.
        // (lines 71-76)
        //
        //   file(COPY miniz.c DESTINATION ${CMAKE_CURRENT_BINARY_DIR}/amalgamation/)
        //   file(READ miniz_tdef.c MINIZ_TDEF_C)
        //   file(READ miniz_tinfl.c MINIZ_TINFL_C)
        //   file(READ miniz_zip.c MINIZ_ZIP_C)
        //   file(APPEND ${CMAKE_CURRENT_BINARY_DIR}/amalgamation/miniz.c
        //      "${MINIZ_TDEF_C} ${MINIZ_TINFL_C} ${MINIZ_ZIP_C}")
        //
        // [up1] Remove includes from amalgamated files and add guard.
        // (lines 78-84)
        //
        //   file(READ ${CMAKE_CURRENT_BINARY_DIR}/amalgamation/miniz.h AMAL_MINIZ_H)
        //   file(READ ${CMAKE_CURRENT_BINARY_DIR}/amalgamation/miniz.c AMAL_MINIZ_C)
        //   foreach(REPLACE_STRING miniz;miniz_common;miniz_tdef;miniz_tinfl;miniz_zip;miniz_export)
        //     string(REPLACE "#include \"${REPLACE_STRING}.h\"" "" AMAL_MINIZ_H "${AMAL_MINIZ_H}")
        //     string(REPLACE "#include \"${REPLACE_STRING}.h\"" "" AMAL_MINIZ_C "${AMAL_MINIZ_C}")
        //   endforeach()
        //   string(CONCAT AMAL_MINIZ_H "#ifndef MINIZ_EXPORT\n#define MINIZ_EXPORT\n#endif\n" "${AMAL_MINIZ_H}")
        //
        // `Step.WriteFile` makes intermediate directories so we don't need to
        // create `amalgamation/` nor copy `miniz.h`.

        const amalgamate_step = amalgamate(
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
                .{ .string = if (build_header_only) "\n#ifndef MINIZ_HEADER_FILE_ONLY\n" else "" },
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
        amalgamate_step.dependOn(wf_lupstream_step);
        b.getInstallStep().dependOn(amalgamate_step);

        // Create our library.

        const lib = b.addLibrary(.{
            .name = "miniz",
            .root_module = mod,
            .version = miniz_version,
            .linkage = linkage,
        });
        // lib.addIncludePath(lupstream.path(b, "amalgamation"));
        if (install_project) b.installArtifact(lib);

        if (build_header_only) {
            // [up1] Embed miniz.c if we're only building a header.
            // (lines 86-87)
            //
            //     string(CONCAT AMAL_MINIZ_H "${AMAL_MINIZ_H}" "\n#ifndef MINIZ_HEADER_FILE_ONLY\n"
            //            "${AMAL_MINIZ_C}" "\n#endif // MINIZ_HEADER_FILE_ONLY\n")
            //

            // const amalgamate_header_only = try b.allocator.create(std.Build.Step);
            // amalgamate_header_only.* = .init(.{
            //     .id = .write_file,
            //     .name = "amalgamate header only",
            //     .owner = b,
            //     .makeFn = amalgamateHeaderOnly,
            // });
            // amalgamate_header_only.dependOn(add_header_guard);
            // amalgamate_header_only.dependOn(&amalgamate_source.step);
            // amalgamation_step.dependOn(amalgamate_header_only);

            // [up1] Copy miniz.h to lupstream. (line 88)
            //
            //    file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/amalgamation/miniz.h "${AMAL_MINIZ_H}")
            //
            // Extracted below.

            // [up1] Create our header-only library target. (line 89,97-101)
            //
            //     add_library(${PROJECT_NAME} INTERFACE)
            //     ...
            //     set_property(TARGET ${PROJECT_NAME} APPEND
            //       PROPERTY INTERFACE_INCLUDE_DIRECTORIES
            //       $<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}/amalgamation>
            //       $<INSTALL_INTERFACE:include>
            //     )
            //
            // Common with branches, extracted above.
        } else {
            // [up1] Copy miniz.c/h to lupstream. (line 104,105)
            //
            //     file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/amalgamation/miniz.h "${AMAL_MINIZ_H}")
            //     file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/amalgamation/miniz.c "${AMAL_MINIZ_C}")
            //

            // const copy_source = try b.allocator.create(std.Build.Step);
            // copy_source.* = .init(.{
            //     .id = .write_file,
            //     .name = "copy source",
            //     .owner = b,
            //     .makeFn = copySource,
            // });
            // copy_source.dependOn(&amalgamate_source.step);
            // amalgamation_step.dependOn(copy_source);

            // [up1] Create our library target. (line 108-112)
            //
            //     add_library(${PROJECT_NAME} STATIC ${miniz_SOURCE})
            //     target_include_directories(${PROJECT_NAME} PUBLIC
            //       $<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}/amalgamation>
            //       $<INSTALL_INTERFACE:include>
            //     )
            //
            // Common with branches, extracted above.

            // lib.addCSourceFile(.{ .file = lupstream.path(b, "amalgamation/miniz.c") });
        }

        // const copy_header = try b.allocator.create(std.Build.Step);
        // copy_header.* = .init(.{
        //     .id = .write_file,
        //     .name = "copy header",
        //     .owner = b,
        //     .makeFn = copyHeader,
        // });
        // copy_header.dependOn(&amalgamate_header.step);
        // amalgamation_step.dependOn(copy_header);

        //
        // set(INSTALL_HEADERS ${CMAKE_CURRENT_BINARY_DIR}/amalgamation/miniz.h)
        //
        // file(GLOB_RECURSE ZIP_FILES RELATIVE "${CMAKE_CURRENT_BINARY_DIR}/amalgamation" "${CMAKE_CURRENT_BINARY_DIR}/amalgamation/*")
        // file(GLOB_RECURSE ZIP_FILES2 RELATIVE "${CMAKE_SOURCE_DIR}" "${CMAKE_SOURCE_DIR}/examples/*")
        // list(APPEND ZIP_FILES ${ZIP_FILES2})
        // list(APPEND ZIP_FILES "ChangeLog.md")
        // list(APPEND ZIP_FILES "readme.md")
        // list(APPEND ZIP_FILES "LICENSE")
        // set(ZIP_OUT_FN "${CMAKE_CURRENT_BINARY_DIR}/miniz-${MINIZ_VERSION}.zip")
        // message(STATUS "Zip files: ${ZIP_FILES}")
        // add_custom_command(
        //         COMMAND ${CMAKE_COMMAND} -E copy_directory ${CMAKE_SOURCE_DIR}/examples ${CMAKE_CURRENT_BINARY_DIR}/amalgamation/examples
        //         COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_SOURCE_DIR}/ChangeLog.md ${CMAKE_CURRENT_BINARY_DIR}/amalgamation/ChangeLog.md
        //         COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_SOURCE_DIR}/readme.md ${CMAKE_CURRENT_BINARY_DIR}/amalgamation/readme.md
        //         COMMAND ${CMAKE_COMMAND} -E copy ${CMAKE_SOURCE_DIR}/LICENSE ${CMAKE_CURRENT_BINARY_DIR}/amalgamation/LICENSE
        //         COMMAND ${CMAKE_COMMAND} -E tar "cf" "${ZIP_OUT_FN}" --format=zip -- ${ZIP_FILES}
        //         WORKING_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/amalgamation"
        //         OUTPUT  "${ZIP_OUT_FN}"
        //         DEPENDS ${ZIP_FILES}
        //         COMMENT "Zipping to ${CMAKE_CURRENT_BINARY_DIR}/miniz.zip."
        //     )
        //
        //     add_custom_target(
        //     create_zip ALL
        //     DEPENDS "${ZIP_OUT_FN}"
        //     )
    } else {
        std.log.err("TODO: Non-amalgamated", .{});

        //   include(GenerateExportHeader)
        //   set(miniz_SOURCE miniz.c miniz_zip.c miniz_tinfl.c miniz_tdef.c)
        //   add_library(${PROJECT_NAME} ${miniz_SOURCE})
        //   generate_export_header(${PROJECT_NAME})
        //
        //   if(NOT BUILD_SHARED_LIBS)
        //     string(TOUPPER ${PROJECT_NAME} PROJECT_UPPER)
        //     set_target_properties(${PROJECT_NAME}
        //         PROPERTIES INTERFACE_COMPILE_DEFINITIONS ${PROJECT_UPPER}_STATIC_DEFINE)
        //   else()
        //     set_property(TARGET ${PROJECT_NAME} PROPERTY C_VISIBILITY_PRESET hidden)
        //   endif()
        //
        //   set_property(TARGET ${PROJECT_NAME} PROPERTY VERSION ${MINIZ_VERSION})
        //   set_property(TARGET ${PROJECT_NAME} PROPERTY SOVERSION ${MINIZ_API_VERSION})
        //
        //   target_include_directories(${PROJECT_NAME} PUBLIC
        //     $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}>
        //     $<BUILD_INTERFACE:${CMAKE_CURRENT_BINARY_DIR}>
        //     $<INSTALL_INTERFACE:include>
        //   )
        //
        //   file(GLOB INSTALL_HEADERS ${CMAKE_CURRENT_SOURCE_DIR}/*.h)
        //   list(APPEND
        //        INSTALL_HEADERS ${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}_export.h)
    }

    // if(NOT BUILD_HEADER_ONLY)
    //   target_compile_definitions(${PROJECT_NAME}
    //     PRIVATE $<$<C_COMPILER_ID:GNU>:_GNU_SOURCE>)
    //
    //   # pkg-config file
    //   configure_file(miniz.pc.in ${CMAKE_CURRENT_BINARY_DIR}/miniz.pc @ONLY)
    //
    //   if(INSTALL_PROJECT)
    //     install(FILES
    //     ${CMAKE_CURRENT_BINARY_DIR}/miniz.pc
    //     DESTINATION ${CMAKE_INSTALL_LIBDIR}/pkgconfig)
    //   endif()
    // endif()

    if (!build_header_only) {
        // const pkg_config_file = b.addConfigHeader(
        //     .{ .style = .{ .cmake = upstream.path(b, "miniz.pc.in") } },
        //     .{
        //         .PROJECT_NAME = "miniz",
        //         .PROJECT_DESCRIPTION = "Single C source file zlib-replacement library",
        //         .MINIZ_VERSION = b.fmt("{}", .{miniz_version}),
        //         .PROJECT_HOMEPAGE_URL = "https://github.com/richgel999/miniz",
        //         .CMAKE_INSTALL_PREFIX = b.install_prefix,
        //         .CMAKE_INSTALL_LIBDIR = b.lib_dir,
        //         .CMAKE_INSTALL_INCLUDEDIR = b.h_dir,
        //     },
        // );
        // b.getInstallStep().dependOn(&pkg_config_file.step);

        // if (install_project) {
        //     _ = b.addInstallLibFile(pkg_config_file.getOutput(), "pkgconfig/miniz.pc");
        // }
    }

    // if(BUILD_NO_STDIO)
    //   target_compile_definitions(${PROJECT_NAME} PRIVATE MINIZ_NO_STDIO)
    // endif()

    if (build_no_stdio) {
        mod.addCMacro("MINIZ_NO_STDIO", "");
    }

    // if(INSTALL_PROJECT)
    // install(TARGETS ${PROJECT_NAME} EXPORT ${PROJECT_NAME}Targets
    //     RUNTIME  DESTINATION ${CMAKE_INSTALL_BINDIR}
    //     ARCHIVE  DESTINATION ${CMAKE_INSTALL_LIBDIR}
    //     LIBRARY  DESTINATION ${CMAKE_INSTALL_LIBDIR}
    //     # users can use <miniz.h> or <miniz/miniz.h>
    //     INCLUDES DESTINATION include ${CMAKE_INSTALL_INCLUDEDIR}/${PROJECT_NAME}
    // )

    // include(CMakePackageConfigHelpers)
    // write_basic_package_version_file(
    //     "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}/${PROJECT_NAME}ConfigVersion.cmake"
    //     VERSION ${MINIZ_VERSION}
    //     COMPATIBILITY AnyNewerVersion
    // )

    // export(EXPORT ${PROJECT_NAME}Targets
    //     FILE "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}/${PROJECT_NAME}Targets.cmake"
    //     NAMESPACE ${PROJECT_NAME}::
    // )
    // configure_file(Config.cmake.in
    //     "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}/${PROJECT_NAME}Config.cmake"
    //     @ONLY
    // )

    // set(ConfigPackageLocation ${CMAKE_INSTALL_LIBDIR}/cmake/${PROJECT_NAME})
    // install(EXPORT ${PROJECT_NAME}Targets
    //     FILE
    //     ${PROJECT_NAME}Targets.cmake
    //     NAMESPACE
    //     ${PROJECT_NAME}::
    //     DESTINATION
    //     ${ConfigPackageLocation}
    // )
    // install(
    //     FILES
    //     "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}/${PROJECT_NAME}Config.cmake"
    //     "${CMAKE_CURRENT_BINARY_DIR}/${PROJECT_NAME}/${PROJECT_NAME}ConfigVersion.cmake"
    //     DESTINATION
    //     ${ConfigPackageLocation}
    //     COMPONENT
    //     Devel
    // )
    // endif()

    if (install_project) {
        _ = b.addInstallHeaderFile(lupstream.path(b, "miniz.h"), "headers");
    }

    // Create an unpack step to view the source code we are using.
    const unpack = b.step("unpack", "Installs the unpacked source");
    unpack.dependOn(&b.addInstallDirectory(.{
        .source_dir = upstream,
        .install_dir = .{ .custom = "src" },
        .install_subdir = "",
    }).step);
}

// Version

/// Get the .version field of the `build.zig.zon`.
fn getVersion(allocator: std.mem.Allocator) std.SemanticVersion {
    const @"build.zig.zon" = @embedFile("build.zig.zon");
    var lines = std.mem.splitScalar(u8, @"build.zig.zon", '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, std.mem.trimLeft(u8, line, " \t"), ".version")) {
        const end = std.mem.lastIndexOfScalar(u8, line, '"').?;
        const start = std.mem.lastIndexOfScalar(u8, line[0..end], '"').? + 1;
        const version = allocator.dupe(u8, line[start..end]) catch @panic("OOM");
        return std.SemanticVersion.parse(version) catch unreachable;
    };
    unreachable;
}

// Tools

const LazyPathOrString = union(enum) {
    lazy_path: std.Build.LazyPath,
    string: []const u8,
};

fn amalgamate(
    b: *std.Build,
    headers: []const LazyPathOrString,
    sources: []const LazyPathOrString,
    additional_includes: []const []const u8,
    header_only: bool,
) *Step {
    const mod = b.createModule(.{
        .target = target,
        .optimize = .ReleaseFast,
        .root_source_file = b.path("tools/amalgamate.zig"),
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
    run.addFileArg(b.path(".zig-cache/generated/miniz/miniz.h"));

    run.addArg("--source-output");
    run.addFileArg(b.path(".zig-cache/generated/miniz/miniz.c"));

    return &run.step;
}

// Build-Time Logging

const LogWriteFilesStep = struct {
    step: Step,
    write_files: *Step.WriteFile,

    pub fn init(b: *std.Build, write_files: *Step.WriteFile) *@This() {
        const step = b.allocator.create(@This()) catch @panic("OOM");
        step.step = std.Build.Step.init(.{
            .name = "log write files",
            .id = .custom,
            .makeFn = makeFn,
            .owner = b,
        });
        step.write_files = write_files;

        step.step.dependOn(&write_files.step);
        return step;
    }

    fn makeFn(step: *Step, _: Step.MakeOptions) anyerror!void {
        const print = std.debug.print;

        const lwf: *@This() = @fieldParentPtr("step", step);
        const wf = lwf.write_files;

        print("[debug] Copying to \"{s}\":\n", .{wf.generated_directory.getPath()});
        if (wf.files.items.len > 0) print("\tFiles:\n", .{});
        for (wf.files.items, 0..) |file, i| {
            print("\t  [{}] ", .{i});
            switch (file.contents) {
                .bytes => print("<bytes>", .{}),
                .copy => |path| print("(copy) {}", .{path.getPath3(step.owner, step)}),
            }
            print(" => {s}\n", .{file.sub_path});
        }
        if (wf.directories.items.len > 0) print("\tDirectories:\n", .{});
        for (wf.directories.items, 0..) |dir, i| {
            // TODO: Log include and exclude extensions.
            print("\t  [{}] {}\n", .{ i, dir.source.path(step.owner, dir.sub_path).getPath3(step.owner, step) });
        }
    }
};
