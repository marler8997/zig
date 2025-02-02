const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const coffdump = b.addExecutable(.{
        .name = "coffdump",
        .root_source_file = b.path("tools/coffdump.zig"),
        .target = target,
        .optimize = .Debug,
        .single_threaded = true,
    });
    b.installArtifact(coffdump);
}
