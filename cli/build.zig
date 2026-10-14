// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2021 The Elixir Team

const std = @import("std");

pub const Tool = enum { elixir, elixirc, iex, mix };

const release_targets = [_][]const u8{
    "aarch64-linux-musl",
    "x86_64-linux-musl",
    "aarch64-macos",
    "x86_64-macos",
    "aarch64-windows-gnu",
    "x86_64-windows-gnu",
    "aarch64-freebsd",
    "x86_64-freebsd",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .small });

    const skip_erl = b.option(
        bool,
        "skip-erl",
        "Start erlexec directly and do not run the erl shell script (default: true)",
    ) orelse true;

    addTools(b, target, optimize, skip_erl, .default);

    // Put the executables for each target in zig-out/<target>/bin.
    const release = b.step("release", "Build the executables for all supported targets");
    for (release_targets) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable;
        const resolved = b.resolveTargetQuery(query);
        const dir: std.Build.Step.InstallArtifact.Options.Dir = .{
            .override = .{ .custom = b.fmt("{s}/bin", .{triple}) },
        };
        for (std.enums.values(Tool)) |tool| {
            const exe = addTool(b, tool, resolved, optimize, skip_erl);
            release.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = dir }).step);
        }
    }
}

fn addTools(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    skip_erl: bool,
    dir: std.Build.Step.InstallArtifact.Options.Dir,
) void {
    for (std.enums.values(Tool)) |tool| {
        const exe = addTool(b, tool, target, optimize, skip_erl);
        b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = dir }).step);
    }
}

fn addTool(
    b: *std.Build,
    tool: Tool,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    skip_erl: bool,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption(Tool, "tool", tool);
    options.addOption(bool, "skip_erl", skip_erl);

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
    });
    module.addOptions("build_options", options);
    module.addAnonymousImport("VERSION", .{ .root_source_file = b.path("../VERSION") });

    return b.addExecutable(.{ .name = @tagName(tool), .root_module = module });
}
