pub const HANDLE = @import("std").os.windows.HANDLE;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));
pub extern "kernel32" fn ExitProcess(
    uExitCode: u32,
) callconv(@import("std").os.windows.WINAPI) noreturn;
pub const STD_HANDLE = enum(u32) {
    INPUT_HANDLE = 4294967286,
    OUTPUT_HANDLE = 4294967285,
    ERROR_HANDLE = 4294967284,
};
pub extern "kernel32" fn GetStdHandle(
    nStdHandle: STD_HANDLE,
) callconv(@import("std").os.windows.WINAPI) HANDLE;
pub extern "kernel32" fn WriteFile(
    hFile: ?HANDLE,
    // TODO: what to do with BytesParamIndex 2?
    lpBuffer: ?*const anyopaque,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: ?*u32,
    lpOverlapped: ?*OVERLAPPED,
) callconv(@import("std").os.windows.WINAPI) i32;
pub const OVERLAPPED = extern struct {
    Internal: usize,
    InternalHigh: usize,
    Anonymous: extern union {
        Anonymous: extern struct {
            Offset: u32,
            OffsetHigh: u32,
        },
        Pointer: ?*anyopaque,
    },
    hEvent: ?HANDLE,
};
