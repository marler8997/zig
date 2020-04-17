const std = @import("../std.zig");
const Allocator = std.mem.Allocator;

/// This allocator is used in front of another allocator and logs to the provided stream
/// on every call to the allocator. Stream errors are ignored.
/// If https://github.com/ziglang/zig/issues/2586 is implemented, this API can be improved.
pub fn LoggingAllocator(comptime OutStreamType: type) type {
    return struct {
        allocator: Allocator,
        parent_allocator: *Allocator,
        out_stream: OutStreamType,

        const Self = @This();

        pub fn init(parent_allocator: *Allocator, out_stream: OutStreamType) Self {
            return Self{
                .allocator = Allocator{
                    .allocFn = alloc,
                    .resizeFn = resize,
                },
                .parent_allocator = parent_allocator,
                .out_stream = out_stream,
            };
        }

        fn alloc(allocator: *std.mem.Allocator, len: usize, alignment: u29) error{OutOfMemory}![]u8 {
            const self = @fieldParentPtr(Self, "allocator", allocator);
            self.out_stream.print("alloc: {} ", .{len}) catch {};
            const result = self.parent_allocator.callAllocFn(len, alignment);
            if (result) |buff| {
                self.out_stream.print("success!\n", .{}) catch {};
            } else |err| {
                self.out_stream.print("failure!\n", .{}) catch {};
            }
            return result;
        }

        fn resize(allocator: *std.mem.Allocator, buf: []u8, new_len: usize) usize {
            const self = @fieldParentPtr(Self, "allocator", allocator);
            if (new_len == 0) {
                self.out_stream.print("free : {}\n", .{buf.len}) catch {};
            } else {
                self.out_stream.print("resize from {} to {} ", .{ buf.len, new_len }) catch {};
            }
            const result = self.parent_allocator.callResizeFn(buf, new_len);
            if (new_len > 0) {
                if (result >= new_len) {
                    self.out_stream.print("success!\n", .{}) catch {};
                } else {
                    self.out_stream.print("failure!\n", .{}) catch {};
                }
            }
            return result;
        }
    };
}

pub fn loggingAllocator(
    parent_allocator: *Allocator,
    out_stream: var,
) LoggingAllocator(@TypeOf(out_stream)) {
    return LoggingAllocator(@TypeOf(out_stream)).init(parent_allocator, out_stream);
}

test "LoggingAllocator" {
    var buf: [255]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const allocator = &loggingAllocator(std.testing.allocator, fbs.outStream()).allocator;

    const ptr = try allocator.alloc(u8, 10);
    allocator.free(ptr);

    const allocSize = 10 + Allocator.ExactAllocPadding;
    var expectedBuf: [255]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expectedBuf,
           \\alloc: {} success!
           \\free : {}
           \\
    , .{allocSize, allocSize});
    std.testing.expectEqualSlices(u8, expected, fbs.getWritten());
}
