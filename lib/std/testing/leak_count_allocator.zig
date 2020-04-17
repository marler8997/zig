const std = @import("../std.zig");

/// This allocator is used in front of another allocator and counts the numbers of allocs and frees.
/// The test runner asserts every alloc has a corresponding free at the end of each test.
///
/// The detection algorithm is incredibly primitive and only accounts for number of calls.
/// This should be replaced by the general purpose debug allocator.
pub const LeakCountAllocator = struct {
    count: usize,
    allocator: std.mem.Allocator,
    internal_allocator: *std.mem.Allocator,

    pub fn init(allocator: *std.mem.Allocator) LeakCountAllocator {
        return .{
            .count = 0,
            .allocator = .{
                .allocFn = alloc,
                .shrinkFn = shrink,
                //.resizeFn = allocator.resizeFn, // this is a compile error?
                .resizeFn = resize,
            },
            .internal_allocator = allocator,
        };
    }

    fn alloc(allocator: *std.mem.Allocator, len: usize, alignment: u29) error{OutOfMemory}![]u8 {
        const self = @fieldParentPtr(LeakCountAllocator, "allocator", allocator);
        var data = try self.internal_allocator.allocMem(len, alignment);
        self.count += 1;
        return data;
    }

    fn shrink(allocator: *std.mem.Allocator, buf: []u8, new_len: usize) void {
        const self = @fieldParentPtr(LeakCountAllocator, "allocator", allocator);
        self.internal_allocator.shrinkMem(buf, new_len);
        if (new_len == 0) {
            if (self.count == 0) {
                std.debug.panic("error - too many calls to free, most likely double free", .{});
            }
            self.count -= 1;
        }
    }

    fn resize(allocator: *std.mem.Allocator, buf: []u8, new_len: usize) error{OutOfMemory}!void {
        const self = @fieldParentPtr(LeakCountAllocator, "allocator", allocator);
        return self.internal_allocator.resizeMem(buf, new_len);
    }

    pub fn validate(self: LeakCountAllocator) !void {
        if (self.count > 0) {
            std.debug.warn("error - detected leaked allocations without matching free: {}\n", .{self.count});
            return error.Leak;
        }
    }
};
