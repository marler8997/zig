const builtin = @import("builtin");
const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Test it");
    b.default_step = test_step;

    {
        const zig_build = addZigBuild(b);
        test_step.dependOn(&zig_build.step);
    }
    {
        const zig_build = addZigBuild(b);
        zig_build.addArg("noop");
        test_step.dependOn(&zig_build.step);
    }
    {
        const zig_build = addZigBuild(b);
        zig_build.addArg("need_always_unavailable_by_artifact");
        expectAlwaysUnavailableError(zig_build);
        test_step.dependOn(&zig_build.step);
    }
    {
        const zig_build = addZigBuild(b);
        zig_build.addArg("need_always_unavailable_by_module");
        expectAlwaysUnavailableError(zig_build);
        test_step.dependOn(&zig_build.step);
    }
}

fn addZigBuild(b: *std.Build) *std.Build.Step.Run {
    return b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        "--build-file",
        b.pathFromRoot("example/build.zig"),
    });
}

fn expectAlwaysUnavailableError(zig_build: *std.Build.Step.Run) void {
    zig_build.addCheck(.{ .expect_stderr_match = "unable to connect to server" });
}
