const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dvui_dep = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
        // .@"tree-sitter" = true,
    });

    const dvui_sdl = dvui_dep.module("dvui_sdl3");

    _ = b.addModule("lib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "dvui", .module = dvui_sdl },
        },
    });

    // const gen = b.addExecutable(.{
    //     .name = "gen",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/generate.zig"),
    //         .target = target,
    //         .optimize = optimize,
    //         .imports = &.{
    //             .{ .name = "markdown", .module = md_mod },
    //         },
    //     }),
    // });

    // b.installArtifact(gen);
}
