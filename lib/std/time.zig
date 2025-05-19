const std = @import("std.zig");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const math = std.math;
const windows = std.os.windows;
const posix = std.posix;

pub const epoch = @import("time/epoch.zig");

/// Deprecated: moved to std.Thread.sleep
pub const sleep = std.Thread.sleep;

/// Deprecated: use now
///
/// Get a calendar timestamp, in seconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `posix.clock_gettime` for a POSIX timestamp.
pub fn timestamp() i64 {
    return @divFloor(milliTimestamp(), ms_per_s);
}

/// Deprecated: use now
///
/// Get a calendar timestamp, in milliseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `posix.clock_gettime` for a POSIX timestamp.
pub fn milliTimestamp() i64 {
    return @as(i64, @intCast(@divFloor(nanoTimestamp(), ns_per_ms)));
}

/// Deprecated: use now
///
/// Get a calendar timestamp, in microseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `posix.clock_gettime` for a POSIX timestamp.
pub fn microTimestamp() i64 {
    return @as(i64, @intCast(@divFloor(nanoTimestamp(), ns_per_us)));
}

/// Deprecated: use now
///
/// Get a calendar timestamp, in nanoseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// On Windows this has a maximum granularity of 100 nanoseconds.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `posix.clock_gettime` for a POSIX timestamp.
pub fn nanoTimestamp() i128 {
    return now().convertEpoch();
}

pub fn now() Moment {
    switch (builtin.os.tag) {
        .windows => {
            // RtlGetSystemTimePrecise() has a granularity of 100 nanoseconds and uses the NTFS/Windows epoch,
            // which is 1601-01-01.
            const epoch_adj = epoch.windows * (ns_per_s / 100);
            return @as(i128, windows.ntdll.RtlGetSystemTimePrecise() + epoch_adj) * 100;
        },
        .wasi => {
            var ns: std.os.wasi.timestamp_t = undefined;
            const err = std.os.wasi.clock_time_get(.REALTIME, 1, &ns);
            assert(err == .SUCCESS);
            return ns;
        },
        .uefi => {
            var value: std.os.uefi.Time = undefined;
            const status = std.os.uefi.system_table.runtime_services.getTime(&value, null);
            assert(status == .success);
            return value.toEpoch();
        },
        else => {
            const ts = posix.clock_gettime(.REALTIME) catch |err| switch (err) {
                error.UnsupportedClock, error.Unexpected => return 0, // "Precision of timing depends on hardware and OS".
            };
            return (@as(i128, ts.sec) * ns_per_s) + ts.nsec;
        },
    }
}

test now {
    const time_0 = now();
    std.Thread.sleep(ns_per_ms);
    const interval = now().since(time_0);
    try testing.expect(interval > 0);
}

// Divisions of a nanosecond.
pub const ns_per_hns = 100;
pub const ns_per_us = 1000;
pub const ns_per_ms = 1000 * ns_per_us;
pub const ns_per_s = 1000 * ns_per_ms;
pub const ns_per_min = 60 * ns_per_s;
pub const ns_per_hour = 60 * ns_per_min;
pub const ns_per_day = 24 * ns_per_hour;
pub const ns_per_week = 7 * ns_per_day;

// Divisions of a microsecond.
pub const us_per_ms = 1000;
pub const us_per_s = 1000 * us_per_ms;
pub const us_per_min = 60 * us_per_s;
pub const us_per_hour = 60 * us_per_min;
pub const us_per_day = 24 * us_per_hour;
pub const us_per_week = 7 * us_per_day;

// Divisions of a millisecond.
pub const ms_per_s = 1000;
pub const ms_per_min = 60 * ms_per_s;
pub const ms_per_hour = 60 * ms_per_min;
pub const ms_per_day = 24 * ms_per_hour;
pub const ms_per_week = 7 * ms_per_day;

// Divisions of a second.
pub const s_per_min = 60;
pub const s_per_hour = s_per_min * 60;
pub const s_per_day = s_per_hour * 24;
pub const s_per_week = s_per_day * 7;

/// A calendar timestamp with nanosecond precision.
/// The backing integer is the number of nanoseconds before or after 1 January 2000, 00:00:00 UTC.
/// Operations on `Moment`s and `Delta`s with very extreme values (on the order of +- 1e12 years from
/// the year 2000) may give imprecise results.
pub const Moment = enum(i96) {
    _,

    /// Like `until`, but with the arguments flipped.
    pub fn since(end: Moment, start: Moment) Delta {
        return start.until(end);
    }

    /// Gets the `Delta` from `start` to `end`.
    pub fn until(start: Moment, end: Moment) Delta {
        // Prevent overflow here by coercing up. save me ranged ints
        const ns_diff = @as(i97, @intFromEnum(end)) - @as(i97, @intFromEnum(start));
        return .from(ns_diff, .nanosecond);
    }

    // /// Returns the `Moment` representing 00:00:00 UTC on the given date.
    // /// Asserts that `month` and `day` are valid.
    // pub fn fromDate(year: i64, month: u4, day: u5) Moment {
    //     // i'm not implementing this here, it's annoying
    //     // (and this doc comment is probably woefully underspecified)
    //     _ = .{ year, month, day };
    // }

    /// Returns a `Moment` representing `m` offset by the delta `d`.
    pub fn add(m: Moment, d: Delta) Moment {
        // again, prevent overflow by coercing up
        const ns = @as(i97, @intFromEnum(m)) + @as(i97, @intFromEnum(d));
        return @enumFromInt(std.math.lossyCast(i96, ns));
    }

    /// Performs a division to return the day this moment occurred.
    /// The resulting day is used to calculate the calendar year/month.
    pub fn day(m: Moment) Day {
        return @enumFromInt(@as(DayInt, @intCast(@divFloor(@intFromEnum(m), ns_per_day))));
    }

    pub fn timeOfDay(m: Moment, comptime unit: Unit) TimeOfDay(unit) {
        const value: i96 = switch (unit) {
            .secs => @divTrunc(@intFromEnum(m), ns_per_s),
            .millis => @divTrunc(@intFromEnum(m), ns_per_ms),
            .micros => @divTrunc(@intFromEnum(m), ns_per_us),
            .hectonanos => @divTrunc(@intFromEnum(m), ns_per_hns),
            .nanos => @intFromEnum(m),
        };
        return TimeOfDay(unit){
            .value = std.math.comptimeMod(value, unit.perDay()),
        };
    }

    /// The `Moment` of the Unix epoch, 1980/1/1 00:00:00 GMT.
    /// "Unix timestamps" are typically given as an offset from this `Moment` in seconds.
    pub const posix_epoch: Moment = .fromDate(1970, 1, 1);
    // pub const unix_epoch = posix_epoch;
};

/// A signed difference with nanosecond precision between two calendar timestamps.
/// The backing integer value is the number of nanoseconds.
pub const Delta = enum(i96) {
    _,

    /// Convert this `Delta` to a concrete number in a given unit. If the value does not fit in `T`, the
    /// closest possible value of `T` is returned (see `std.math.lossyCast`).
    ///
    /// (there could -- probably *should* -- also be variants of this which use `divCeil` and stuff for
    /// different rounding behavior, or that return an error instead of using lossyCast, etc)
    pub fn in(d: Delta, u: Unit, comptime T: type) T {
        // No `Unit` is `0` or `-1` so this is safe.
        const n = @intFromEnum(d) / @intFromEnum(u);
        return std.math.lossyCast(T, n);
    }

    /// Given a concrete number with an associated unit, creates a corresponding `Delta`. If the value
    /// does not fit in a `Delta`, the closest possible `Delta` is returned.
    pub fn init(n: anytype, u: Unit) Delta {
        const casted = std.math.lossyCast(i96, n);
        const ns = std.math.mul(i96, casted, @intFromEnum(u)) catch |err| switch (err) {
            error.Overflow => if (u > 0) std.math.maxInt(i96) else std.math.minInt(i96),
        };
        return @enumFromInt(ns);
    }

    // could also have some nice convenient wrappers, such as this one (which i'll use in the example below)
    pub fn seconds(n: anytype) Delta {
        return .init(n, .seconds);
    }
};

pub const Unit = enum {
    secs,
    millis,
    micros,
    /// 100 nanoseconds
    hectonanos,
    nanos,

    pub fn perDay(comptime unit: Unit) comptime_int {
        return unit.perHour() * 24;
    }
    pub fn perHour(comptime unit: Unit) comptime_int {
        return unit.perMinute() * 60;
    }
    pub fn perMinute(comptime unit: Unit) comptime_int {
        return unit.perSecond() * 60;
    }
    pub fn perSecond(comptime unit: Unit) comptime_int {
        return switch (unit) {
            .secs => 1,
            .millis => 1000,
            .micros => 1000000,
            .hectonanos => 10000000,
            .nanos => 1000000000,
        };
    }

    // pub fn scaleTo(comptime unit: Unit, comptime target: Unit) Scale {
    //     return switch (unit) {
    //         .secs => switch (target) {
    //             inline else => .{ .multiply = target.perSecond() },
    //         },
    //         .millis => switch (target) {
    //             .secs => .{ .divide = 1000 },
    //             .millis => .{ .multiply = 1 },
    //             .micros => .{ .multiply = 1000 },
    //             .hectonanos => .{ .multiply = 10000 },
    //             .nanos => .{ .multiply = 1000000 },
    //         },
    //         .micros => switch (target) {
    //             .secs => .{ .divide = 1000000 },
    //             .millis => .{ .divide = 1000 },
    //             .micros => .{ .multiply = 1 },
    //             .hectonanos => .{ .multiply = 10 },
    //             .nanos => .{ .multiply = 1000 },
    //         },
    //         .hectonanos => switch (target) {
    //             .secs => .{ .divide = 10000000 },
    //             .millis => .{ .divide = 10000 },
    //             .micros => .{ .divide = 10 },
    //             .hectonanos => .{ .multiply = 1 },
    //             .nanos => .{ .multiply = 100 },
    //         },
    //         .nanos => switch (target) {
    //             .secs => .{ .divide = 1000000000 },
    //             .millis => .{ .divide = 1000000 },
    //             .micros => .{ .divide = 1000 },
    //             .hectonanos => .{ .divide = 100 },
    //             .nanos => .{ .multiply = 1 },
    //         },
    //     };
    // }
};

// test "convert between unix timestamp and moment" {
//     const ts_in: i64 = std.doSomethingToGetAUnixTimestamp();
//     const m_in: Moment = .add(.unix_epoch, .seconds(ts_in));
//     // we converted a unix timestamp to a moment!

//     // then we have our program logic in the middle.
//     // conveniently, this program logic takes a `Moment` and returns a new `Moment`.
//     const m_out = std.doOurLogic(m_in);

//     const ts_out = m_out.since(.unix_epoch).in(.seconds, i64);
//     // annnd we're back to a unix timestamp, to send over the wire or whatever:
//     std.doStuffWithMyTimestamp(ts_out);
// }

const Day = enum(i50) {
    _,

    const Self = @This();

    pub fn dayOfYear(self: Self) DayOfYear {
        var year: Year = 2000;
        // TODO: make this more efficient, to do so, we can make a function
        // that can return the number of days in any given range of years.
        // We use that to get "close" to the year and calculate the new day
        // offset, then iterate until we're there.

        var offset_remaining: DayInt = @intFromEnum(self);
        if (offset_remaining >= 0) {
            while (true) {
                const year_size = daysInYear(.fromYear(year));
                if (offset_remaining < year_size)
                    return .{ .year = year, .day_index = @intCast(offset_remaining) };
                offset_remaining -= @intCast(year_size);
                year += 1;
            }
        } else {
            while (true) {
                year -= 1;
                const year_size = daysInYear(.fromYear(year));
                if (offset_remaining >= -@as(i10, year_size)) {
                    return .{
                        .year = year,
                        // i10 is the smallest signed integer to represent the year size (a u9)
                        .day_index = @intCast(@as(i10, year_size) + @as(i10, @intCast(offset_remaining))),
                    };
                }
                offset_remaining += @intCast(year_size);
            }
        }
    }
};

pub fn TimeOfDay(unit: Unit) type {
    return struct {
        value: std.math.IntFittingRange(0, unit.perDay()),

        const Self = @This();

        /// the number of hours past the start of the day (0 to 23)
        pub fn hour(self: Self) u5 {
            return @as(u5, @intCast(@divTrunc(self.value, unit.perHour())));
        }
        /// the number of minutes past the hour (0 to 59)
        pub fn minute(self: Self) u6 {
            return @as(u6, @intCast(@divTrunc(std.math.comptimeMod(self.value, unit.perHour()), 60)));
        }
        /// the number of seconds past the start of the minute (0 to 59)
        pub fn second(self: Self) u6 {
            return @as(u6, @intCast(@divTrunc(std.math.comptimeMod(self.value, unit.perMinute()), unit.perSecond())));
        }
    };
}

const MomentInt = @typeInfo(Moment).@"enum".tag_type;
const DayInt = @typeInfo(Day).@"enum".tag_type;
// const YearInt = @typeInfo(Year).@"enum".tag_type;
comptime {
    std.debug.assert(DayInt == std.math.IntFittingRange(
        @divFloor(std.math.minInt(MomentInt), @as(MomentInt, ns_per_day)),
        @divFloor(std.math.maxInt(MomentInt), @as(MomentInt, ns_per_day)),
    ));
    std.debug.assert(Year == std.math.IntFittingRange(
        2000 + std.math.minInt(DayInt) * 366,
        2000 + std.math.maxInt(DayInt) * 366,
    ));
}

// const Year = enum(i96) {
//     _,
// };
const Year = i59;

pub const DayOfMonth = struct {
    month: Month,
    day_index: u5, // days into the month (0 to 30)
};

pub const DayOfYear = struct {
    year: Year,
    /// The number of days into the year (0 to 365)
    day_index: u9,

    const Self = @This();

    pub fn dayOfMonth(self: Self) DayOfMonth {
        return if (isLeapYear(self.year)) switch (self.day_index) {
            0...30 => .{ .month = .jan, .day_index = @intCast(self.day_index) },
            31...59 => .{ .month = .feb, .day_index = @intCast(self.day_index - 31) },
            60...90 => .{ .month = .mar, .day_index = @intCast(self.day_index - 60) },
            91...120 => .{ .month = .apr, .day_index = @intCast(self.day_index - 91) },
            121...151 => .{ .month = .may, .day_index = @intCast(self.day_index - 121) },
            152...181 => .{ .month = .jun, .day_index = @intCast(self.day_index - 152) },
            182...212 => .{ .month = .jul, .day_index = @intCast(self.day_index - 182) },
            213...243 => .{ .month = .aug, .day_index = @intCast(self.day_index - 213) },
            244...273 => .{ .month = .sep, .day_index = @intCast(self.day_index - 244) },
            274...304 => .{ .month = .oct, .day_index = @intCast(self.day_index - 274) },
            305...334 => .{ .month = .nov, .day_index = @intCast(self.day_index - 305) },
            335...365 => .{ .month = .dec, .day_index = @intCast(self.day_index - 335) },
            else => unreachable,
        } else switch (self.day_index) {
            0...30 => .{ .month = .jan, .day_index = @intCast(self.day_index) },
            31...58 => .{ .month = .feb, .day_index = @intCast(self.day_index - 31) },
            59...89 => .{ .month = .mar, .day_index = @intCast(self.day_index - 59) },
            90...119 => .{ .month = .apr, .day_index = @intCast(self.day_index - 90) },
            120...150 => .{ .month = .may, .day_index = @intCast(self.day_index - 120) },
            151...180 => .{ .month = .jun, .day_index = @intCast(self.day_index - 151) },
            181...211 => .{ .month = .jul, .day_index = @intCast(self.day_index - 181) },
            212...242 => .{ .month = .aug, .day_index = @intCast(self.day_index - 212) },
            243...272 => .{ .month = .sep, .day_index = @intCast(self.day_index - 243) },
            273...303 => .{ .month = .oct, .day_index = @intCast(self.day_index - 273) },
            304...333 => .{ .month = .nov, .day_index = @intCast(self.day_index - 304) },
            334...364 => .{ .month = .dec, .day_index = @intCast(self.day_index - 334) },
            else => unreachable,
        };
    }
};

pub const Leapness = enum {
    no_leap,
    leap,

    pub fn fromYear(year: anytype) Leapness {
        return if (isLeapYear(year)) .leap else .no_leap;
    }
};

pub fn isLeapYear(year: anytype) bool {
    if (@mod(year, 4) != 0)
        return false;
    if (@mod(year, 100) != 0)
        return true;
    return (0 == @mod(year, 400));
}

pub fn daysInYear(leapness: Leapness) u9 {
    return if (leapness == .leap) 366 else 365;
}

pub const Month = enum(u4) {
    jan = 1,
    feb,
    mar,
    apr,
    may,
    jun,
    jul,
    aug,
    sep,
    oct,
    nov,
    dec,

    /// Create month from numeric calendar value (1 through 12)
    pub fn fromNumeric(numeric_value: u4) Month {
        return @enumFromInt(numeric_value);
    }

    /// return the numeric calendar value for the given month
    /// i.e. jan=1, feb=2, etc
    pub fn numeric(self: Month) u4 {
        return @intFromEnum(self);
    }

    /// return the month as an index, 0 through 11
    pub fn index(self: Month) u4 {
        return self.numeric() - 1;
    }

    pub fn dayCount(self: Month, leapness: Leapness) u5 {
        return switch (self) {
            .jan => 31,
            .feb => if (leapness == .leap) 29 else 28,
            .mar => 31,
            .apr => 30,
            .may => 31,
            .jun => 30,
            .jul => 31,
            .aug => 31,
            .sep => 30,
            .oct => 31,
            .nov => 30,
            .dec => 31,
        };
    }
};

/// An Instant represents a timestamp with respect to the currently
/// executing program that ticks during suspend and can be used to
/// record elapsed time unlike `nanoTimestamp`.
///
/// It tries to sample the system's fastest and most precise timer available.
/// It also tries to be monotonic, but this is not a guarantee due to OS/hardware bugs.
/// If you need monotonic readings for elapsed time, consider `Timer` instead.
pub const Instant = struct {
    timestamp: if (is_posix) posix.timespec else u64,

    // true if we should use clock_gettime()
    const is_posix = switch (builtin.os.tag) {
        .windows, .uefi, .wasi => false,
        else => true,
    };

    /// Queries the system for the current moment of time as an Instant.
    /// This is not guaranteed to be monotonic or steadily increasing, but for
    /// most implementations it is.
    /// Returns `error.Unsupported` when a suitable clock is not detected.
    pub fn now() error{Unsupported}!Instant {
        const clock_id = switch (builtin.os.tag) {
            .windows => {
                // QPC on windows doesn't fail on >= XP/2000 and includes time suspended.
                return .{ .timestamp = windows.QueryPerformanceCounter() };
            },
            .wasi => {
                var ns: std.os.wasi.timestamp_t = undefined;
                const rc = std.os.wasi.clock_time_get(.MONOTONIC, 1, &ns);
                if (rc != .SUCCESS) return error.Unsupported;
                return .{ .timestamp = ns };
            },
            .uefi => {
                var value: std.os.uefi.Time = undefined;
                const status = std.os.uefi.system_table.runtime_services.getTime(&value, null);
                if (status != .success) return error.Unsupported;
                return .{ .timestamp = value.toEpoch() };
            },
            // On darwin, use UPTIME_RAW instead of MONOTONIC as it ticks while
            // suspended.
            .macos, .ios, .tvos, .watchos, .visionos => posix.CLOCK.UPTIME_RAW,
            // On freebsd derivatives, use MONOTONIC_FAST as currently there's
            // no precision tradeoff.
            .freebsd, .dragonfly => posix.CLOCK.MONOTONIC_FAST,
            // On linux, use BOOTTIME instead of MONOTONIC as it ticks while
            // suspended.
            .linux => posix.CLOCK.BOOTTIME,
            // On other posix systems, MONOTONIC is generally the fastest and
            // ticks while suspended.
            else => posix.CLOCK.MONOTONIC,
        };

        const ts = posix.clock_gettime(clock_id) catch return error.Unsupported;
        return .{ .timestamp = ts };
    }

    /// Quickly compares two instances between each other.
    pub fn order(self: Instant, other: Instant) std.math.Order {
        // windows and wasi timestamps are in u64 which is easily comparible
        if (!is_posix) {
            return std.math.order(self.timestamp, other.timestamp);
        }

        var ord = std.math.order(self.timestamp.sec, other.timestamp.sec);
        if (ord == .eq) {
            ord = std.math.order(self.timestamp.nsec, other.timestamp.nsec);
        }
        return ord;
    }

    /// Returns elapsed time in nanoseconds since the `earlier` Instant.
    /// This assumes that the `earlier` Instant represents a moment in time before or equal to `self`.
    /// This also assumes that the time that has passed between both Instants fits inside a u64 (~585 yrs).
    pub fn since(self: Instant, earlier: Instant) u64 {
        switch (builtin.os.tag) {
            .windows => {
                // We don't need to cache QPF as it's internally just a memory read to KUSER_SHARED_DATA
                // (a read-only page of info updated and mapped by the kernel to all processes):
                // https://docs.microsoft.com/en-us/windows-hardware/drivers/ddi/ntddk/ns-ntddk-kuser_shared_data
                // https://www.geoffchappell.com/studies/windows/km/ntoskrnl/inc/api/ntexapi_x/kuser_shared_data/index.htm
                const qpc = self.timestamp - earlier.timestamp;
                const qpf = windows.QueryPerformanceFrequency();

                // 10Mhz (1 qpc tick every 100ns) is a common enough QPF value that we can optimize on it.
                // https://github.com/microsoft/STL/blob/785143a0c73f030238ef618890fd4d6ae2b3a3a0/stl/inc/chrono#L694-L701
                const common_qpf = 10_000_000;
                if (qpf == common_qpf) {
                    return qpc * (ns_per_s / common_qpf);
                }

                // Convert to ns using fixed point.
                const scale = @as(u64, std.time.ns_per_s << 32) / @as(u32, @intCast(qpf));
                const result = (@as(u96, qpc) * scale) >> 32;
                return @as(u64, @truncate(result));
            },
            .uefi, .wasi => {
                // UEFI and WASI timestamps are directly in nanoseconds
                return self.timestamp - earlier.timestamp;
            },
            else => {
                // Convert timespec diff to ns
                const seconds = @as(u64, @intCast(self.timestamp.sec - earlier.timestamp.sec));
                const elapsed = (seconds * ns_per_s) + @as(u32, @intCast(self.timestamp.nsec));
                return elapsed - @as(u32, @intCast(earlier.timestamp.nsec));
            },
        }
    }
};

/// A monotonic, high performance timer.
///
/// Timer.start() is used to initialize the timer
/// and gives the caller an opportunity to check for the existence of a supported clock.
/// Once a supported clock is discovered,
/// it is assumed that it will be available for the duration of the Timer's use.
///
/// Monotonicity is ensured by saturating on the most previous sample.
/// This means that while timings reported are monotonic,
/// they're not guaranteed to tick at a steady rate as this is up to the underlying system.
pub const Timer = struct {
    started: Instant,
    previous: Instant,

    pub const Error = error{TimerUnsupported};

    /// Initialize the timer by querying for a supported clock.
    /// Returns `error.TimerUnsupported` when such a clock is unavailable.
    /// This should only fail in hostile environments such as linux seccomp misuse.
    pub fn start() Error!Timer {
        const current = Instant.now() catch return error.TimerUnsupported;
        return Timer{ .started = current, .previous = current };
    }

    /// Reads the timer value since start or the last reset in nanoseconds.
    pub fn read(self: *Timer) u64 {
        const current = self.sample();
        return current.since(self.started);
    }

    /// Resets the timer value to 0/now.
    pub fn reset(self: *Timer) void {
        const current = self.sample();
        self.started = current;
    }

    /// Returns the current value of the timer in nanoseconds, then resets it.
    pub fn lap(self: *Timer) u64 {
        const current = self.sample();
        defer self.started = current;
        return current.since(self.started);
    }

    /// Returns an Instant sampled at the callsite that is
    /// guaranteed to be monotonic with respect to the timer's starting point.
    fn sample(self: *Timer) Instant {
        const current = Instant.now() catch unreachable;
        if (current.order(self.previous) == .gt) {
            self.previous = current;
        }
        return self.previous;
    }
};

test Timer {
    var timer = try Timer.start();

    std.Thread.sleep(10 * ns_per_ms);
    const time_0 = timer.read();
    try testing.expect(time_0 > 0);

    const time_1 = timer.lap();
    try testing.expect(time_1 >= time_0);
}

test {
    _ = epoch;
    _ = @import("time/test.zig");
}
