//const win32 = @import("win32").everything;
const win32 = @import("win32.zig");

//pub fn main() void {
pub export fn WinMainCRTStartup() callconv(.winapi) noreturn {
    const hStdOut = win32.GetStdHandle(.OUTPUT_HANDLE);
    if (hStdOut == win32.INVALID_HANDLE_VALUE) {
        //std.debug.warn("Error: GetStdHandle failed with {}\n", .{GetLastError()});
        win32.ExitProcess(255);
    }
    writeAll(hStdOut, "Hello, World!\n") catch win32.ExitProcess(255); // fail
    win32.ExitProcess(0);
}

fn writeAll(hFile: win32.HANDLE, buffer: []const u8) !void {
    var written: usize = 0;
    while (written < buffer.len) {
        const next_write = @as(u32, @intCast(0xFFFFFFFF & (buffer.len - written)));
        var last_written: u32 = undefined;
        if (1 != win32.WriteFile(hFile, buffer.ptr + written, next_write, &last_written, null)) {
            // TODO: return from GetLastError
            return error.WriteFileFailed;
        }
        written += last_written;
    }
}
// const std = @import("std");
// //pub export fn wWinMainCRTStartup() callconv(.withStackAlign(.c, 1)) noreturn {
// //    std.os.windows.ntdll.RtlExitUserProcess(0);
// //}
// pub fn main() void {
//     //std.os.windows.ntdll.RtlExitUserProcess(0);

//     std.os.windows.kernel32.ExitProcess(0);
// }
