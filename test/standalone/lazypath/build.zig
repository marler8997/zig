const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_step = b.step("test", "Test it");
    b.default_step = test_step;

    {
        const zig_build = addZigBuild(b);
        zig_build.addArg("-Dresolve-path-during-config");
        zig_build.addCheck(.{ .expect_stderr_match = "getPath called on LazyPath outside of any step's make function" });
        test_step.dependOn(&zig_build.step);
    }
    {
        const zig_build = addZigBuild(b);
        zig_build.addArg("use-lazy-path-without-depending-on-it");
        zig_build.addCheck(.{ .expect_stderr_match = "step 'dangling lazy path' is missing a dependency on lazy path 'dangling'" });
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
