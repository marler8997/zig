const std = @import("std");

pub fn build(b: *std.Build) !void {
    const options = b.addOptions();

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "zig",
        .root_source_file = b.path("src/automain.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);
}
