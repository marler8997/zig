const std = @import("std");



fn valueSet(comptime enum_info: std.builtin.TypeInfo.Enum) std.AutoHashMap(enum_info.tag_type, void) {
    var memory: [100]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&memory);
    
    var map = std.AutoHashMapUnmanaged(enum_info.tag_type, void) { };
    errdefer map.deinit();
    inline for (enum_info.fields) |enum_field| {
        map.put(fba.allocator(), @intCast(enum_info.tag_type, enum_field.value), {});
    }
    return map;
}

const E = enum { a, b, c };

pub fn main() !void {
    const enum_info = @typeInfo(E).Enum;
    const set = comptime valueSet(enum_info);
    std.log.info("{}", .{set.contains(1)});
}
