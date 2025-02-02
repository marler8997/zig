const std = @import("std");
const fs = std.fs;
const mem = std.mem;

const CoffHeader = std.coff.CoffHeader;
const SectionHeader = std.coff.SectionHeader;

pub fn main() !u8 {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    // no need to deinit
    const arena = arena_instance.allocator();

    const all_args = try std.process.argsAlloc(arena);
    // no need to free

    const stderr = std.io.getStdErr();
    if (all_args.len <= 1) {
        try stderr.writeAll("Usage: coffdump <coff_file>\n");
        return 0xff;
    }
    const cmd_args = all_args[1..];
    if (cmd_args.len != 1) {
        std.log.err("expected 1 cmdline arg but got {}", .{cmd_args.len});
        return 0xff;
    }
    const file_path = cmd_args[0];

    const content = blk: {
        const file = try fs.cwd().openFile(file_path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(arena, std.math.maxInt(usize));
    };

    const is_exe_or_dll = std.mem.startsWith(u8, content, "MZ");

    var fbs: std.io.FixedBufferStream([]const u8) = .{ .buffer = content, .pos = 0 };
    const reader = fbs.reader();
    var bw = std.io.bufferedWriter(std.io.getStdOut().writer());
    const writer = bw.writer();

    try writer.writeAll("--- Dos Header ---\n");
    if (is_exe_or_dll) {
        const dos_header = try reader.readStructEndian(DosHeader, .little);
        std.debug.assert(dos_header.magic == 0x5a4d);
        inline for (std.meta.fields(DosHeader)) |field| {
            if (comptime std.mem.eql(u8, field.name, "magic")) continue;
            try writer.print(field.name ++ "={any}\n", .{@field(dos_header, field.name)});
        }

        try dumpRawData(writer.any(), content[fbs.pos..dos_header.pe_header_offset]);
        try bw.flush();
        fbs.pos = dos_header.pe_header_offset;

        const pe_sig = try reader.readInt(u32, .little);
        if (pe_sig != 0x00004550) { // "PE\0\0"
            std.log.err("Invalid PE signature: 0x{x:0>8}", .{pe_sig});
            return 0xff;
        }
    } else {
        try writer.writeAll("none (not an exe/dll)\n");
    }
    try bw.flush();

    const file_header = try reader.readStructEndian(CoffHeader, .little);
    try writer.print(
        \\--- File Header ---
        \\machine={0}
        \\section_count={1}
        \\timestamp=0x{2x:0>8}
        \\symbol_table_ptr=0x{3x:0>8} {3}
        \\symbol_count={4}
        \\size_of_optional_header={5}
        \\
    , .{
        fmtEnum(file_header.machine),
        file_header.number_of_sections,
        file_header.time_date_stamp,
        file_header.pointer_to_symbol_table,
        file_header.number_of_symbols,
        file_header.size_of_optional_header,
    });
    inline for (std.meta.fields(std.coff.CoffHeaderFlags)) |field| {
        try writer.print("{s}={}\n", .{ field.name, @field(file_header.flags, field.name) });
    }
    try bw.flush();

    try writer.writeAll("--- Optional Header ---\n");
    if (file_header.size_of_optional_header > 0) {
        try dumpRawData(writer.any(), content[fbs.pos..][0..file_header.size_of_optional_header]);
        fbs.pos += file_header.size_of_optional_header;
    }
    try bw.flush();

    const section_header_start = fbs.pos;

    var section_index: usize = 0;
    while (section_index < file_header.number_of_sections) : (section_index += 1) {
        try writer.print("--- Section {} ---\n", .{section_index + 1});
        fbs.pos = section_header_start + @sizeOf(std.coff.SectionHeader) * section_index;
        const section_header = try reader.readStructEndian(std.coff.SectionHeader, .little);
        const name_len = std.mem.indexOfScalar(u8, &section_header.name, 0) orelse 8;
        const name = section_header.name[0..name_len];
        try writer.print("file_offset=0x{0x:0>8} {0}\n", .{fbs.pos});
        try writer.print("name='{}'\n", .{std.zig.fmtEscapes(name)});
        try writer.print("virt_size     | 0x{0x:0>8} {0}\n", .{section_header.virtual_size});
        try writer.print("virt_addr     | 0x{0x:0>8} {0}\n", .{section_header.virtual_address});
        try writer.print("raw_data_size | 0x{0x:0>8} {0}\n", .{section_header.size_of_raw_data});
        try writer.print("raw_data_ptr  | 0x{0x:0>8} {0}\n", .{section_header.pointer_to_raw_data});
        try writer.print("reloc_ptr     | 0x{0x:0>8} {0}\n", .{section_header.pointer_to_relocations});
        try writer.print("linenum_ptr   | 0x{0x:0>8} {0}\n", .{section_header.pointer_to_linenumbers});
        try writer.print("reloc_count   | {}\n", .{section_header.number_of_relocations});
        try writer.print("linenum_count | {}\n", .{section_header.number_of_linenumbers});
        inline for (std.meta.fields(std.coff.SectionHeaderFlags)) |field| {
            if (comptime std.mem.startsWith(u8, field.name, "_")) {
                std.debug.assert(@field(section_header.flags, field.name) == 0);
                continue;
            }
            try writer.print("{s}={}\n", .{ field.name, @field(section_header.flags, field.name) });
        }
        try bw.flush();

        if (section_header.size_of_raw_data > 0) {
            try dumpRawData(writer.any(), content[section_header.pointer_to_raw_data..][0..section_header.size_of_raw_data]);
            try bw.flush();
        }
    }
    try bw.flush();

    return 0;
}

fn dumpRawData(writer: std.io.AnyWriter, data: []const u8) !void {
    var offset: usize = 0;
    const line_width = 16;
    while (offset < data.len) {
        const len = @min(data.len - offset, line_width);
        try dumpRawDataLine(line_width, writer, @intCast(offset), data[offset..][0..len]);
        offset += len;
    }
}
fn dumpRawDataLine(comptime line_width: usize, writer: std.io.AnyWriter, addr: u32, data: []const u8) !void {
    std.debug.assert(data.len <= line_width);
    const addr_part = 11;
    const hex_part = 2 * line_width;
    const sep = " | ";
    const char_part = line_width;
    var line: [addr_part + hex_part + sep.len + char_part + 1]u8 = undefined;
    {
        const len = (std.fmt.bufPrint(line[0..addr_part], "{x:0>8} | ", .{addr}) catch unreachable).len;
        std.debug.assert(len == addr_part);
    }
    for (0..line_width) |i| {
        const hex_chars = line[addr_part + i * 2 ..];
        const text_char_ref = &line[addr_part + hex_part + sep.len + i];
        if (i < data.len) {
            const len = (std.fmt.bufPrint(hex_chars, "{x:0>2}", .{data[i]}) catch unreachable).len;
            std.debug.assert(len == 2);
            if (std.ascii.isPrint(data[i])) {
                text_char_ref.* = data[i];
            } else {
                text_char_ref.* = '-';
            }
        } else {
            hex_chars[0] = ' ';
            hex_chars[1] = ' ';
            text_char_ref.* = ' ';
        }
    }
    @memcpy(line[addr_part + hex_part ..][0..sep.len], sep);
    line[line.len - 1] = '\n';
    try writer.writeAll(&line);
}

const DosHeader = extern struct {
    magic: u16 align(2),
    last_page_bytes: u16 align(2),
    pages: u16 align(2),
    relocs: u16 align(2),
    header_paragraphs: u16 align(2),
    min_alloc: u16 align(2),
    max_alloc: u16 align(2),
    initial_ss: u16 align(2),
    initial_sp: u16 align(2),
    checksum: u16 align(2),
    initial_ip: u16 align(2),
    initial_cs: u16 align(2),
    reloc_table_offset: u16 align(2),
    overlay: u16 align(2),
    reserved: [4]u16 align(2),
    oem_id: u16 align(2),
    oem_info: u16 align(2),
    reserved2: [10]u16 align(2),
    pe_header_offset: u32 align(2),
};

fn fmtEnum(enum_value: anytype) FmtEnum(@TypeOf(enum_value)) {
    return .{ .value = enum_value };
}
fn FmtEnum(comptime Enum: type) type {
    return struct {
        value: Enum,

        const Self = @This();
        pub fn format(
            self: Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = fmt;
            _ = options;
            try writer.print("{}", .{@intFromEnum(self.value)});
            const enum_info = @typeInfo(Enum).@"enum";
            @setEvalBranchQuota(3 * enum_info.fields.len);
            inline for (enum_info.fields) |field| {
                if (@intFromEnum(self.value) == field.value) {
                    try writer.print("({s})", .{field.name});
                    return;
                }
            }
        }
    };
}
