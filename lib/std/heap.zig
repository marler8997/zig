const std = @import("std.zig");
const root = @import("root");
const debug = std.debug;
const assert = debug.assert;
const testing = std.testing;
const mem = std.mem;
const os = std.os;
const builtin = @import("builtin");
const c = std.c;
const maxInt = std.math.maxInt;

pub const LoggingAllocator = @import("heap/logging_allocator.zig").LoggingAllocator;
pub const loggingAllocator = @import("heap/logging_allocator.zig").loggingAllocator;
pub const ArenaAllocator = @import("heap/arena_allocator.zig").ArenaAllocator;

const Allocator = mem.Allocator;

pub const c_allocator = &c_allocator_state;
var c_allocator_state = Allocator{
    .allocFn = cAlloc,
    .resizeFn = cResize,
};

fn cAlloc(self: *Allocator, len: usize, alignment: u29) Allocator.Error![]u8 {
    assert(alignment <= @alignOf(c_longdouble));
    const buf = c.malloc(len) orelse return error.OutOfMemory;
    return @ptrCast([*]u8, buf)[0..len];
}

// C's heap does not support a resize (in place) operation. If we want to
// to support C's realloc through mem.Allocator then we could either add
// a new function pointer or have special case handling for the C heap.
// For the "new function pointer" solution, we could add a reallocFn function pointer
// and mem.Allocator would provide a default implementation for most allocators.
fn cResize(self: *Allocator, buf: []u8, new_len: usize) usize {
    if (new_len == 0) {
        c.free(buf.ptr);
        return 0;
    }
    // TODO: is there any cases where we can guarantee that realloc won't move memory?  such as when new_len < buf.len?
    // TODO: use malloc_usable_size to see how much is available?
    return buf.len;
}

/// This allocator makes a syscall directly for every allocation and free.
/// Thread-safe and lock-free.
pub const page_allocator = if (std.Target.current.isWasm())
    &wasm_page_allocator_state
else if (std.Target.current.os.tag == .freestanding)
    root.os.heap.page_allocator
else
    &page_allocator_state;

var page_allocator_state = Allocator{
    .allocFn = PageAllocator.alloc,
    .resizeFn = PageAllocator.resize,
};
var wasm_page_allocator_state = Allocator{
    .allocFn = WasmPageAllocator.alloc,
    .resizeFn = WasmPageAllocator.resize,
};

pub const direct_allocator = @compileError("deprecated; use std.heap.page_allocator");

const PageAllocator = struct {
    fn alloc(allocator: *Allocator, n: usize, alignment: u29) error{OutOfMemory}![]u8 {
        assert(n > 0);

        if (builtin.os.tag == .windows) {
            const w = os.windows;

            // Although officially it's at least aligned to page boundary,
            // Windows is known to reserve pages on a 64K boundary. It's
            // even more likely that the requested alignment is <= 64K than
            // 4K, so we're just allocating blindly and hoping for the best.
            // see https://devblogs.microsoft.com/oldnewthing/?p=42223
            const addr = w.VirtualAlloc(
                null,
                n,
                w.MEM_COMMIT | w.MEM_RESERVE,
                w.PAGE_READWRITE,
            ) catch return error.OutOfMemory;

            // If the allocation is sufficiently aligned, use it.
            if (@ptrToInt(addr) & (alignment - 1) == 0) {
                return @ptrCast([*]u8, addr)[0..n];
            }

            // If it wasn't, actually do an explicitely aligned allocation.
            w.VirtualFree(addr, 0, w.MEM_RELEASE);
            // TODO: we could subtract MIN_VIRTUAL_ALLOC_ALIGN from this size
            const alloc_size = n + alignment;

            const final_addr = while (true) {
                // Reserve a range of memory large enough to find a sufficiently
                // aligned address.
                const reserved_addr = w.VirtualAlloc(
                    null,
                    alloc_size,
                    w.MEM_RESERVE,
                    w.PAGE_NOACCESS,
                ) catch return error.OutOfMemory;
                const aligned_addr = mem.alignForward(@ptrToInt(reserved_addr), alignment);

                // Release the reserved pages (not actually used).
                w.VirtualFree(reserved_addr, 0, w.MEM_RELEASE);

                // At this point, it is possible that another thread has
                // obtained some memory space that will cause the next
                // VirtualAlloc call to fail. To handle this, we will retry
                // until it succeeds.
                const ptr = w.VirtualAlloc(
                    @intToPtr(*c_void, aligned_addr),
                    n,
                    w.MEM_COMMIT | w.MEM_RESERVE,
                    w.PAGE_READWRITE,
                ) catch continue;

                return @ptrCast([*]u8, ptr)[0..n];
            };

            return @ptrCast([*]u8, final_addr)[0..n];
        }

        const maxDropLen = alignment - std.math.min(alignment, mem.page_size);
        const alignedLen = mem.alignForward(n, mem.page_size);
        const allocLen = if (maxDropLen <= alignedLen - n) alignedLen
            else mem.alignForward(alignedLen + maxDropLen, mem.page_size);
        const slice = os.mmap(
            null,
            allocLen,
            os.PROT_READ | os.PROT_WRITE,
            os.MAP_PRIVATE | os.MAP_ANONYMOUS,
            -1,
            0,
        ) catch return error.OutOfMemory;
        assert(mem.isAligned(@ptrToInt(slice.ptr), mem.page_size));

        const aligned_addr = mem.alignForward(@ptrToInt(slice.ptr), alignment);

        // Unmap the extra bytes that were only requested in order to guarantee
        // that the range of memory we were provided had a proper alignment in
        // it somewhere. The extra bytes could be at the beginning, or end, or both.
        const dropLen = aligned_addr - @ptrToInt(slice.ptr);
        if (dropLen != 0) {
            os.munmap(slice[0..dropLen]);
        }
        return @intToPtr([*]u8, aligned_addr)[0..allocLen - dropLen];
    }

    fn resize(allocator: *Allocator, buf_unaligned: []u8, new_size: usize) usize {
        if (builtin.os.tag == .windows) {
            const w = os.windows;
            if (new_size == 0) {
                // From the docs:
                // "If the dwFreeType parameter is MEM_RELEASE, this parameter
                // must be 0 (zero). The function frees the entire region that
                // is reserved in the initial allocation call to VirtualAlloc."
                // So we can only use MEM_RELEASE when actually releasing the
                // whole allocation.
                w.VirtualFree(buf_unaligned.ptr, 0, w.MEM_RELEASE);
                return 0;
            }
            if (new_size < buf_unaligned.len) {
                const base_addr = @ptrToInt(buf_unaligned.ptr);
                const old_addr_end = base_addr + buf_unaligned.len;
                const new_addr_end = mem.alignForward(base_addr + new_size, mem.page_size);
                if (old_addr_end > new_addr_end) {
                    // For shrinking that is not releasing, we will only
                    // decommit the pages not needed anymore.
                    w.VirtualFree(
                        @intToPtr(*c_void, new_addr_end),
                        old_addr_end - new_addr_end,
                        w.MEM_DECOMMIT,
                    );
                }
                return new_size;
            }
            // new_size >= buf_unaligned.len not implemented
            return buf_unaligned.len;
        }

        const buf_aligned_len = mem.alignForward(buf_unaligned.len, mem.page_size);
        const new_size_aligned = mem.alignForward(new_size, mem.page_size);
        if (new_size_aligned == buf_aligned_len)
            return new_size_aligned;

        if (new_size_aligned < buf_aligned_len) {
            const ptr = @intToPtr([*]align(mem.page_size) u8, @ptrToInt(buf_unaligned.ptr) + new_size_aligned);
            os.munmap(ptr[0 .. buf_aligned_len - new_size_aligned]);
            return new_size_aligned;
        }

        // TODO: call mremap
        return buf_aligned_len;
    }
};

const WasmPageAllocator = struct {
    comptime {
        if (!std.Target.current.isWasm()) {
            @compileError("WasmPageAllocator is only available for wasm32 arch");
        }
    }

    const PageStatus = enum(u1) {
        used = 0,
        free = 1,

        pub const none_free: u8 = 0;
    };

    const FreeBlock = struct {
        data: []u128,

        const Io = std.packed_int_array.PackedIntIo(u1, .Little);

        fn totalPages(self: FreeBlock) usize {
            return self.data.len * 128;
        }

        fn isInitialized(self: FreeBlock) bool {
            return self.data.len > 0;
        }

        fn getBit(self: FreeBlock, idx: usize) PageStatus {
            const bit_offset = 0;
            return @intToEnum(PageStatus, Io.get(mem.sliceAsBytes(self.data), idx, bit_offset));
        }

        fn setBits(self: FreeBlock, start_idx: usize, len: usize, val: PageStatus) void {
            const bit_offset = 0;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                Io.set(mem.sliceAsBytes(self.data), start_idx + i, bit_offset, @enumToInt(val));
            }
        }

        // Use '0xFFFFFFFF' as a _missing_ sentinel
        // This saves ~50 bytes compared to returning a nullable

        // We can guarantee that conventional memory never gets this big,
        // and wasm32 would not be able to address this memory (32 GB > usize).

        // Revisit if this is settled: https://github.com/ziglang/zig/issues/3806
        const not_found = std.math.maxInt(usize);

        fn useRecycled(self: FreeBlock, num_pages: usize) usize {
            @setCold(true);
            for (self.data) |segment, i| {
                const spills_into_next = @bitCast(i128, segment) < 0;
                const has_enough_bits = @popCount(u128, segment) >= num_pages;

                if (!spills_into_next and !has_enough_bits) continue;

                var j: usize = i * 128;
                while (j < (i + 1) * 128) : (j += 1) {
                    var count: usize = 0;
                    while (j + count < self.totalPages() and self.getBit(j + count) == .free) {
                        count += 1;
                        if (count >= num_pages) {
                            self.setBits(j, num_pages, .used);
                            return j;
                        }
                    }
                    j += count;
                }
            }
            return not_found;
        }

        fn recycle(self: FreeBlock, start_idx: usize, len: usize) void {
            self.setBits(start_idx, len, .free);
        }
    };

    var _conventional_data = [_]u128{0} ** 16;
    // Marking `conventional` as const saves ~40 bytes
    const conventional = FreeBlock{ .data = &_conventional_data };
    var extended = FreeBlock{ .data = &[_]u128{} };

    fn extendedOffset() usize {
        return conventional.totalPages();
    }

    fn nPages(memsize: usize) usize {
        return mem.alignForward(memsize, mem.page_size) / mem.page_size;
    }

    fn alloc(allocator: *Allocator, len: usize, alignment: u29) error{OutOfMemory}![]u8 {
        const page_count = nPages(len);
        const page_idx = try allocPages(page_count);
        return @intToPtr([*]u8, page_idx * mem.page_size)[0.. page_count * mem.page_size];
    }
    fn allocPages(page_count: usize) !usize {
        {
            const idx = conventional.useRecycled(page_count);
            if (idx != FreeBlock.not_found) {
                return idx;
            }
        }

        const idx = extended.useRecycled(page_count);
        if (idx != FreeBlock.not_found) {
            return idx + extendedOffset();
        }

        const prev_page_count = @wasmMemoryGrow(0, @intCast(u32, page_count));
        if (prev_page_count <= 0) {
            return error.OutOfMemory;
        }

        return @intCast(usize, prev_page_count);
    }

    fn freePages(start: usize, end: usize) void {
        {
            const off = extendedOffset();
            if (start < off) {
                conventional.recycle(start, std.math.min(off, end));
            }
        }
        if (end > extendedOffset()) {
            var new_end = end;
            if (!extended.isInitialized()) {
                // Steal the last page from the memory currently being recycled
                // TODO: would it be better if we use the first page instead?
                new_end -= 1;

                extended.data = @intToPtr([*]u128, new_end * mem.page_size)[0 .. mem.page_size / @sizeOf(u128)];
                // Since this is the first page being freed and we consume it, assume *nothing* is free.
                mem.set(u128, extended.data, PageStatus.none_free);
            }
            const clamped_start = std.math.max(extendedOffset(), start);
            extended.recycle(clamped_start - extendedOffset(), new_end - clamped_start);
        }
    }

    fn resize(allocator: *Allocator, buf: []u8, new_len: usize) usize {
        if (new_len >= buf.len) return buf.len;
        assert(mem.isAligned(buf.len, mem.page_size)); // sanity check
        const current_n = nPages(buf.len);
        const new_n = nPages(new_len);
        if (new_n != current_n) {
            const base = nPages(@ptrToInt(buf.ptr));
            freePages(base + new_n, base + current_n);
        }
        return new_n * mem.page_size;
    }
};

pub const HeapAllocator = switch (builtin.os.tag) {
    .windows => struct {
        allocator: Allocator,
        heap_handle: ?HeapHandle,

        const HeapHandle = os.windows.HANDLE;

        pub fn init() HeapAllocator {
            return HeapAllocator{
                .allocator = Allocator{
                    .allocFn = alloc,
                    .resizeFn = resize,
                },
                .heap_handle = null,
            };
        }

        pub fn deinit(self: *HeapAllocator) void {
            if (self.heap_handle) |heap_handle| {
                os.windows.HeapDestroy(heap_handle);
            }
        }

        fn getRecordPtr(buf: []u8) *align(1) usize {
            return @intToPtr(*align(1) usize, @ptrToInt(buf.ptr) + buf.len);
        }

        fn alloc(allocator: *Allocator, n: usize, alignment: u29) error{OutOfMemory}![]u8 {
            const self = @fieldParentPtr(HeapAllocator, "allocator", allocator);
            if (n == 0) return &[0]u8{};

            const amt = n + alignment + @sizeOf(usize);
            const optional_heap_handle = @atomicLoad(?HeapHandle, &self.heap_handle, builtin.AtomicOrder.SeqCst);
            const heap_handle = optional_heap_handle orelse blk: {
                const options = if (builtin.single_threaded) os.windows.HEAP_NO_SERIALIZE else 0;
                const hh = os.windows.kernel32.HeapCreate(options, amt, 0) orelse return error.OutOfMemory;
                const other_hh = @cmpxchgStrong(?HeapHandle, &self.heap_handle, null, hh, builtin.AtomicOrder.SeqCst, builtin.AtomicOrder.SeqCst) orelse break :blk hh;
                os.windows.HeapDestroy(hh);
                break :blk other_hh.?; // can't be null because of the cmpxchg
            };
            const ptr = os.windows.kernel32.HeapAlloc(heap_handle, 0, amt) orelse return error.OutOfMemory;
            const root_addr = @ptrToInt(ptr);
            const buf = @intToPtr([*]u8, mem.alignForward(root_addr, alignment))[0..n];
            getRecordPtr(buf).* = root_addr;
            return buf;
        }

        fn resize(allocator: *Allocator, buf: []u8, new_size: usize) usize {
            const self = @fieldParentPtr(HeapAllocator, "allocator", allocator);
            if (new_len == 0) {
                os.windows.HeapFree(self.heap_handle.?, 0, @intToPtr(*c_void ,getRecordPtr(buf).*));
                return 0;
            }

            const root_addr = getRecordPtr(buf).*;
            const amt = (@ptrToInt(buf.ptr) - root_addr) + new_size + @sizeOf(usize);
            const new_ptr = os.windows.kernel32.HeapReAlloc(
                self.heap_handle.?,
                os.windows.HEAP_REALLOC_IN_PLACE_ONLY,
                @intToPtr(*c_void, root_addr),
                amt,
            ) orelse return error.OutOfMemory;
            assert(new_ptr == @intToPtr(*c_void, root_addr));
            getRecordPtr(buf.ptr[0..new_size]).* = root_addr;
        }
    },
    else => @compileError("Unsupported OS"),
};

fn sliceContainsPtr(container: []u8, ptr: [*]u8) bool {
    return @ptrToInt(ptr) >= @ptrToInt(container.ptr) and
        @ptrToInt(ptr) < (@ptrToInt(container.ptr) + container.len);
}

fn sliceContainsSlice(container: []u8, slice: []u8) bool {
    return @ptrToInt(slice.ptr) >= @ptrToInt(container.ptr) and
        (@ptrToInt(slice.ptr) + slice.len) <= (@ptrToInt(container.ptr) + container.len);
}

pub const FixedBufferAllocator = struct {
    allocator: Allocator,
    end_index: usize,
    buffer: []u8,

    pub fn init(buffer: []u8) FixedBufferAllocator {
        return FixedBufferAllocator{
            .allocator = Allocator{
                .allocFn = alloc,
                .resizeFn = resize,
            },
            .buffer = buffer,
            .end_index = 0,
        };
    }

    pub fn ownsPtr(self: *FixedBufferAllocator, ptr: [*]u8) bool {
        return sliceContainsPtr(self.buffer, ptr);
    }

    pub fn ownsSlice(self: *FixedBufferAllocator, slice: []u8) bool {
        return sliceContainsSlice(self.buffer, slice);
    }

    // NOTE: this will not work in all cases, if the last allocation had an adjusted_index
    //       then we won't be able to determine what the last allocation was.  This is because
    //       the alignForward operation done in alloc is not reverisible.
    pub fn isLastAllocation(self: *FixedBufferAllocator, buf: []u8) bool {
        return buf.ptr + buf.len == self.buffer.ptr + self.end_index;
    }

    fn alloc(allocator: *Allocator, n: usize, alignment: u29) ![]u8 {
        const self = @fieldParentPtr(FixedBufferAllocator, "allocator", allocator);
        const aligned_addr = mem.alignForward(@ptrToInt(self.buffer.ptr) + self.end_index, alignment);
        const adjusted_index = aligned_addr - @ptrToInt(self.buffer.ptr);
        const new_end_index = adjusted_index + n;
        if (new_end_index > self.buffer.len) {
            return error.OutOfMemory;
        }
        const result = self.buffer[adjusted_index..new_end_index];
        self.end_index = new_end_index;

        return result;
    }

    fn resize(allocator: *Allocator, buf: []u8, new_size: usize) usize {
        const self = @fieldParentPtr(FixedBufferAllocator, "allocator", allocator);
        assert(self.ownsSlice(buf)); // sanity check

        if (!self.isLastAllocation(buf))
            return buf.len;

        if (new_size <= buf.len) {
            const sub = buf.len - new_size;
            self.end_index -= sub;
            return buf.len - sub;
        }
        var add = new_size - buf.len;
        if (add + self.end_index > self.buffer.len)
            add = self.buffer.len - self.end_index;
        self.end_index += add;
        return buf.len + add;
    }

    pub fn reset(self: *FixedBufferAllocator) void {
        self.end_index = 0;
    }
};

pub const ThreadSafeFixedBufferAllocator = blk: {
    if (builtin.single_threaded) {
        break :blk FixedBufferAllocator;
    } else {
        // lock free
        break :blk struct {
            allocator: Allocator,
            end_index: usize,
            buffer: []u8,

            pub fn init(buffer: []u8) ThreadSafeFixedBufferAllocator {
                return ThreadSafeFixedBufferAllocator{
                    .allocator = Allocator{
                        .allocFn = alloc,
                        .resizeFn = Allocator.noResize,
                    },
                    .buffer = buffer,
                    .end_index = 0,
                };
            }

            fn alloc(allocator: *Allocator, n: usize, alignment: u29) ![]u8 {
                const self = @fieldParentPtr(ThreadSafeFixedBufferAllocator, "allocator", allocator);
                var end_index = @atomicLoad(usize, &self.end_index, builtin.AtomicOrder.SeqCst);
                while (true) {
                    const addr = @ptrToInt(self.buffer.ptr) + end_index;
                    const adjusted_addr = mem.alignForward(addr, alignment);
                    const adjusted_index = end_index + (adjusted_addr - addr);
                    const new_end_index = adjusted_index + n;
                    if (new_end_index > self.buffer.len) {
                        return error.OutOfMemory;
                    }
                    end_index = @cmpxchgWeak(usize, &self.end_index, end_index, new_end_index, builtin.AtomicOrder.SeqCst, builtin.AtomicOrder.SeqCst) orelse return self.buffer[adjusted_index..new_end_index];
                }
            }
            pub fn reset(self: *ThreadSafeFixedBufferAllocator) void {
                self.end_index = 0;
            }
        };
    }
};

pub fn stackFallback(comptime size: usize, fallback_allocator: *Allocator) StackFallbackAllocator(size) {
    return StackFallbackAllocator(size){
        .buffer = undefined,
        .fallback_allocator = fallback_allocator,
        .fixed_buffer_allocator = undefined,
        .allocator = Allocator{
            .allocFn = StackFallbackAllocator(size).realloc,
            .resizeFn = StackFallbackAllocator(size).resize,
        },
    };
}

pub fn StackFallbackAllocator(comptime size: usize) type {
    return struct {
        const Self = @This();

        buffer: [size]u8,
        allocator: Allocator,
        fallback_allocator: *Allocator,
        fixed_buffer_allocator: FixedBufferAllocator,

        pub fn get(self: *Self) *Allocator {
            self.fixed_buffer_allocator = FixedBufferAllocator.init(self.buffer[0..]);
            return &self.allocator;
        }

        fn alloc(allocator: *Allocator, len: usize, alignment: u29) error{OutOfMemory}![]u8 {
            const self = @fieldParentPtr(Self, "allocator", allocator);
            return FixedBufferAllocator.alloc(&self.fixed_buffer_allocator, len, alignment) catch
                return fallback_allocator.alloc(len, alignment);
        }

        fn resize(self: *Allocator, buf: []u8, new_len: usize) usize {
            const self = @fieldParentPtr(Self, "allocator", allocator);
            if (self.fixed_buffer_allocator.ownsPtr(buf.ptr)) {
                return self.fixed_buffer_allocator.callResizeFn(buf, new_len);
            }
            return self.fallback_allocator.callResizeFn(buf, new_len);
        }
    };
}

test "c_allocator" {
    if (builtin.link_libc) {
        var slice = try c_allocator.alloc(u8, 50);
        defer c_allocator.free(slice);
        slice = try c_allocator.realloc(slice, 100);
    }
}

test "WasmPageAllocator internals" {
    if (comptime std.Target.current.isWasm()) {
        const conventional_memsize = WasmPageAllocator.conventional.totalPages() * std.mem.page_size;
        const initial = try page_allocator.alloc(u8, std.mem.page_size);
        std.debug.assert(@ptrToInt(initial.ptr) < conventional_memsize); // If this isn't conventional, the rest of these tests don't make sense. Also we have a serious memory leak in the test suite.

        var inplace = try page_allocator.realloc(initial, 1);
        testing.expectEqual(initial.ptr, inplace.ptr);
        inplace = try page_allocator.realloc(inplace, 4);
        testing.expectEqual(initial.ptr, inplace.ptr);
        page_allocator.free(inplace);

        const reuse = try page_allocator.alloc(u8, 1);
        testing.expectEqual(initial.ptr, reuse.ptr);
        page_allocator.free(reuse);

        // This segment may span conventional and extended which has really complex rules so we're just ignoring it for now.
        const padding = try page_allocator.alloc(u8, conventional_memsize);
        page_allocator.free(padding);

        const extended = try page_allocator.alloc(u8, conventional_memsize);
        testing.expect(@ptrToInt(extended.ptr) >= conventional_memsize);

        const use_small = try page_allocator.alloc(u8, 1);
        testing.expectEqual(initial.ptr, use_small.ptr);
        page_allocator.free(use_small);

        inplace = try page_allocator.realloc(extended, 1);
        testing.expectEqual(extended.ptr, inplace.ptr);
        page_allocator.free(inplace);

        const reuse_extended = try page_allocator.alloc(u8, conventional_memsize);
        testing.expectEqual(extended.ptr, reuse_extended.ptr);
        page_allocator.free(reuse_extended);
    }
}

test "PageAllocator" {
    const allocator = page_allocator;
    try testAllocator(allocator);
    try testAllocatorAligned(allocator, 16);
    if (!std.Target.current.isWasm()) {
        try testAllocatorLargeAlignment(allocator);
        try testAllocatorAlignedShrink(allocator);
    }

    if (builtin.os.tag == .windows) {
        // Trying really large alignment. As mentionned in the implementation,
        // VirtualAlloc returns 64K aligned addresses. We want to make sure
        // PageAllocator works beyond that, as it's not tested by
        // `testAllocatorLargeAlignment`.
        const slice = try allocator.alignedAlloc(u8, 1 << 20, 128);
        slice[0] = 0x12;
        slice[127] = 0x34;
        allocator.free(slice);
    }
}

test "HeapAllocator" {
    if (builtin.os.tag == .windows) {
        var heap_allocator = HeapAllocator.init();
        defer heap_allocator.deinit();

        const allocator = &heap_allocator.allocator;
        try testAllocator(allocator);
        try testAllocatorAligned(allocator, 16);
        try testAllocatorLargeAlignment(allocator);
        try testAllocatorAlignedShrink(allocator);
    }
}

test "ArenaAllocator" {
    var arena_allocator = ArenaAllocator.init(page_allocator);
    defer arena_allocator.deinit();

    try testAllocator(&arena_allocator.allocator);
    try testAllocatorAligned(&arena_allocator.allocator, 16);
    try testAllocatorLargeAlignment(&arena_allocator.allocator);
    try testAllocatorAlignedShrink(&arena_allocator.allocator);
}

var test_fixed_buffer_allocator_memory: [800000 * @sizeOf(u64)]u8 = undefined;
test "FixedBufferAllocator" {
    var fixed_buffer_allocator = FixedBufferAllocator.init(test_fixed_buffer_allocator_memory[0..]);

    try testAllocator(&fixed_buffer_allocator.allocator);
    try testAllocatorAligned(&fixed_buffer_allocator.allocator, 16);
    try testAllocatorLargeAlignment(&fixed_buffer_allocator.allocator);
    try testAllocatorAlignedShrink(&fixed_buffer_allocator.allocator);
}

test "FixedBufferAllocator.reset" {
    var buf: [8]u8 align(@alignOf(u64)) = undefined;
    var fba = FixedBufferAllocator.init(buf[0..]);

    const X = 0xeeeeeeeeeeeeeeee;
    const Y = 0xffffffffffffffff;

    var x = try fba.allocator.create(u64);
    x.* = X;
    testing.expectError(error.OutOfMemory, fba.allocator.create(u64));

    fba.reset();
    var y = try fba.allocator.create(u64);
    y.* = Y;

    // we expect Y to have overwritten X.
    testing.expect(x.* == y.*);
    testing.expect(y.* == Y);
}

test "FixedBufferAllocator Reuse memory on realloc" {
    var small_fixed_buffer: [10]u8 = undefined;
    // check if we re-use the memory
    {
        var fixed_buffer_allocator = FixedBufferAllocator.init(&small_fixed_buffer);

        var slice0 = try fixed_buffer_allocator.allocator.alloc(u8, 5);
        testing.expect(slice0.len == 5);
        var slice1 = try fixed_buffer_allocator.allocator.realloc(slice0, 10);
        testing.expect(slice1.ptr == slice0.ptr);
        testing.expect(slice1.len == 10);
        testing.expectError(error.OutOfMemory, fixed_buffer_allocator.allocator.realloc(slice1, 11));
    }
    // check that we don't re-use the memory if it's not the most recent block
    {
        var fixed_buffer_allocator = FixedBufferAllocator.init(&small_fixed_buffer);

        var slice0 = try fixed_buffer_allocator.allocator.alloc(u8, 2);
        slice0[0] = 1;
        slice0[1] = 2;
        var slice1 = try fixed_buffer_allocator.allocator.alloc(u8, 2);
        var slice2 = try fixed_buffer_allocator.allocator.realloc(slice0, 4);
        testing.expect(slice0.ptr != slice2.ptr);
        testing.expect(slice1.ptr != slice2.ptr);
        testing.expect(slice2[0] == 1);
        testing.expect(slice2[1] == 2);
    }
}

test "ThreadSafeFixedBufferAllocator" {
    var fixed_buffer_allocator = ThreadSafeFixedBufferAllocator.init(test_fixed_buffer_allocator_memory[0..]);

    try testAllocator(&fixed_buffer_allocator.allocator);
    try testAllocatorAligned(&fixed_buffer_allocator.allocator, 16);
    try testAllocatorLargeAlignment(&fixed_buffer_allocator.allocator);
    try testAllocatorAlignedShrink(&fixed_buffer_allocator.allocator);
}

fn testAllocator(allocator: *mem.Allocator) !void {
    var slice = try allocator.alloc(*i32, 100);
    testing.expect(slice.len == 100);
    for (slice) |*item, i| {
        item.* = try allocator.create(i32);
        item.*.* = @intCast(i32, i);
    }

    slice = try allocator.realloc(slice, 20000);
    testing.expect(slice.len == 20000);

    for (slice[0..100]) |item, i| {
        testing.expect(item.* == @intCast(i32, i));
        allocator.destroy(item);
    }

    slice = allocator.shrink(slice, 50);
    testing.expect(slice.len == 50);
    slice = allocator.shrink(slice, 25);
    testing.expect(slice.len == 25);
    slice = allocator.shrink(slice, 0);
    testing.expect(slice.len == 0);
    slice = try allocator.realloc(slice, 10);
    testing.expect(slice.len == 10);

    allocator.free(slice);
}

fn testAllocatorAligned(allocator: *mem.Allocator, comptime alignment: u29) !void {
    // initial
    var slice = try allocator.alignedAlloc(u8, alignment, 10);
    testing.expect(slice.len == 10);
    // grow
    slice = try allocator.realloc(slice, 100);
    testing.expect(slice.len == 100);
    // shrink
    slice = allocator.shrink(slice, 10);
    testing.expect(slice.len == 10);
    // go to zero
    slice = allocator.shrink(slice, 0);
    testing.expect(slice.len == 0);
    // realloc from zero
    slice = try allocator.realloc(slice, 100);
    testing.expect(slice.len == 100);
    // shrink with shrink
    slice = allocator.shrink(slice, 10);
    testing.expect(slice.len == 10);
    // shrink to zero
    slice = allocator.shrink(slice, 0);
    testing.expect(slice.len == 0);
}

fn testAllocatorLargeAlignment(allocator: *mem.Allocator) mem.Allocator.Error!void {
    //Maybe a platform's page_size is actually the same as or
    //  very near usize?
    if (mem.page_size << 2 > maxInt(usize)) return;

    const USizeShift = std.meta.Int(false, std.math.log2(usize.bit_count));
    const large_align = @as(u29, mem.page_size << 2);

    var align_mask: usize = undefined;
    _ = @shlWithOverflow(usize, ~@as(usize, 0), @as(USizeShift, @ctz(u29, large_align)), &align_mask);

    var slice = try allocator.alignedAlloc(u8, large_align, 500);
    testing.expect(@ptrToInt(slice.ptr) & align_mask == @ptrToInt(slice.ptr));

    slice = allocator.shrink(slice, 100);
    testing.expect(@ptrToInt(slice.ptr) & align_mask == @ptrToInt(slice.ptr));

    slice = try allocator.realloc(slice, 5000);
    testing.expect(@ptrToInt(slice.ptr) & align_mask == @ptrToInt(slice.ptr));

    slice = allocator.shrink(slice, 10);
    testing.expect(@ptrToInt(slice.ptr) & align_mask == @ptrToInt(slice.ptr));

    slice = try allocator.realloc(slice, 20000);
    testing.expect(@ptrToInt(slice.ptr) & align_mask == @ptrToInt(slice.ptr));

    allocator.free(slice);
}

fn testAllocatorAlignedShrink(allocator: *mem.Allocator) mem.Allocator.Error!void {
    var debug_buffer: [1000]u8 = undefined;
    const debug_allocator = &FixedBufferAllocator.init(&debug_buffer).allocator;

    const alloc_size = mem.page_size * 2 + 50;
    var slice = try allocator.alignedAlloc(u8, 16, alloc_size);
    defer allocator.free(slice);

    var stuff_to_free = std.ArrayList([]align(16) u8).init(debug_allocator);
    // On Windows, VirtualAlloc returns addresses aligned to a 64K boundary,
    // which is 16 pages, hence the 32. This test may require to increase
    // the size of the allocations feeding the `allocator` parameter if they
    // fail, because of this high over-alignment we want to have.
    while (@ptrToInt(slice.ptr) == mem.alignForward(@ptrToInt(slice.ptr), mem.page_size * 32)) {
        try stuff_to_free.append(slice);
        slice = try allocator.alignedAlloc(u8, 16, alloc_size);
    }
    while (stuff_to_free.popOrNull()) |item| {
        allocator.free(item);
    }
    slice[0] = 0x12;
    slice[60] = 0x34;

    // realloc to a smaller size but with a larger alignment
    slice = try allocator.alignedRealloc(slice, mem.page_size * 32, alloc_size / 2);
    testing.expect(slice[0] == 0x12);
    testing.expect(slice[60] == 0x34);
}

test "heap" {
    _ = @import("heap/logging_allocator.zig");
}
