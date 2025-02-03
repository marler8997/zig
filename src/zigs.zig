const std = @import("std");

pub const Platform = enum {
    @"linux-x86_64",
};

pub fn getHash(platform: Platform, version: []const u8) ?[68]u8 {
    if (std.mem.eql(u8, version, "0.13.0")) return switch (platform) {
        .@"linux-x86_64" => "122095c9b2703250317da71eb14a2979a398ec776b42a979d5ffbf0cc5100a77e36b".*,
    };
    return null;
}
