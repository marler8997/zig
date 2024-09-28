const std = @import("std");

pub fn build(b: *std.Build) void {
    if (b.option(bool, "resolve-path-during-config", "") orelse false) {
        const path = b.path("foo");
        _ = path.getPath(b);
        @panic("getPath didn't panic like it should have");
    }

    b.step("use-lazy-path-without-depending-on-it", "").dependOn(
        &DanglingLazyPath.create(b).step,
    );

    // what about a step that creates a lazy path?
    // can that step reference the lazy path?
}

const DanglingLazyPath = struct {
    step: std.Build.Step,
    lazy_path: std.Build.LazyPath,
    pub fn create(b: *std.Build) *DanglingLazyPath {
        const d = b.allocator.create(DanglingLazyPath) catch @panic("OOM");
        d.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "dangling lazy path",
                .owner = b,
                .makeFn = make,
            }),
            .lazy_path = b.path("dangling"),
        };
        return d;
    }
    fn make(step: *std.Build.Step, options: std.Build.Step.MakeOptions) !void {
        _ = options;
        const d: *DanglingLazyPath = @fieldParentPtr("step", step);
        _ = d.lazy_path.getPath(step.owner); // should panic
        @panic("getPath didn't panic like it should have");
    }
};
