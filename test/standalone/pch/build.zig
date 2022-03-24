const Builder = @import("std").build.Builder;

pub fn build(b: *Builder) void {
    const pch = b.addObject("test.pch", "test.h");
    pch.linkLibC();

    const exe = b.addExecutable("test", "test.c");
    exe.addPrecompiledHeader(pch);
    const run = exe.run();
    run.stdout_action = .{
        .expect_exact = "Success\n",
    };

    const test_step = b.step("test", "Test precompiled headers");
    test_step.dependOn(&run.step);
    b.default_step.dependOn(test_step);
}
