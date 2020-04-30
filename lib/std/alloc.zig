/// A generic composable allocation library.
///
/// Example:
///
///     // Make an aligned "C heap" allocator that logs on each allocation
///     const a = Alloc.c.log().aligned().slice().init;
///     const s = a.alloc(1234); // s is []u8
///     defer a.dealloc(s);
///
///     // Make an mmap allocator that logs on each allocation
///     const a = Alloc.mmap.log().slice().init;
///     const s = a.alloc(1234); // s is []u8
///     defer a.dealloc(s);
///
///     // Create an allocator that tries to allocate on the stack, then falls back to the C allocator
///     var stackBuffer : [100]u8 = undefiend;
///     const a = Alloc.join(.{
///         Alloc.bumpDown(1, stackBuffer).init,
///         Alloc.c.init,
///     }).slice().init;
///     const s = a.alloc(40);
///     defer a.dealloc(s);
///
///     // Create a custom allocator and custom wrapper
///     const MyAllocator = struct { ... };
///     const MyAllocatorWrapper = struct { ... };
///     const a = Alloc.custom(MyAllocator { ... }).aligned()
///         .custom(MyAllocatorWrapper { ... }).precise().slice();
///
/// This library allows every allocator to declare their individual-allocation storage
/// requirements through a custom "Block" type. The Block type can store any data the allocator
/// wants to associate with individual allocations. It could be just a pointer, or
/// just a slice, or a struct with many fields.
///
/// Using alloctor-defined Block types allows the caller to determine where the Block
/// should be stored and who owns it.  This increases the composibility of allocators
/// as it allows the storage of these blocks to be part of a composable interface.
/// This allows storage for multiple composed allocators to be combined and stored
/// anywhere.
///
/// Most of the allocators in this library can be described as "BlockAllocators", meaning,
/// an allocator that returns and accepts a custom Block type. For applications that want
/// to speak in "slices", the "SliceAllocator" will take any BlockAllocator, and create
/// a slice-based API around it. The SliceAllocator will either function as a straight
/// passthrough to the underlying BlockAllocator, or pad each allocation to store the
/// extra data required for each Block.
///
/// Implementing an Allocator
/// ======================================================================================
/// Every Allocator MUST define a pub struct type named 'Block'.
/// Check the MakeBlockType function for notes on creating a Block type.
/// Blocks are normally passed by value to the allocator, unless the allocator
/// is going to modify it (i.e. extendBlockInPlace).
/// The caller will access the memory pointer for a block by calling its `ptr()` function.
/// The pointer can have an "align(X)" property to indicate all allocations from will be
/// aligned by X.
///
/// ### Allocation:
///
///     1. fn alignForward(len: usize) usize
///        Returns the next smallest valid length that is >= `len`.  This function
///        allows a caller to know how big its allocation will be before calling allocBlock.
///        It must be a pure static function on the allocator type.
///        Length values must be aligned if an only if the allocator implements this function.
///        It would be common for a page allocator to implement this.
///        NOTE: if I find an allocator that cannot determine this with a pure static function,
///              then I'll need to implement something like allocMinBlock below
///
///     2. allocBlock(len: usize) error{OutOfMemory}!Block
///        assert(len > 0);
///        assert(len == alignForward(len)); // if alignForward is implemented
///        Allocate a block of `len` bytes. If the allocator implements `alignForward`,
///        then `len` must have already been aligned by it.
///        Note that the block itself may take more memory than `len` bytes, however,
///        its len() function will return the requested `len` number of bytes (if it has
///        a len() function).
///
///     3. ??? IDEA: allocMinBlock(len: *usize) error{OutOfMemory}!Block ????
///        There may be allocators that will allocate even more memory even with an aligned length, and this
///        length cannot be determined until it's time to perform the allocation. If I come up with an allocator
///        that does this then I might add this function to the allocator interface. Note that if the block
///        implements len(), then it's value would have to match the len value returned in `len`.
///
/// ### Alignment
///
///     * allocOverAlignedBlock(lenRef: *usize, alignment: u29) error{OutOfMemory}!Block
///       assert(lenRef.* > 0);
///       assert(isValidAlign(alignment));
///       assert(alignment > Block.alignment);
///       The "Over" part of "OverAligned" means `alignment` > `Block.alignment`.  The returned block.ptr() will be
///       aligned to the given `alignment`.
///       lenRef should point to the length that the caller requires.  It can be any value > 0, it does not need
///       to be aligned by `alignForward`. The allocator will return the full length available at the returned block.ptr()
///       address through `lenRef`, which will be >= the value that was passed in.
///       If the block is larger than requested, the caller can attempt to retract the block if they know they
///       won't need the extra memory. Note that this is an option purposely left to the caller (see Single Responsibility
///       Principle).
///       NOTE: so far the only allocator that I know of that should implement this is the AlignAllocator and any wrapping allocators.
///
///     * allocPreciseOverAlignedBlock(len: usize, alignment: u29) error{OutOfMemory}!Block
///       assert(len > 0);
///       assert(isValidAlign(alignment));
///       assert(alignment > Block.alignment);
///       Same as allocOverAlignedBlock except that block.len() will equal the initial value of `lenRef.*`.
///
/// ### Deallocation:
///
///     * deallocBlock(block: Block) void
///       Cannot fail. block must be identical to a block returned by alloc and has maintained any
///       modifications made to it through other allocator functions.
///
///     * deallocAll() void
///       Cannot fail. Deallocates every block in the allocator, but the allocator can still be used.
///
///     * deinitAndDeallocAll() void
///       Cannot fail. Deallocates every block AND deinitializes the allocator so it can no longer be used.
///
/// ### Resizing
///
///     extend and retract are separate functions so that an allocator can indicate at
///     compile-time which ones it supports.
///
///     * extendBlockInPlace(block: *Block, newLen: usize) error{OutOfMemory}!void
///       assert(newLen > block.len());
///       assert(newLen == alignForward(newLen)); // if alignForward is implemented
///       Extend a block without moving it.
///       If the allocator implements alignForward, then `newLen` must be aligned by it.
///       Note that block is passed in by reference because the function can modify it.  If it is
///       modified, the caller must pass in the new version for all future calls.
///
///     * retractBlockInPlace(block: *Block, newLen: usize) error{OutOfMemory}!void
///       assert(newLen > 0);
///       assert(newLen < block.len());
///       assert(newLen == alignForward(newLen)); // if alignForward is implemented
///       Retract a block without moving it.
///       Note that retract is equivalent to shrink except that it can fail and will fail if the
///       memory cannot be retracted.  If you just want to make a "best effort" to retract memory,
///       and want the allocator to start tracking the shrunken length, then use shrinkBlockInPlace.
///       Note that block is passed in by reference because the function can modify it.  If it is
///       modified, the caller must pass in the new version for all future calls.
///
///     * shrinkBlockInPlace(block: *Block, newLen: usize) void
///       assert(newLen > 0);
///       assert(newLen < block.len());
///       Shrink a block without moving it.
///       Unlink restrictBlockInPlace, this method cannot fail. After calling this, block.len() will
///       be set to `newLen`. The allocator may or may not be able to use the released space.
///       Most allocators will not implement this as it typically requires extra space to store
///       any discrepancy between the caller length and the underlying allocator's length.  Wrap any
///       allocator with ".precise()" to support this.
///
///     * TODO: might want to add a method to extend both left and right? expand?
///
/// ### Ownership? (How helpful is this?)
///
///     * IDEA: ownsBlock(block: Block) bool
///       Means the allocator can tell if it owns a block.
///
/// ### ??? Next Block Pointer ???
///
///     * IDEA: nextBlockPtr() [*]u8
///       An allocator could implement this if it's next block pointer is pre-determined.
///       A containing alignment allocator may want to know this to adjust what they need to request for an aligned block.
///     * IDEA: nextBlockPtrWithLen(len: usize) [*]u8
///       Maybe this would be a helpful option as well?
///
/// ### Realloc
///
///     These functions should only be implemented by the CAllocator and wrapping allocators.
///     They can only be called on "precise" allocators.
///
///     * cReallocBlock(block: *Block, currentLen: usize, newLen: usize) error{OutOfMemory}!void
///     * cReallocAlignedBlock(block: *Block, currentLen: usize, newLen: usize, currentAlign: u29, minAlign: u29) error{OutOfMemory}!void
///       assert(currentLen == block.len()) // if block.hasLen is true
///       assert(newLen > 0);
///       assert(newLen == alignForward(newLen)); // if alignForward is implemented
///       assert(currentLen != newLen);
///       assert(isValidAlign(currentAlign));
///       assert(mem.isAligned(@ptrToInt(block.ptr()), currentAlign));
///       assert(isValidAlign(minAlign));
///       assert(minAlign <= currentAlign);
///       This function is equivalent to C's realloc.
///       This should only be implemented by CAllocator, AlignAllocator and forwarded by "wrapping allocators".
///       The `reallocAlignedBlock` function in this module will implement the `realloc` operation for
///       every allocator using a combination of other operations.  The C allocator is special because
///       it does not support enough operations to support realloc, so we call its realloc function directly.
///       The currentAlign value should be the alignment requested when the block was allocated. `minAlign`
///       must be <= to currentAlign, and indicates what alignment must be maintained if the memory is moved.
///
///
/// ### Why does PreciseAllocator wrap AlignAllocator instead of the other way around?
/// --------------------------------------------------------------------------------
/// It's to support allocations that are both "precise" and "over-aligned".  The AlignAllocator needs to
/// be able to change the length of the allocation to get an aligned address.  Once the allocator becomes
/// precise, we've lost the ability to change the length unless we add extra storage to the Block. By
/// always keeping the AlignAllocator underneath the PreciseAllocator, it's free to change the length
/// of the allocation without having to store the discrepancy.
///
/// For now I enforce this ordering with the isPreciseWrapped bool. Note that ".align()" can wrapp allocators
/// that can perform "precise allocations" (i.e. .bumpDown(1)), however, it cannot specifically wrap ".precise()".
///
/// ================================================================================
/// TODO: Should I remove all the asserts inside the function bodies and create an AssertAllocator?
/// ================================================================================
///
const std = @import("std");
const mem = std.mem;
const os = std.os;
const assert = std.debug.assert;

const testing = std.testing;

/// Make an allocator from a chain of method calls.
/// NOTE: this struct is empty, it does not take up any runtime space
pub const Alloc = struct {
    //
    // TODO: should I put all these in this struct, or should they just be global symbols?
    //
    pub const fail = MakeBlockAllocator(FailAllocator) { .init = FailAllocator { } };

    pub usingnamespace if (std.builtin.link_libc) struct {
        pub const c = MakeBlockAllocator(CAllocator)    { .init = CAllocator { } };
    } else struct { };

    pub usingnamespace if (std.Target.current.os.tag == .windows) struct {
        pub const windowsGlobalHeap = MakeBlockAllocator(WindowsGlobalHeapAllocator) { .init = WindowsGlobalHeapAllocator { } };
        pub fn windowsHeap(handle: std.os.windows.HANDLE) MakeBlockAllocator(WindowsHeapAllocator) {
            return MakeBlockAllocator(WindowsHeapAllocator) { .init = WindowsHeapAllocator.init(handle) };
        }
    } else struct {
        pub const mmap = MakeBlockAllocator(MmapAllocator) { .init = MmapAllocator { } };
    };

    pub fn bumpDown(comptime alignment: u29, buf: []u8) MakeBlockAllocator(BumpDownAllocator(alignment)) {
        return .{ .init = makeBumpDownAllocator(alignment, buf) };
    }

    // Support method call syntax to add custom allocators.
    pub fn custom(allocator: var) MakeBlockAllocator(@TypeOf(allocator)) {
        return .{ .init = allocator };
    }
};
pub fn MakeBlockAllocator(comptime T: type) type {return struct {
    init: T,

    ///
    /// `precise` wraps another allocator.  It adds an extra length field to each block. This extra field enables
    /// allocations of any size (aka "precise allocations") and also enables the "shrinkBockInPlace" operation.
    ///
    /// `precise` should never be wrapped by `aligned`, rather, it should always be the one wrapping `aligned`
    /// (see "Why does PreciseAllocator wrap AlignAllocator instead of the other way around?").
    ///
    pub fn precise(self: @This()) MakeBlockAllocator(PreciseAllocator(T)) {
        return .{ .init = makePreciseAllocator(self.init) };
    }

    pub fn aligned(self: @This()) MakeBlockAllocator(AlignAllocator(T)) {
        return .{ .init = makeAlignAllocator(self.init) };
    }
    pub fn log(self: @This()) MakeBlockAllocator(LogAllocator(T)) {
        return .{ .init = makeLogAllocator(self.init) };
    }
    // TODO: sliceForceStore? or shrinkableSlice?
    pub fn slice(self: @This()) MakeSliceAllocator(SliceAllocator(T)) {
        return .{ .init = makeSliceAllocator(self.init) };
    }

    // TODO: can't get this to work yet
    // Support method call syntax to add custom allocators.
    //pub fn custom(self: @This(), wrapperTypeFunc: var) MakeBlockAllocator(@typeInfo(@TypeOf(wrapperTypeFunc)).Fn.return_type.?) {
    //    @compileLog(@TypeOf(wrapperTypeFunc));
    //    return .{ .init = @call(.{}, @typeInfo(@TypeOf(wrapperTypeFunc)).Fn.return_type.?, .{self} ) };
    //}
};}
pub fn MakeSliceAllocator(comptime T: type) type {return struct {
    init: T,
    // TODO: will create some slice wrappers like logging, locking/threadsafe, etc.
};}

test "FailAllocator" {
    testBlockAllocator(&Alloc.fail.init);
    testBlockAllocator(&Alloc.fail.log().init);
    testSliceAllocator(&Alloc.fail.slice().init);
    testSliceAllocator(&Alloc.fail.log().slice().init);

    // test that '.custom' syntax works
    _ = &Alloc.custom(FailAllocator{ }).init;
    // TODO: can't get custom allocator wrappers to work yet
    //_ = &Alloc.fail.custom(LogAllocator).init;
}
test "CAllocator" {
    if (!std.builtin.link_libc) return;
    testBlockAllocator(&Alloc.c.init);
    testBlockAllocator(&Alloc.c.aligned().init);
    testBlockAllocator(&Alloc.c.precise().init);
    testBlockAllocator(&Alloc.c.aligned().precise().init);
    testSliceAllocator(&Alloc.c.slice().init);
    testSliceAllocator(&Alloc.c.aligned().slice().init);
    testSliceAllocator(&Alloc.c.precise().slice().init);
    testSliceAllocator(&Alloc.c.aligned().precise().slice().init);
}
test "WindowsHeapAllocator" {
    if (std.Target.current.os.tag != .windows) return;
    testBlockAllocator(&Alloc.windowsGlobalHeap.init);
    testBlockAllocator(&Alloc.windowsGlobalHeap.aligned().init);
    testBlockAllocator(&Alloc.windowsGlobalHeap.aligned().precise().init);
    testSliceAllocator(&Alloc.windowsGlobalHeap.slice().init);
    testSliceAllocator(&Alloc.windowsGlobalHeap.aligned().slice().init);
    testSliceAllocator(&Alloc.windowsGlobalHeap.aligned().precise().slice().init);
    // TODO: test private heaps with HeapAlloc
    //{
    //    var a = Alloc.windowsHeap(HeapAlloc(...)).init;
    //    defer a.deinitAndDeallocAll();
    //    testBlockAllocator(&a);
    //    ...
    //}
}

test "MmapAllocator" {
    if (std.Target.current.os.tag == .windows) return;
    testBlockAllocator(&Alloc.mmap.init);
    testBlockAllocator(&Alloc.mmap.aligned().init);
    testBlockAllocator(&Alloc.mmap.aligned().precise().init);
    testSliceAllocator(&Alloc.mmap.precise().slice().init);
    testSliceAllocator(&Alloc.mmap.aligned().precise().slice().init);
}
test "BumpDownAllocator" {
    var buf: [500]u8 = undefined;
    inline for ([_]u29 {1, 2, 4, 8, 16, 32, 64}) |alignment| {
        testBlockAllocator(&Alloc.bumpDown(alignment, &buf).init);
        testBlockAllocator(&Alloc.bumpDown(alignment, &buf).aligned().init);
        if (comptime alignment == 1) {
            testSliceAllocator(&Alloc.bumpDown(alignment, &buf).slice().init);
            testSliceAllocator(&Alloc.bumpDown(alignment, &buf).aligned().slice().init);
        } else {
            testBlockAllocator(&Alloc.bumpDown(alignment, &buf).precise().init);
            testBlockAllocator(&Alloc.bumpDown(alignment, &buf).aligned().precise().init);
            testSliceAllocator(&Alloc.bumpDown(alignment, &buf).precise().slice().init);
            testSliceAllocator(&Alloc.bumpDown(alignment, &buf).aligned().precise().slice().init);
        }
    }
}

/// Create a Block type from the given block Data type.
/// The Data type must include:
///     pub const hasLen    = true|false;
///     pub const alignment = AN_ALIGNMENT_INTEGER;
///
///     // It must implement or disable initBuf
///         pub const initBuf = void;
///     // OR
///         pub fn initBuf(p: [*]align(alignment) u8) Self;
//      // OR if hasLen is true
///         pub fn initBuf(p: []align(alignment) u8) Self;
///     // initBuf should exist if and only if the pointer/slice is the only data in the Block type
///
///     // returns a pointer to the memory owned by the block
///     pub fn ptr(self: @This()) [*]align(alignment) u8 { ... }
///     // if hasLen is true, a function to return the length of the memory owned by the block
///     // and a function to return the memory owned by the block as a slice
///     pub fn len(self: @This()) usize { ... }
///     pub fn setLen(self: *@This(), newLen: usize) void { ... }
///
pub fn MakeBlockType(comptime Data: type) type {
    if (!isValidAlign(Data.alignment)) @compileError("invalid alignment");
    return struct {
        const Self = @This();

        pub const hasLen = Data.hasLen;
        pub const alignment = Data.alignment;
        data: Data,

        pub fn init(data: Data) Self { return .{ .data = data }; }

        pub usingnamespace if (!implements(Data, "initBuf")) struct {
            pub const initBuf = void;
        } else struct {
            const Buf = if (hasLen) []align(alignment) u8 else [*]align(alignment) u8;
            pub fn initBuf(buf: Buf) Self { return .{ .data = Data.initBuf(buf) }; }
        };
        pub fn ptr(self: Self) [*]align(alignment) u8 { return self.data.ptr(); }

        pub usingnamespace if (!hasLen) struct { } else struct {
            pub fn len(self: Self) usize { return self.data.len(); }
            pub fn setLen(self: *Self, newLen: usize) void { self.data.setLen(newLen); }
        };
    };
}


/// Creates a simple block type that stores a pointer or a slice and a struct of any extra data.
pub fn MakeSimpleBlockType(
    /// true if the Block tracks slices rather than just pointers.
    comptime hasLen_: bool,
    /// guaranteed alignment for all blocks from the allocator. Must be a power
    /// of 2 that is also >= 1.
    comptime alignment_: u29,
    /// extra data that each block must maintain.
    comptime Extra: type
) type {
    const Buf = if (hasLen_) [] align(alignment_) u8
                else         [*]align(alignment_) u8;
    const Data = struct {
        const Self = @This();

        pub const hasLen = hasLen_;
        pub const alignment = alignment_;

        buf: Buf,
        extra: Extra,

        pub usingnamespace if (@sizeOf(Extra) > 0) struct {
            pub const initBuf = void;
        } else struct {
            pub fn initBuf(buf: Buf) Self { return .{ .buf = buf, .extra = .{} }; }
        };

        pub usingnamespace if (!hasLen) struct {
            pub fn ptr(self: Self) [*]align(alignment) u8 { return self.buf; }
        } else struct {
            pub fn ptr(self: Self) [*]align(alignment) u8 { return self.buf.ptr; }
            pub fn len(self: Self) usize { return self.buf.len; }
            pub fn setLen(self: *Self, newLen: usize) void { self.buf.len = newLen; }
        };
    };
    return MakeBlockType(Data);
}

/// An allocator that always fails.
pub const FailAllocator = struct {
    pub const Block = MakeSimpleBlockType(true, 1, struct {});
    pub fn init(_: struct{}) FailAllocator { return .{}; }

    pub const alignForward = void;
    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        assert(len > 0);
        return error.OutOfMemory;
    }
    pub fn allocOverAlignedBlock(self: @This(), lenRef: *usize, alignment: u29) error{OutOfMemory}!Block {
        assert(lenRef.* > 0);
        assert(isValidAlign(alignment));
        assert(alignment > Block.alignment);
        return error.OutOfMemory;
    }
    pub fn allocPreciseOverAlignedBlock(self: @This(), len: usize, alignment: u29) error{OutOfMemory}!Block {
        assert(len > 0);
        assert(isValidAlign(alignment));
        assert(alignment > Block.alignment);
        return error.OutOfMemory;
    }
    pub const deallocBlock = void;
    pub const deallocAll = void;
    pub const deinitAndDeallocAll = void;
    pub const extendBlockInPlace = void;
    pub const retractBlockInPlace = void;
    pub const shrinkBlockInPlace = void;
    pub const cReallocBlock = void;
    pub const cReallocAlignedBlock = void;
    pub const isPreciseWrapped = false;
};

pub const CAllocator = struct {
    pub const Block = MakeSimpleBlockType(false, 1, struct {});

    pub const alignForward = void;
    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        assert(len > 0);
        const ptr = std.c.malloc(len) orelse return error.OutOfMemory;
        return Block.initBuf(@ptrCast([*]u8, ptr));
    }
    pub const allocOverAlignedBlock = void;
    pub const allocPreciseOverAlignedBlock = void;
    pub fn deallocBlock(self: @This(), block: Block) void {
        std.c.free(block.ptr());
    }
    pub const deallocAll = void;
    pub const deinitAndDeallocAll = void;
    pub const extendBlockInPlace = void;
    pub const retractBlockInPlace = void;
    pub const shrinkBlockInPlace = void;
    pub fn cReallocBlock(self: @This(), block: *Block, newLen: usize) error{OutOfMemory}!void {
        assert(newLen > 0);
        const ptr = std.c.realloc(block.ptr(), newLen)
            orelse return error.OutOfMemory;
        block.* = Block.initBuf(@ptrCast([*]u8, ptr));
    }
    pub const cReallocAlignedBlock = void;
    pub const isPreciseWrapped = false;
};

pub const MmapAllocator = struct {
    pub const Block = MakeSimpleBlockType(true, mem.page_size, struct {});

    pub fn alignForward(len: usize) usize {
        return mem.alignForward(len, mem.page_size);
    }
    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        assert(len == alignForward(len));
        const result = os.mmap(
            null,
            len,
            os.PROT_READ | os.PROT_WRITE,
            os.MAP_PRIVATE | os.MAP_ANONYMOUS,
            -1, 0) catch return error.OutOfMemory;
        return Block.initBuf(@alignCast(mem.page_size, result.ptr)[0..len]);
    }
    pub const allocOverAlignedBlock = void;
    pub const allocPreciseOverAlignedBlock = void;
    pub fn deallocBlock(self: @This(), block: Block) void {
        os.munmap(block.data.buf);
    }
    pub const deallocAll = void;
    pub const deinitAndDeallocAll = void;

    // TODO: move this to std/os/linux.zig
    pub usingnamespace if (std.Target.current.os.tag != .linux) struct { } else struct {
        pub fn sys_mremap(old_address: [*]align(mem.page_size) u8, old_size: usize, new_size: usize, flags: usize) usize {
            return os.linux.syscall4(.mremap, @ptrToInt(old_address), old_size, new_size, flags);
        }
    };
    fn mremap(buf: []align(mem.page_size) u8, newLen: usize, flags: usize) ![*]u8 {
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        // TEMPORARY HACK
        // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
        if (std.Target.current.os.tag != .linux) return error.OutOfMemory;
        const rc = sys_mremap(buf.ptr, buf.len, newLen, flags);
        switch (os.linux.getErrno(rc)) {
            0 => return @intToPtr([*]u8, rc),
            os.EAGAIN => return error.LockedMemoryLimitExceeded,
            os.EFAULT => return error.Fault,
            os.EINVAL => unreachable,
            os.ENOMEM => return error.OutOfMemory,
            else => |err| return os.unexpectedErrno(err),
        }
    }


    pub fn mremapInPlace(block: *Block, newLen: usize) error{OutOfMemory}!void {
        const result = mremap(block.data.buf, newLen, 0) catch return error.OutOfMemory;
        assert(result == block.ptr());
        block.data.buf.len = newLen;
    }
    pub fn extendBlockInPlace(self: @This(), block: *Block, newLen: usize) error{OutOfMemory}!void {
        assert(newLen > block.len());
        assert(newLen == alignForward(newLen));
        return mremapInPlace(block, newLen);
    }
    pub fn retractBlockInPlace(self: @This(), block: *Block, newLen: usize) error{OutOfMemory}!void {
        assert(newLen > 0);
        assert(newLen < block.len());
        assert(newLen == alignForward(newLen));
        return mremapInPlace(block, newLen);
    }
    pub const shrinkBlockInPlace = void;
    pub const cReallocBlock = void;
    pub const cReallocAlignedBlock = void;
    pub const isPreciseWrapped = false;
};

/// Simple Fast allocator. Tradeoff is that it can only re-use blocks if they are deallocated
/// in LIFO stack order.
///
/// The Up/Down detail is exposed because they have different behavior.
/// The BumpDownAllocator means that in-place extend/retract is much more limited than
/// an BumpUpAllocator which is only limited by the amount of memory it has.
///
/// I'm not sure what the advantage of a DownwasBumpAllocator is, maybe it is more efficient?
///     see https://fitzgeraldnick.com/2019/11/01/always-bump-downwards.html
///
/// TODO: would it be worth it to create alignForward/alignBackward functions with a comptime alignment?
pub fn makeBumpDownAllocator(comptime alignment: u29, buf: []u8) BumpDownAllocator(alignment) {
    return BumpDownAllocator(alignment).init(buf);
}
pub fn BumpDownAllocator(comptime alignment : u29) type {return struct {
    const Self = @This();
    pub const Block = MakeSimpleBlockType(true, alignment, struct {});

    buf: []u8,
    bumpIndex: usize, // MUST ALWAYS be aligned
    pub fn init(buf: []u8) @This() {
        return .{ .buf = buf, .bumpIndex = getStartBumpIndex(buf) };
    }
    // We must ensure bumpIndex is aligned when it is initialized
    fn getStartBumpIndex(buf: []u8) usize {
        const endAddr = @ptrToInt(buf.ptr) + buf.len;
        const alignedEndAddr = mem.alignBackward(endAddr, alignment);
        if (alignedEndAddr < @ptrToInt(buf.ptr)) return 0;
        return alignedEndAddr - @ptrToInt(buf.ptr);
    }
    fn getBlockIndex(self: @This(), block: Block) usize {
        assert(@ptrToInt(block.ptr()) >= @ptrToInt(self.buf.ptr));
        return @ptrToInt(block.ptr()) - @ptrToInt(self.buf.ptr);
    }


    fn commonAllocBlock(self: *Self, len: usize) error{OutOfMemory}!Block {
        if (len > self.bumpIndex)
            return error.OutOfMemory;
        const bufIndex = self.bumpIndex - len;
        self.bumpIndex = bufIndex;
        return Block.initBuf(@alignCast(alignment, self.buf[bufIndex..bufIndex+len]));
    }
    pub usingnamespace if (alignment == 1) struct {
        pub const alignForward = void;
        pub fn allocBlock(self: *Self, len: usize) error{OutOfMemory}!Block {
            assert(len > 0);
            return self.commonAllocBlock(len);
        }
    } else struct {
        pub fn alignForward(len: usize) usize {
            assert(len > 0);
            return mem.alignForward(len, alignment);
        }
        pub fn allocBlock(self: *Self, len: usize) error{OutOfMemory}!Block {
            assert(len == alignForward(len));
            return self.commonAllocBlock(len);
        }
    };
    pub const allocOverAlignedBlock = void;
    pub const allocPreciseOverAlignedBlock = void;
    pub fn deallocBlock(self: *@This(), block: Block) void {
        if (self.bumpIndex == self.getBlockIndex(block)) {
            self.bumpIndex += mem.alignForward(block.len(), alignment);
        }
    }
    pub fn deallocAll(self: *@This()) void {
        self.bumpIndex = getStartBumpIndex(self.buf);
    }
    pub const deinitAndDeallocAll = void;
    /// BumpDown cannot extend/retract blocks, but BumpUp could extend/retract the last one
    pub const extendBlockInPlace = void;
    pub const retractBlockInPlace = void;
    pub const shrinkBlockInPlace = void;
    pub const cReallocBlock = void;
    pub const cReallocAlignedBlock = void;
    pub const isPreciseWrapped = false;
};}

// The windows heap provided by kernel32
pub const WindowsHeapAllocator = struct {
    // TODO: can we assume HeapAlloc will always have a certain alignment?
    pub const Block = MakeSimpleBlockType(false, 1, struct {});

    handle: os.windows.HANDLE,

    pub fn init(handle: os.windows.HANDLE) @This() {
        return @This() { .handle = handle };
    }

    /// Type-specific function to be able to pass in windows-specific flags
    pub fn heapAlloc(self: @This(), len: usize, flags: u32) error{OutOfMemory}!Block {
        const result = os.windows.kernel32.HeapAlloc(self.handle, flags, len) orelse return error.OutOfMemory;
        return Block.initBuf(@ptrCast([*]u8, result));
    }
    /// Type-specific function to be able to pass in windows-specific flags
    pub fn heapFree(self: @This(), block: Block, flags: u32) void {
        os.windows.HeapFree(self.handle, flags, block.ptr());
    }
    const HEAP_REALLOC_IN_PLACE_ONLY : u32 = 0x00000010; // TODO: move this to os.windows
    /// Type-specific function to be able to pass in windows-specific flags
    fn heapReAlloc(self: @This(), block: *Block, newLen: usize, flags: u32) error{OutOfMemory}!void {
        const result = os.windows.kernel32.HeapReAlloc(self.handle,
            flags | HEAP_REALLOC_IN_PLACE_ONLY, block.ptr(), newLen) orelse return error.OutOfMemory;
        assert(@ptrToInt(result) == @ptrToInt(block.ptr()));
    }

    pub const alignForward = void;
    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        // TODO: use HEAP_NO_SERIALIZE flag if we are single-threaded?
        return self.heapAlloc(len, 0);
    }
    pub const allocOverAlignedBlock = void;
    pub const allocPreciseOverAlignedBlock = void;
    pub fn deallocBlock(self: @This(), block: Block) void {
        // TODO: use HEAP_NO_SERIALIZE flag if we are single-threaded?
        return self.heapFree(block, 0);
    }
    pub const deallocAll = void;
    /// WARNING: if this is the global process heap, you probably don't want to destroy it
    pub fn deinitAndDeallocAll(self: @This()) void {
        os.windows.HeapDestroy(self.handle);
    }
    pub fn extendBlockInPlace(self: @This(), block: *Block, newLen: usize) error{OutOfMemory}!void {
        // TODO: use HEAP_NO_SERIALIZE flag if we are single-threaded?
        return self.heapReAlloc(block, newLen, 0);
    }
    pub fn retractBlockInPlace(self: @This(), block: *Block, newLen: usize) error{OutOfMemory}!void {
        // TODO: use HEAP_NO_SERIALIZE flag if we are single-threaded?
        return self.heapReAlloc(block, newLen, 0);
    }
    pub const shrinkBlockInPlace = void;
    pub const cReallocBlock = void;
    pub const cReallocAlignedBlock = void;
    pub const isPreciseWrapped = false;
};

pub fn getProcessHeapWindows() !os.windows.HANDLE {
    return os.windows.kernel32.GetProcessHeap() orelse switch (os.windows.kernel32.GetLastError()) {
        else => |err| return os.windows.unexpectedError(err),
    };
}

/// Global version of WindowsHeapAllocator that doesn't require runtime initialization.
pub const WindowsGlobalHeapAllocator = struct {
    pub const Block = WindowsHeapAllocator.Block;

    pub fn getInstance() WindowsHeapAllocator {
        return WindowsHeapAllocator.init(getProcessHeapWindows() catch unreachable);
    }
    pub const alignForward = void;
    pub fn allocBlock(self: @This(), len: usize) error{OutOfMemory}!Block {
        return try getInstance().allocBlock(len);
    }
    pub const allocOverAlignedBlock = void;
    pub const allocPreciseOverAlignedBlock = void;
    pub fn deallocBlock(self: @This(), block: Block) void {
        getInstance().deallocBlock(block);
    }
    pub const deallocAll = void;

    /// deinitAndDeallocAll disabled because normally you don't want to destroy the global process
    /// heap. Note that ther user could still call this via: getInstance().deinitAndDeallocAll()
    pub const deinitAndDeallocAll = void;

    pub fn extendBlockInPlace(self: @This(), block: *Block, newLen: usize) error{OutOfMemory}!void {
        return try getInstance().extendBlockInPlace(block, newLen);
    }
    pub fn retractBlockInPlace(self: @This(), block: *Block, newLen: usize) error{OutOfMemory}!void {
        return try getInstance().retractBlockInPlace(block, newLen);
    }
    pub const shrinkBlockInPlace = void;
    pub const cReallocBlock = void;
    pub const cReallocAlignedBlock = void;
    pub const isPreciseWrapped = false;
};

// TODO: make SlabAllocator?
// TODO: make a SanityAllocator that saves all the blocks and ensures every call passes in valid blocks.
// TODO: make a LockingAllocator/ThreadSafeAllocator that can wrap any other allocator?

/// Equivalent to C's realloc. All allocators will share a common implementation of this except
/// for the C allocator which has its own implementation.
///
/// This function isn't designed very well, it's purposely designed to behave like C's realloc.
/// currentLen MUST be the exact length of the given block.  It is passed in because not all blocks
/// support block.len(). We could support currentLen being less than block.len(), but that's not how
/// C's realloc behaves, we can create another function if we want that behavior.
///
/// This function is only supported for "precise" allocators.
///
pub fn reallocAlignedBlock(allocator: var, block: *@TypeOf(allocator.*).Block, currentLen: usize, newLen: usize, currentAlign: u29, minAlign: u29) error{OutOfMemory}!void {
    const T = @TypeOf(allocator.*);
    if (comptime implements(T, "alignForward"))
        @compileError("reallocAlignedBlock cannot be called on '" ++ @typeName(T) ++ "' because it is not precise.");
    if (!comptime implements(T, "allocPreciseOverAlignedBlock"))
        @compileError("reallocAlignedBlock cannot be called on '" ++ @typeName(T) ++ "' because it is not aligned.");

    if (T.Block.hasLen) assert(currentLen == block.len());
    assert(newLen > 0);
    assert(currentLen != newLen);
    assert(isValidAlign(currentAlign));
    assert(mem.isAligned(@ptrToInt(block.ptr()), currentAlign));
    assert(isValidAlign(minAlign));
    assert(minAlign <= currentAlign);

    if (comptime implements(T, "cReallocAlignedBlock"))
        return try allocator.cReallocAlignedBlock(block, currentLen, newLen, currentAlign, minAlign);
    if (comptime implements(T, "cReallocBlock"))
        @compileError(@typeName(T) ++ " implmeents cReallocBlock but not cReallocAlignedBlock, wrap it with .aligned()");

    // first try resizing in place to avoid having to copy the data and potentially re-align
    if (newLen > currentLen) {
        if (comptime implements(T, "extendBlockInPlace")) {
            if (allocator.extendBlockInPlace(block, newLen)) |_| {
                return;
            } else |_| { }
        }
    } else { // newLen < block.len()
        if (comptime implements(T, "retractBlockInPlace")) {
            if (allocator.retractBlockInPlace(block, newLen)) |_| {
                return;
            } else |_| { }
        }
    }

    // TODO: try expanding the block in both directions, will require a copy but should
    //       be better on the cache and cause less fragmentation

    // fallback to creating a new block and copying the data
    const newBlock = if (minAlign <= T.Block.alignment)
        try allocator.allocBlock(newLen) else try allocator.allocPreciseOverAlignedBlock(newLen, minAlign);
    assert(mem.isAligned(@ptrToInt(newBlock.ptr()), minAlign));
    @memcpy(newBlock.ptr(), block.ptr(), std.math.min(block.len(), newLen));
    deallocBlockIfSupported(allocator, block.*);
    block.* = newBlock;
}

pub fn makeLogAllocator(allocator: var) LogAllocator(@TypeOf(allocator)) {
    return LogAllocator(@TypeOf(allocator)) { .allocator = allocator };
}
// TODO: log to an output stream rather than directly to stderr
pub fn LogAllocator(comptime T: type) type {
    return struct {
        const SelfRef = if (@sizeOf(T) == 0) @This() else *@This();
        pub const Block = T.Block;
        allocator: T,
        pub const alignForward = T.alignForward;
        pub usingnamespace if (!implements(T, "allocBlock")) struct {
            pub const allocBlock = void;
        } else struct {
            pub fn allocBlock(self: SelfRef, len: usize) error{OutOfMemory}!Block {
                std.debug.warn("{}: allocBlock len={}\n", .{@typeName(T), len});
                const result = try self.allocator.allocBlock(len);
                std.debug.warn("{}: allocBlock returning {}\n", .{@typeName(T), result.ptr()});
                return result;
            }
        };
        pub usingnamespace if (!implements(T, "allocOverAlignedBlock")) struct {
            pub const allocOverAlignedBlock = void;
        } else struct {
            pub fn allocOverAlignedBlock(self: SelfRef, lenRef: *usize, allocAlign: u29) error{OutOfMemory}!Block {
                std.debug.warn("{}: allocOverAlignedBlock len={} align={}\n", .{@typeName(T), lenRef.*, allocAlign});
                const result = try self.allocator.allocOverAlignedBlock(lenRef, allocAlign);
                std.debug.warn("{}: allocOverAlignedBlock returning {}:{}\n", .{@typeName(T), result.ptr(), lenRef.*});
                return result;
            }
        };
        pub usingnamespace if (!implements(T, "allocPreciseOverAlignedBlock")) struct {
            pub const allocPreciseOverAlignedBlock = void;
        } else struct {
            pub fn allocPreciseOverAlignedBlock(self: SelfRef, len: usize, allocAlign: u29) error{OutOfMemory}!Block {
                std.debug.warn("{}: allocPreciseOverAlignedBlock len={} align={}\n", .{@typeName(T), len, allocAlign});
                const result = try self.allocator.allocPreciseOverAlignedBlock(len, allocAlign);
                std.debug.warn("{}: allocPreciseOverAlignedBlock returning {}\n", .{@typeName(T), result.ptr()});
                return result;
            }
        };

        pub usingnamespace if (!implements(T, "deallocBlock")) struct {
            pub const deallocBlock = void;
        } else struct {
            pub fn deallocBlock(self: SelfRef, block: Block) void {
                if (comptime Block.hasLen) {
                    std.debug.warn("{}: deallocBlock ptr={} len={}\n", .{@typeName(T), block.ptr(), block.len()});
                } else {
                    std.debug.warn("{}: deallocBlock ptr={}\n", .{@typeName(T), block.ptr()});
                }
                return self.allocator.deallocBlock(block);
            }
        };
        pub usingnamespace if (!implements(T, "deallocAll")) struct {
            pub const deallocAll = void;
        } else struct {
            pub fn deallocAll(self: SelfRef) void {
                std.debug.warn("{}: deallocAll\n", .{@typeName(T)});
                return self.allocator.deallocAll();
            }
        };
        pub usingnamespace if (!implements(T, "deinitAndDeallocAll")) struct {
            pub const deinitAndDeallocAll = void;
        } else struct {
            pub fn deinitAndDeallocAll(self: SelfRef) void {
                std.debug.warn("{}: deinitAndDeallocAll\n", .{});
                return self.allocator.deinitAndDeallocAll();
            }
        };
        pub usingnamespace if (!implements(T, "extendBlockInPlace")) struct {
            pub const extendBlockInPlace = void;
        } else struct {
            pub fn extendBlockInPlace(self: SelfRef, block: *Block, newLen: usize) error{OutOfMemory}!void {
                if (comptime Block.hasLen) {
                    std.debug.warn("{}: extendBlockInPlace {}:{} newLen={}\n", .{@typeName(T), block.ptr(), block.len(), newLen});
                } else {
                    std.debug.warn("{}: extendBlockInPlace {} newLen={}\n", .{@typeName(T), block.ptr(), newLen});
                }
                return try self.allocator.extendBlockInPlace(block, newLen);
            }
        };
        pub usingnamespace if (!implements(T, "retractBlockInPlace")) struct {
            pub const retractBlockInPlace = void;
        } else struct {
            pub fn retractBlockInPlace(self: SelfRef, block: *Block, newLen: usize) error{OutOfMemory}!void {
                if (comptime Block.hasLen) {
                    std.debug.warn("{}: retractBlockInPlace {}:{} newLen={}\n", .{@typeName(T), block.ptr(), block.len(), newLen});
                } else {
                    std.debug.warn("{}: retractBlockInPlace {} newLen={}\n", .{@typeName(T), block.ptr(), newLen});
                }
                return try self.allocator.retractBlockInPlace(block, newLen);
            }
        };
        pub usingnamespace if (!implements(T, "shrinkBlockInPlace")) struct {
            pub const shrinkBlockInPlace = void;
        } else struct {
            pub fn shrinkBlockInPlace(self: SelfRef, block: *Block, newLen: usize) void {
                if (comptime Block.hasLen) {
                    std.debug.warn("{}: shrinkBlockInPlace {}:{} newLen={}\n", .{@typeName(T), block.ptr(), block.len(), newLen});
                } else {
                    std.debug.warn("{}: shrinkBlockInPlace {} newLen={}\n", .{@typeName(T), block.ptr(), newLen});
                }
                self.allocator.shrinkBlockInPlace(block, newLen);
            }
        };

        pub usingnamespace if (!implements(T, "cReallocBlock")) struct {
            pub const cReallocBlock = void;
        } else struct {
            pub fn cReallocBlock(self: SelfRef, block: *Block, newLen: usize) error{OutOfMemory}!void {
                if (T.Block.hasLen) {
                    assert(block.len() == currentLen);
                    std.debug.warn("{}: cReallocBlock {}:{} newLen={}\n", .{@typeName(T), block.ptr(), block.len(), newLen});
                } else {
                    std.debug.warn("{}: cReallocBlock {} newLen={}\n", .{@typeName(T), block.ptr(), newLen});
                }
                try self.allocator.cReallocBlock(block, newLen);
                std.debug.warn("{}: cReallocBlock returning {}\n", .{@typeName(T), block.ptr()});
            }
        };
        pub usingnamespace if (!implements(T, "cReallocAlignedBlock")) struct {
            pub const cReallocAlignedBlock = void;
        } else struct {
            pub fn cReallocAlignedBlock(self: SelfRef, block: *Block, currentLen: usize, newLen: usize, currentAlign: u29, minAlign: u29) error{OutOfMemory}!void {
                std.debug.warn("{}: cReallocBlock {}:{} newLen={} align {} > {}\n", .{@typeName(T), block.ptr(), currentLen, newLen, currentAlign, minAlign});
                try self.allocator.cReallocAlignedBlock(block, currentLen, newLen, currentAlign, minAlign);
                std.debug.warn("{}: cReallocBlock returning {}\n", .{@typeName(T), block.ptr()});
            }
        };
        pub const isPreciseWrapped = T.isPreciseWrapped;
    };
}


pub fn makePreciseAllocator(allocator: var) PreciseAllocator(@TypeOf(allocator)) {
    return PreciseAllocator(@TypeOf(allocator)) { .allocator = allocator };
}
pub fn PreciseAllocator(comptime T: type) type {
    if (T.isPreciseWrapped)
        @compileError(@typeName(T) ++ " is already wrapped with PreciseAllocator");
    if (implements(T, "shrinkBlockInPlace"))
        @compileError(@typeName(T) ++ " already supports shrinkInPlace, wrapping it with .precise() won't help");

    return struct {
        const SelfRef = if (@sizeOf(T) == 0) @This() else *@This();
        pub const Block = MakeBlockType(struct {
            const BlockSelf = @This();

            pub const hasLen = true;
            pub const alignment = T.Block.alignment;

            preciseLen: usize,
            forwardBlock: T.Block,

            pub usingnamespace if (T.Block.hasLen or !implements(T.Block, "initBuf")) struct {
                pub const initBuf = void;
            } else struct {
                pub fn initBuf(slice: []align(alignment) u8) BlockSelf { return .{
                    .preciseLen = slice.len,
                    .forwardBlock = T.Block.initBuf(slice.ptr)
                };}
            };

            pub fn ptr(self: BlockSelf) [*]align(alignment) u8 { return self.forwardBlock.ptr(); }
            pub fn len(self: BlockSelf) usize { return self.preciseLen; }
            pub fn setLen(self: *BlockSelf, newLen: usize) void { self.preciseLen = newLen; }
        });

        allocator: T,

        pub const alignForward = void;
        pub fn allocBlock(self: SelfRef, len: usize) error{OutOfMemory}!Block {
            return Block.init(.{
                .preciseLen = len,
                .forwardBlock = try self.allocator.allocBlock(alignLenForward(T, len))
            });
        }

        pub usingnamespace if (!implements(T, "allocOverAlignedBlock")) struct {
            pub const allocOverAlignedBlock = void;
            pub const allocPreciseOverAlignedBlock = void;
        } else struct {
            pub fn allocOverAlignedBlock(self: SelfRef, lenRef: *usize, allocAlign: u29) error{OutOfMemory}!Block {
                const forwardBlock = try self.allocator.allocOverAlignedBlock(lenRef, allocAlign);
                return Block.init(.{
                    .preciseLen = lenRef.*,
                    .forwardBlock = forwardBlock,
                });
            }
            pub fn allocPreciseOverAlignedBlock(self: SelfRef, len: usize, allocAlign: u29) error{OutOfMemory}!Block {
                var forwardBlockLen = len;
                const forwardBlock = try self.allocator.allocOverAlignedBlock(&forwardBlockLen, allocAlign);
                return Block.init(.{
                    .preciseLen = len,
                    .forwardBlock = forwardBlock,
                });
            }
        };

        pub usingnamespace if (!implements(T, "deallocBlock")) struct {
            pub const deallocBlock = void;
        } else struct {
            pub fn deallocBlock(self: SelfRef, block: Block) void {
                return self.allocator.deallocBlock(block.data.forwardBlock);
            }
        };
        pub usingnamespace if (!implements(T, "deallocAll")) struct {
            pub const deallocAll = void;
        } else struct {
            pub fn deallocAll(self: SelfRef) void {
                return self.allocator.deallocAll();
            }
        };
        pub usingnamespace if (!implements(T, "deinitAndDeallocAll")) struct {
            pub const deinitAndDeallocAll = void;
        } else struct {
            pub fn deinitAndDeallocAll(self: SelfRef) void {
                return self.allocator.deinitAndDeallocAll();
            }
        };
        pub usingnamespace if (!implements(T, "extendBlockInPlace")) struct {
            pub const extendBlockInPlace = void;
        } else struct {
            pub fn extendBlockInPlace(self: SelfRef, block: *Block, newLen: usize) error{OutOfMemory}!void {
                const alignedLen = alignLenForward(T, newLen);
                const callExtend = if (comptime !T.Block.hasLen) true
                    else alignedLen > block.data.forwardBlock.len();
                if (callExtend) {
                    try self.allocator.extendBlockInPlace(&block.data.forwardBlock, alignedLen);
                    if (T.Block.hasLen)
                        assert(block.data.forwardBlock.len() == alignedLen);
                }
                block.data.preciseLen = newLen;
            }
        };
        pub usingnamespace if (!implements(T, "retractBlockInPlace")) struct {
            pub const retractBlockInPlace = void;
        } else struct {
            pub fn retractBlockInPlace(self: SelfRef, block: *Block, newLen: usize) error{OutOfMemory}!void {
                const alignedLen = alignLenForward(T, newLen);
                const callRetract = if (comptime !T.Block.hasLen) true
                    else alignedLen > block.data.forwardBlock.len();
                if (callRetract) {
                    try self.allocator.retractBlockInPlace(&block.data.forwardBlock, alignedLen);
                    if (T.Block.hasLen)
                        assert(block.data.forwardBlock.len() == alignedLen);
                }
                block.data.preciseLen = newLen;
            }
        };

        pub fn shrinkBlockInPlace(self: SelfRef, block: *Block, newLen: usize) void {
            const alignedLen = alignLenForward(T, newLen);
            if (comptime implements(T, "shrinkBlockInPlace")) {
                const callShrink = if (comptime !T.Block.hasLen) true
                    else alignedLen > block.data.forwardBlock.len();
                if (callShrink) {
                    self.allocator.shrinkBlockInPlace(&block.data.forwardBlock, alignedLen);
                    if (T.Block.hasLen)
                        assert(block.data.forwardBlock.len() == alignedLen);
                }
            } else if (comptime implements(T, "retractBlockInPlace")) {
                self.retractBlockInPlace(block, newLen) catch |e| { }; // ignore error
            }
            block.data.preciseLen = newLen;
        }

        pub usingnamespace if (!implements(T, "cReallocBlock")) struct {
            pub const cReallocBlock = void;
        } else struct {
            pub fn cReallocBlock(self: SelfRef, block: *Block, newLen: usize) error{OutOfMemory}!void {
                if (comptime T.Block.hasLen) {
                    if (block.data.forwardBlock.len() == newLen) return;
                }
                try self.allocator.cReallocBlock(&block.data.forwardBlock, newLen);
                block.data.preciseLen = newLen;
            }
        };
        pub usingnamespace if (!implements(T, "cReallocAlignedBlock")) struct {
            pub const cReallocAlignedBlock = void;
        } else struct {
            pub fn cReallocAlignedBlock(self: SelfRef, block: *Block, currentLen: usize, newLen: usize, currentAlign: u29, minAlign: u29) error{OutOfMemory}!void {
                assert(currentLen == block.data.preciseLen);
                if (comptime T.Block.hasLen) {
                    if (block.data.forwardBlock.len() == newLen) return;
                }
                try self.allocator.cReallocAlignedBlock(&block.data.forwardBlock, currentLen, newLen, currentAlign, minAlign);
                block.data.preciseLen = newLen;
            }
        };
        pub const isPreciseWrapped = true;
    };
}

pub fn makeAlignAllocator(allocator: var) AlignAllocator(@TypeOf(allocator)) {
    return AlignAllocator(@TypeOf(allocator)) { .allocator = allocator };
}
pub fn AlignAllocator(comptime T: type) type {
    if (implements(T, "allocOverAlignedBlock"))
        @compileError("cannot wrap '" ++ @typeName(T) ++ "' with AlignAllocator because it already implements allocOverAlignedBlock");
    if (implements(T, "cReallocAlignedBlock"))
        @compileError("cannot wrap '" ++ @typeName(T) ++ "' with AlignAllocator because it already implements cReallocAlignedBlock");

     // SEE NOTE: "Why does PreciseAllocator wrap AlignAllocator instead of the other way around?"
     if (T.isPreciseWrapped)
        @compileError("PreciseAllocator must wrap AlignAllocator, not the other way around, i.e. .align() must come before .precise()");

    return struct {
        const SelfRef = if (@sizeOf(T) == 0) @This() else *@This();

        const BlockData = struct {
            const BlockSelf = @This();

            pub const hasLen = T.Block.hasLen;
            pub const alignment = T.Block.alignment;

            buf: [*]align(T.Block.alignment) u8,
            forwardBlock: T.Block,
            // AlignAllocaor can never be represented with just a single pointer/slice
            pub const initBuf = void;
            pub fn ptr(self: BlockSelf) [*]align(alignment) u8 { return self.buf; }
            pub fn len(self: BlockSelf) usize { return self.forwardBlock.len() - getAlignOffsetData(self); }
            pub fn setLen(self: *BlockSelf, newLen: usize) void {
                self.forwardBlock.setLen(getAlignOffsetData(self.*) + newLen);
            }
        };
        pub const Block = MakeBlockType(BlockData);
        allocator: T,

        /// returns the offset of the aligned block from the underlying allocated block
        fn getAlignOffsetData(blockData: BlockData) usize {
            return @ptrToInt(blockData.buf) - @ptrToInt(blockData.forwardBlock.ptr());
        }
        fn getAlignOffset(block: Block) usize { return getAlignOffsetData(block.data); }

        pub const alignForward = T.alignForward;
        pub fn allocBlock(self: SelfRef, len: usize) error{OutOfMemory}!Block {
            const forwardBlock = try self.allocator.allocBlock(len);
            return Block.init(.{ .buf = forwardBlock.ptr(), .forwardBlock = forwardBlock });
        }
        pub fn allocOverAlignedBlock(self: SelfRef, lenRef: *usize, allocAlign: u29) error{OutOfMemory}!Block {
            assert(lenRef.* > 0);
            assert(isValidAlign(allocAlign));
            assert(allocAlign > Block.alignment);

            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
            // TODO: check if allocator as nextAllocAlign/nextPointer so we can limit how much
            //       we need to allocate
            // !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

            // TODO: if the allocator supports extendBlockInPlace, we could try to allocate a buffer
            //       and extend it if we need more alignment, then if it supports retract we could try
            //       calling retract (note: retract, rather than shrink would be the right choice in
            //       this case, and handling failure by keeping the extra memory for ourselves)

            // at this point all we can do is allocate more to guarantee we'll get an aligend buffer of len bytes.
            // We need to allocate len, plus, the maximum span we would need to drop to find an aligned address.
            // TODO: instead of (- Block.alignment), (- self.allocator.nextAlignment())
            const maxDropLen = allocAlign - Block.alignment;
            const allocLen = alignLenForward(T, lenRef.* + maxDropLen);
            const forwardBlock = try self.allocator.allocBlock(allocLen);
            if (T.Block.hasLen)
                assert(allocLen == forwardBlock.len());
            const alignedPtr = @alignCast(Block.alignment,
                @intToPtr([*]u8, mem.alignForward(@ptrToInt(forwardBlock.ptr()), allocAlign))
            );
            const block = Block.init(.{ .buf = alignedPtr, .forwardBlock = forwardBlock });
            lenRef.* = allocLen - getAlignOffset(block);
            return block;
        }
        pub const allocPreciseOverAlignedBlock = void;

        pub usingnamespace if (!implements(T, "deallocBlock")) struct {
            pub const deallocBlock = void;
        } else struct {
            pub fn deallocBlock(self: SelfRef, block: Block) void {
                return self.allocator.deallocBlock(block.data.forwardBlock);
            }
        };
        pub usingnamespace if (!implements(T, "deallocAll")) struct {
            pub const deallocAll = void;
        } else struct {
            pub fn deallocAll(self: SelfRef) void {
                return self.allocator.deallocAll();
            }
        };
        pub usingnamespace if (!implements(T, "deinitAndDeallocAll")) struct {
            pub const deinitAndDeallocAll = void;
        } else struct {
            pub fn deinitAndDeallocAll(self: SelfRef) void {
                return self.allocator.deinitAndDeallocAll();
            }
        };
        pub usingnamespace if (!implements(T, "extendBlockInPlace")) struct {
            pub const extendBlockInPlace = void;
        } else struct {
            pub fn extendBlockInPlace(self: SelfRef, block: *Block, newLen: usize) error{OutOfMemory}!void {
                const newAlignedLen = getAlignOffset(block.*) + newLen;
                // because we may have over-allocated, there could be alot of room available
                // and we MUST check this before calling extendBlockInPlace because the size we request
                // must be larger than what is already allocated
                var callExtend = if (comptime !T.Block.hasLen) true
                    else newAlignedLen > block.data.forwardBlock.len();
                if (callExtend) {
                    try self.allocator.extendBlockInPlace(&block.data.forwardBlock, newAlignedLen);
                    if (T.Block.hasLen) {
                        assert(block.data.forwardBlock.len() == newAlignedLen);
                    }
                }
            }
        };
        pub usingnamespace if (!implements(T, "retractBlockInPlace")) struct {
            pub const retractBlockInPlace = void;
        } else struct {
            pub fn retractBlockInPlace(self: SelfRef, block: *Block, newLen: usize) error{OutOfMemory}!void {
                assert(newLen > 0);
                const newAlignedLen = getAlignOffset(block.*) + newLen;
                const callRetract = if (comptime !T.Block.hasLen) true
                    else newAlignedLen < block.data.forwardBlock.len();
                if (callRetract) {
                    try self.allocator.retractBlockInPlace(&block.data.forwardBlock, newAlignedLen);
                    if (T.Block.hasLen) {
                        assert(block.data.forwardBlock.len() == newAlignedLen);
                    }
                }
            }
        };
        pub usingnamespace if (!implements(T, "shrinkBlockInPlace")) struct {
            pub const shrinkBlockInPlace = void;
        } else struct {
            pub fn shrinkBlockInPlace(self: SelfRef, block: *Block, newLen: usize) void {
                assert(newLen > 0);
                if (T.Block.hasLen) assert(newLen < block.len());
                const newAlignedLen = getAlignOffset(block.*) + newLen;
                const callShrink = if (comptime !T.Block.hasLen) true
                    else newAlignedLen < block.data.forwardBlock.len();
                if (callShrink) {
                    try self.allocator.shrinkBlockInPlace(&block.data.forwardBlock, newAlignedLen);
                    if (T.Block.hasLen) {
                        assert(block.data.forwardBlock.len() == newAlignedLen);
                    }
                }
            }
        };

        pub const cReallocBlock = void;
        pub usingnamespace if (!implements(T, "cReallocBlock")) struct {
            pub const cReallocAlignedBlock = void;
        } else struct {
            // Note that this maintains the alignment from the original allocOverAlignedBlock call
            pub fn cReallocAlignedBlock(self: SelfRef, block: *Block, currentLen: usize, newLen: usize, currentAlign: u29, minAlign: u29) error{OutOfMemory}!void {
                if (T.Block.hasLen) assert(currentLen == block.len());
                assert(newLen > 0);
                if (comptime implements(T, "alignForward")) assert(newLen == alignForward(newLen));
                assert(currentLen != newLen);
                assert(isValidAlign(currentAlign));
                assert(mem.isAligned(@ptrToInt(block.ptr()), currentAlign));
                assert(isValidAlign(minAlign));
                assert(minAlign <= currentAlign);

                // TODO: if minAlign < currentAlign, I could try to take back some space instead of calling realloc
                const maxDropLen = if (minAlign > Block.alignment) minAlign - Block.alignment else 0;
                const allocLen = newLen + maxDropLen;
                try self.allocator.cReallocBlock(&block.data.forwardBlock, allocLen);
                block.data.buf = @alignCast(Block.alignment,
                    @intToPtr([*]u8, mem.alignForward(@ptrToInt(block.data.forwardBlock.ptr()), minAlign))
                );
            }
        };
        pub const isPreciseWrapped = T.isPreciseWrapped;
    };
}

//
// TODO: We could create a PtrAllocator which wraps an allocator with a "pointer-based" API
//       rather than a "slice-based" API.

/// Create a SliceAllocator from a BlockAllocator.
pub fn makeSliceAllocator(allocator: var) SliceAllocator(@TypeOf(allocator)) {
    return SliceAllocator(@TypeOf(allocator)) {
        .allocator = allocator,
    };
}
pub fn SliceAllocator(comptime T: type) type {
    return SliceAllocatorGeneric(T, !implements(T.Block, "initBuf"));
}

/// NOTE: if the underlying Block type has no extra data, then storing the block isn't necessary, however,
///       the user may choose to store it anyway to support shrinkInPlace or provide extra sanity checking.
pub fn makeSliceAllocatorGeneric(allocator: var, comptime storeBlock: bool) SliceAllocatorGeneric(@TypeOf(allocator), storeBlock) {
    return SliceAllocatorGeneric(@TypeOf(allocator), storeBlock) {
        .allocator = allocator,
    };
}
pub fn SliceAllocatorGeneric(comptime T: type, comptime storeBlock : bool) type {
    // The purpose of SliceAllocator is to provide a simple slice-based API.  This means it
    // only need to support precise allocation.
    if (implements(T, "alignForward"))
        @compileError("SliceAllocator cannot wrap imprecise allocator '" ++ @typeName(T) ++ "'. Wrap it with a PreciseAllocator.");
    if (!implements(T.Block, "initBuf") and !storeBlock)
        @compileError("storeBlock must be set to true for " ++ @typeName(T) ++ " because it has extra data");
    return struct {
        const SelfRef = if (@sizeOf(T) == 0) @This() else *@This();
        pub const alignment = T.Block.alignment;
        allocator: T,

        usingnamespace if (!storeBlock) struct {
            /// The size needed to pad each allocation to store the Block
            pub const allocPadding = 0;

            const BlockRef = struct {
                block: T.Block,
                pub fn blockPtr(self: *@This()) *T.Block { return &self.block; }
            };
            pub fn getBlockRef(slice: []align(alignment) u8) BlockRef {
                return .{ .block = T.Block.initBuf(if (T.Block.hasLen) slice else slice.ptr) };
            }
        } else struct {
            /// The size needed to pad each allocation to store the Block
            pub const allocPadding = @sizeOf(T.Block) + @alignOf(T.Block) - 1;

            const BlockRef = struct {
                refPtr: *T.Block,
                pub fn blockPtr(self: @This()) *T.Block { return self.refPtr; }
            };
            // only available if storeBlock is true, can accept non-ref slices
            pub fn getBlockRef(slice: []align(alignment) u8) BlockRef {
                return .{ .refPtr = getStoredBlockRef(slice) };
            }

            // only available if storeBlock is true, can accept non-ref slices
            pub fn getStoredBlockRef(slice: []align(alignment) u8) *T.Block {
                return @intToPtr(*T.Block, mem.alignForward(@ptrToInt(slice.ptr) + slice.len, @alignOf(T.Block)));
            }
            pub fn debugDumpBlock(slice: []align(alignment) u8) void {
                const blockPtr = getStoredBlockRef(buf);
                if (ForwardBlock.hasLen) {
                    std.debug.warn("BLOCK: {}:{}\n", .{blockPtr.ptr(), blockPtr.len()});
                } else {
                    std.debug.warn("BLOCK: {}\n", .{blockPtr.ptr()});
                }
            }
        };

        pub fn alloc(self: SelfRef, len: usize) error{OutOfMemory}![]align(alignment) u8 {
            const paddedLen = len + allocPadding;
            // NOTE: paddedLen will be valid because SliceAllocator checks that T does not implement alignForward
            assert(comptime !implements(T, "alignForward"));
            const block = try self.allocator.allocBlock(paddedLen);
            if (comptime T.Block.hasLen) assert(block.len() == paddedLen);
            const slice = block.ptr()[0..len];
            if (storeBlock)
                getBlockRef(slice).blockPtr().* = block;
            return slice;
        }
        pub usingnamespace if (!implements(T, "allocPreciseOverAlignedBlock")) struct {
            pub const allocOverAligned = void;
        } else struct {
            pub fn allocOverAligned(self: SelfRef, len: usize, allocAlign: u29) error{OutOfMemory}![]align(alignment) u8 {
                assert(len > 0);
                assert(isValidAlign(allocAlign));
                assert(allocAlign > alignment);
                const paddedLen = len + allocPadding;
                const block = try self.allocator.allocPreciseOverAlignedBlock(paddedLen, allocAlign);
                if (comptime T.Block.hasLen) assert(block.len() == paddedLen);
                assert(mem.isAligned(@ptrToInt(block.ptr()), allocAlign));
                const slice = block.ptr()[0..len];
                if (storeBlock)
                    getBlockRef(slice).blockPtr().* = block;
                return slice;
            }
        };
        /// Takes care of calling `alloc` or `allocOverAligned` based on `alignment`.
        pub fn allocAligned(self: SelfRef, len: usize, allocAlign: u29) error{OutOfMemory}![]align(alignment) u8 {
            if (allocAlign <= alignment) return self.alloc(len);
            return self.allocOverAligned(len, allocAlign);
        }
        pub fn dealloc(self: SelfRef, slice: []align(alignment) u8) void {
            const blockPtr = getBlockRef(slice).blockPtr();
            if (storeBlock) {
                assert(blockPtr.ptr() == slice.ptr);
                if (T.Block.hasLen) assert(slice.len + allocPadding == blockPtr.len());
            }
            deallocBlockIfSupported(&self.allocator, blockPtr.*);
        }
        pub usingnamespace if (!implements(T, "extendBlockInPlace")) struct {
            pub const extendInPlace = void;
        } else struct {
            pub fn extendInPlace(self: SelfRef, slice: []align(alignment) u8, newLen: usize) error{OutOfMemory}!void {
                assert(newLen > slice.len);

                var blockRef = getBlockRef(slice);
                const blockPtr = blockRef.blockPtr();
                if (storeBlock) {
                    assert(slice.ptr == blockPtr.ptr());
                    if (T.Block.hasLen) assert(slice.len + allocPadding == blockPtr.len());
                }
                const newPaddedLen = newLen + allocPadding;
                try self.allocator.extendBlockInPlace(blockPtr, newPaddedLen);
                if (T.Block.hasLen)
                    assert(blockPtr.len() == newPaddedLen);
                if (storeBlock) {
                    const newBlockPtr = getStoredBlockRef(slice.ptr[0..newLen]);
                    // NOTE: must be memcpyDown in case of overlap
                    memcpyDown(@ptrCast([*]u8, newBlockPtr), @ptrCast([*]u8, blockPtr), @sizeOf(T.Block));
                    assert(newBlockPtr.ptr() == slice.ptr);
                }
            }
        };

        pub usingnamespace if (!implements(T, "shrinkBlockInPlace")) struct {
            pub const shrinkInPlace = void;
        } else struct {
            pub fn shrinkInPlace(self: SelfRef, slice: []align(alignment) u8, newLen: usize) void {
                assert(newLen > 0);
                assert(newLen < slice.len);
                // make a copy of the block so we don't lose it during the shrink
                var blockRef = getBlockRef(slice);
                var blockCopy = blockRef.blockPtr().*;
                if (storeBlock) {
                    assert(slice.ptr == blockCopy.ptr());
                    if (T.Block.hasLen) assert(slice.len + allocPadding == blockCopy.len());
                }
                const newPaddedLen = newLen + allocPadding;
                self.allocator.shrinkBlockInPlace(&blockCopy, newPaddedLen);
                if (T.Block.hasLen)
                    assert(blockCopy.len() == newPaddedLen);
                if (storeBlock) {
                    getStoredBlockRef(slice.ptr[0..newLen]).* = blockCopy;
                }
            }
        };

        pub usingnamespace if (!implements(T, "allocPreciseOverAlignedBlock")) struct {
            pub const realloc = void;
        } else struct {
            /// Equivalent to C's realloc
            pub fn realloc(self: SelfRef, slice: []align(alignment) u8, newLen: usize, currentAlign: u29, minAlign: u29) error{OutOfMemory}![]align(alignment) u8 {
                assert(newLen > 0);
                // make a copy of the block so we don't lose it during the shrink
                var blockCopy = getBlockRef(slice).blockPtr().*;
                assert(slice.ptr == blockCopy.ptr());
                const blockLen = slice.len + allocPadding;
                if (T.Block.hasLen)
                    assert(blockLen == blockCopy.len());
                const newPaddedLen = newLen + allocPadding;
                try reallocAlignedBlock(&self.allocator, &blockCopy, blockLen, newPaddedLen, currentAlign, minAlign);
                if (T.Block.hasLen)
                    assert(blockCopy.len() == newPaddedLen);
                const newSlice = blockCopy.ptr()[0..newLen];
                if (storeBlock) {
                    getStoredBlockRef(newSlice).* = blockCopy;
                }
                return newSlice;
            }
        };
    };
}

/// TODO: these shouldn't be in this module
fn memcpyUp(dst: [*]u8, src: [*]u8, len: usize) void {
     {var i : usize = 0; while (i < len) : (i += 1) {
         dst[i] = src[i];
     }}
}
fn memcpyDown(dst: [*]u8, src: [*]u8, len: usize) void {
     {var i : usize = len; while (i > 0) {
         i -= 1;
         dst[i] = src[i];
     }}
}

pub fn alignLenForward(comptime T: type, len: usize) usize {
    return if (comptime implements(T, "alignForward")) T.alignForward(len) else len;
}
/// Takes care of calling allocBlock or allocOverAlignedBlock based on `alignment`.
pub fn allocAlignedBlock(allocator: var, lenRef: *usize, alignment: u29) error{OutOfMemory}!@TypeOf(allocator.*).Block {
    const T = @TypeOf(allocator.*);
    if (comptime !implements(T, "allocOverAlignedBlock"))
        @compileError("allocAlignedBlock cannot be called on '" ++ @typeName(T) ++ "' because it is not aligned.  Wrap it with .aligned()");

    assert(lenRef.* > 0);
    assert(isValidAlign(alignment));

    if (alignment <= T.Block.alignment) {
        if (comptime implements(T, "alignForward"))
            lenRef.* = T.alignForward(lenRef.*);
       return allocator.allocBlock(lenRef.*);
    }
    return allocator.allocOverAlignedBlock(lenRef, alignment);
}
/// Takes care of calling allocBlock or allocOverAlignedBlock based on `alignment`.
pub fn allocPreciseAlignedBlock(allocator: var, len: usize, alignment: u29) error{OutOfMemory}!@TypeOf(allocator.*).Block {
    const T = @TypeOf(allocator.*);
    if (comptime !implements(T, "allocPreciseOverAlignedBlock"))
        @compileError("allocPreciseAlignedBlock cannot be called on '" ++ @typeName(T) ++ "' because it is not aligned and precise.  Wrap it with .aligned() and .precise()");

    assert(len > 0);
    assert(isValidAlign(alignment));

    return if (alignment <= T.Block.alignment) allocator.allocBlock(len)
        else allocator.allocPreciseOverAlignedBlock(len, alignment);
}

/// Call deallocBlock only if it is supported by the given allocator, otherwise, do nothing.
pub fn deallocBlockIfSupported(allocator: var, block: @TypeOf(allocator.*).Block) void {
    if (comptime implements(@TypeOf(allocator.*), "deallocBlock")) {
        allocator.deallocBlock(block);
    }
}

// TODO: this function should either be moved somewhere else like std.math, or I should
//       find the existing version of this
fn addRollover(comptime T: type, a: T, b: T) T {
    var result : T = undefined;
    _ = @addWithOverflow(T, a, b, &result);
    return result;
}

pub fn testReadWrite(slice: []u8, seed: u8) void {
    {var i : usize = 0; while (i < slice.len) : (i += 1) {
        slice[i] = addRollover(u8, seed, @intCast(u8, i & 0xFF));
    }}
    {var i : usize = 0; while (i < slice.len) : (i += 1) {
        testing.expect(slice[i] == addRollover(u8, seed, @intCast(u8, i & 0xFF)));
    }}
}

pub fn testBlockAllocator(allocator: var) void {
    const T = @TypeOf(allocator.*);

    // test allocPreciseBlock
    if (comptime implements(T, "allocBlock")) {
        {var i: u8 = 1; while (i < 200) : (i += 17) {
            const len = alignLenForward(T, i);
            assert(len >= i);
            const block = allocator.allocBlock(len) catch continue;
            if (T.Block.hasLen)
                assert(block.len() == len);
            defer deallocBlockIfSupported(allocator, block);
            testReadWrite(block.ptr()[0..len], i);
        }}
    }
    if (comptime implements(T, "allocOverAlignedBlock")) {
        {var alignment: u29 = 1; while (alignment < 8192) : (alignment *= 2) {
            {var i: u8 = 1; while (i < 200) : (i += 17) {
                var len : usize = i;
                const block = allocAlignedBlock(allocator, &len, alignment) catch continue;
                if (T.Block.hasLen)
                    assert(block.len() == len);
                defer deallocBlockIfSupported(allocator, block);
                testReadWrite(block.ptr()[0..len], i);
            }}
        }}
    }
    if (comptime implements(T, "deallocAll")) {
        var i: u8 = 1;
        while (i < 200) : (i += 19) {
            var len = alignLenForward(T, i);
            const block = allocator.allocBlock(len) catch break;
            testReadWrite(block.ptr()[0..len], i);
        }
        allocator.deallocAll();
    }
    // TODO: deinitAndDeallocAll will need a different function where
    //       we aren't testing a specific instance

    if (comptime implements(T, "extendBlockInPlace")) {
        {var i: u8 = 1; while (i < 100) : (i += 1) {
            const len = alignLenForward(T, i);
            assert(len >= i);
            var block = allocator.allocBlock(len) catch continue;
            defer deallocBlockIfSupported(allocator, block);
            testReadWrite(block.ptr()[0..len], 125);

            const extendLen = alignLenForward(T, len + 1);
            assert(extendLen >= len + 1);
            allocator.extendBlockInPlace(&block, extendLen) catch continue;
            testReadWrite(block.ptr()[0..extendLen], 39);
        }}
    }
    if (comptime implements(T, "retractBlockInPlace")) {
        const retractLen = alignLenForward(T, 1);
        assert(retractLen >= 1);
        {var i: u8 = 2; while (i < 100) : (i += 1) {
            const len = alignLenForward(T, i);
            assert(len >= i);
            if (retractLen < len) {
                var block = allocator.allocBlock(len) catch continue;
                defer deallocBlockIfSupported(allocator, block);
                testReadWrite(block.ptr()[0..len], 18);
                allocator.retractBlockInPlace(&block, retractLen) catch continue;
                testReadWrite(block.ptr()[0..retractLen], 91);
            }
        }}
    }
    if (comptime implements(T, "shrinkBlockInPlace")) {
        const shrinkLen = alignLenForward(T, 1);
        assert(shrinkLen >= 1);
        {var i: u8 = 2; while (i < 100) : (i += 1) {
            const len = alignLenForward(T, i);
            assert(len >= i);
            if (shrinkLen < len) {
                var block = allocator.allocBlock(len) catch continue;
                defer deallocBlockIfSupported(allocator, block);
                testReadWrite(block.ptr()[0..len], 18);
                allocator.shrinkBlockInPlace(&block, shrinkLen);
                testReadWrite(block.ptr()[0..shrinkLen], 91);
            }
        }}
    }

    // test reallocBlock
    if (comptime implements(T, "allocPreciseOverAlignedBlock")) {
        {var alignment: u29 = 1; while (alignment <= 8192) : (alignment *= 2) {
            {var i: u8 = 1; while (i < 200) : (i += 17) {
                var len: usize = i;
                var block = allocPreciseAlignedBlock(allocator, len, alignment) catch continue;
                if (T.Block.hasLen) assert(block.len() == len);
                assert(mem.isAligned(@ptrToInt(block.ptr()), alignment));
                defer deallocBlockIfSupported(allocator, block);
                testReadWrite(block.ptr()[0..len], i);
                {
                    const nextLen = len + 10;
                    if (reallocAlignedBlock(allocator, &block, len, nextLen, alignment, alignment)) |_| {
                        if (T.Block.hasLen) assert(block.len() == nextLen);
                        assert(mem.isAligned(@ptrToInt(block.ptr()), alignment));
                        testReadWrite(block.ptr()[0..nextLen], 201);
                        len = nextLen;
                    } else |_| { }
                }
                while (len > 30) {
                    const nextLen = len / 3;
                    if (reallocAlignedBlock(allocator, &block, len, nextLen, alignment, alignment)) |_| {
                        if (T.Block.hasLen) assert(block.len() == nextLen);
                        assert(mem.isAligned(@ptrToInt(block.ptr()), alignment));
                        testReadWrite(block.ptr()[0..nextLen], 201);
                        len = nextLen;
                    } else |_| break;
                }
            }}
        }}
    }
}

fn testSliceAllocator(allocator: var) void {
    const T = @TypeOf(allocator.*);
    {var i: u8 = 1; while (i < 200) : (i += 14) {
        const slice = allocator.alloc(i) catch continue;
        defer allocator.dealloc(slice);
        testReadWrite(slice, i);
    }}
    if (comptime implements(T, "allocOverAligned")) {
        // TODO: test more alignments when implemented
        {var alignment: u8 = 1; while (alignment <= 1) : (alignment *= 2) {
            {var i: u8 = 1; while (i < 200) : (i += 14) {
                const slice = allocator.allocAligned(i, alignment) catch continue;
                defer allocator.dealloc(slice);
                testReadWrite(slice, i);
            }}
        }}
    }
    if (comptime implements(T, "extendInPlace")) {
        {var i: u8 = 1; while (i < 200) : (i += 1) {
            var slice = allocator.alloc(i) catch continue;
            defer allocator.dealloc(slice);
            const extendLen = i + 30;
            allocator.extendInPlace(slice, extendLen) catch continue;
            slice = slice.ptr[0..extendLen];
            testReadWrite(slice, extendLen);
        }}
    }
    if (comptime implements(T, "shrinkInPlace")) {
        {var i: u8 = 2; while (i < 200) : (i += 14) {
            var slice = allocator.alloc(i) catch continue;
            assert(slice.len == i);
            defer allocator.dealloc(slice);
            testReadWrite(slice, i);
            while (slice.len >= 2) {
                const nextLen = slice.len / 2;
                allocator.shrinkInPlace(slice, nextLen);
                slice = slice[0..nextLen];
                testReadWrite(slice, i);
            }
        }}
    }
    if (comptime implements(T, "realloc")) {
        {var alignment: u8 = 1; while (alignment <= 1) : (alignment *= 2) {
            {var i: u8 = 2; while (i < 200) : (i += 14) {
                var slice = allocator.allocAligned(i, alignment) catch continue;
                defer allocator.dealloc(slice);
                testReadWrite(slice, i);
                {var j: u8 = 1; while (j <= 27) : (j += 13) {
                    slice = allocator.realloc(slice, slice.len + j, alignment, alignment) catch break;
                    testReadWrite(slice, j);
                }}
                {var j: u8 = 1; while (j <= 40 and j > slice.len) : (j += 13) {
                    slice = allocator.realloc(slice, slice.len + j, alignment, alignment) catch break;
                    testReadWrite(slice, j);
                }}
            }}
        }}
    }
}

/// TODO: move this to std.mem?
/// alignment must be a power of 2 and cannot be 0
pub fn isValidAlign(alignment: u29) bool {
    return (alignment != 0) and (alignment & (alignment - 1) == 0);
}

/// TODO: this should be moved somewhere else, maybe std.meta?
///
/// Returns whether type `T` implements function `name`, otherwise, it requires that
/// T explicitly disable support by setting it to `void.
///
/// The advantage of requiring every type `T` to explicitly disable a function is that
/// when new functions are added, every type must address whether or not is is supported.
/// This also protects the system from typos, because if a function name is mispelled
/// then it will result in a compile error rather than a runtime bug from the function being
/// unrecognized.
///
pub fn implements(comptime T: type, comptime name: []const u8) bool {
    if (!@hasDecl(T, name))
        @compileError(@typeName(T) ++ " does not implement '" ++ name ++
            "' and has not disabled it by declaring 'pub const " ++ name ++ " = void;'");
    switch (@typeInfo(@TypeOf(@field(T, name)))) {
        .Type => {
            if (@field(T, name) != void)
                @compileError(@typeName(T) ++ " expected '" ++ name ++ "' to be 'void' or a function");
            return false;
        },
        else => return true,
    }
}
