const std = @import("std");

pub fn build(b: *std.Build) void {
    const always_unavailable = b.dependency("always_unavailable", .{});
    _ = b.step("noop", "");
    b.step("need_always_unavailable_by_artifact", "").dependOn(
        &always_unavailable.artifact("some_artifact").step
    );

    const exe = b.addExecutable(.{
        .name = "some_exe",
        .target = b.host,
        .root_source_file = b.path("some_exe.zig"),
    });
    exe.root_module.addImport("some_module", always_unavailable.module("some_module"));
    b.step("need_always_unavailable_by_module", "").dependOn(&exe.step);
}
