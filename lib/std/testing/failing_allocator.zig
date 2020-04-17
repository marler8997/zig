const std = @import("../std.zig");
const mem = std.mem;

/// Allocator that fails after N allocations, useful for making sure out of
/// memory conditions are handled correctly.
///
/// To use this, first initialize it and get an allocator with
///
/// `const failing_allocator = &FailingAllocator.init(<allocator>,
///                                                   <fail_index>).allocator;`
///
/// Then use `failing_allocator` anywhere you would have used a
/// different allocator.
pub const FailingAllocator = struct {
    allocator: mem.Allocator,
    index: usize,
    fail_index: usize,
    internal_allocator: *mem.Allocator,
    allocated_bytes: usize,
    freed_bytes: usize,
    allocations: usize,
    deallocations: usize,

    /// `fail_index` is the number of successful allocations you can
    /// expect from this allocator. The next allocation will fail.
    /// For example, if this is called with `fail_index` equal to 2,
    /// the following test will pass:
    ///
    /// var a = try failing_alloc.create(i32);
    /// var b = try failing_alloc.create(i32);
    /// testing.expectError(error.OutOfMemory, failing_alloc.create(i32));
    pub fn init(allocator: *mem.Allocator, fail_index: usize) FailingAllocator {
        return FailingAllocator{
            .internal_allocator = allocator,
            .fail_index = fail_index,
            .index = 0,
            .allocated_bytes = 0,
            .freed_bytes = 0,
            .allocations = 0,
            .deallocations = 0,
            .allocator = mem.Allocator{
                .allocFn = alloc,
                .shrinkFn = shrink,
                .resizeFn = resize,
            },
        };
    }

    fn alloc(allocator: *std.mem.Allocator, len: usize, alignment: u29) error{OutOfMemory}![]u8 {
        const self = @fieldParentPtr(@This(), "allocator", allocator);
        if (self.index == self.fail_index) {
            return error.OutOfMemory;
        }
        const result = try self.internal_allocator.allocMem(len, alignment);
        self.allocated_bytes += len;
        self.allocations += 1;
        self.index += 1;
        return result;
    }

    fn shrink(allocator: *std.mem.Allocator, buf: []u8, new_len: usize) void {
        const self = @fieldParentPtr(@This(), "allocator", allocator);
        self.internal_allocator.shrinkMem(buf, new_len);
        self.freed_bytes += buf.len - new_len;
        if (new_len == 0)
            self.deallocations += 1;
    }

    fn resize(allocator: *std.mem.Allocator, buf: []u8, new_len: usize) error{OutOfMemory}!void {
        const self = @fieldParentPtr(@This(), "allocator", allocator);
        try self.internal_allocator.resizeMem(buf, new_len);
        if (new_len < buf.len) {
            self.freed_bytes += buf.len - new_len;
        } else {
            self.allocated_bytes += new_len - buf.len;
        }
    }
};
