const std = @import("std.zig");
const builtin = @import("builtin");
const assert = std.debug.assert;
const testing = std.testing;
const math = std.math;
const windows = std.os.windows;
const posix = std.posix;

pub const Epoch = @import("time/Epoch.zig");

/// Deprecated: moved to std.Thread.sleep
pub const sleep = std.Thread.sleep;

pub const Now = switch (builtin.os.tag) {
    .windows => Moment(.windows, .hectonanos, .fromInt(i64)),
    .wasi => Moment(.posix, .nanos, .fromInt(std.os.wasi.timestamp_t)),
    .uefi => Moment(.posix, .nanos, .fromInt(u64)),
    else => Moment(.posix, .nanos, .fromInt(PosixNsec)),
};

pub fn now() Now {
    return switch (builtin.os.tag) {
        .windows => .{ .offset = windows.ntdll.RtlGetSystemTimePrecise() },
        .wasi => {
            var ns: std.os.wasi.timestamp_t = undefined;
            const err = std.os.wasi.clock_time_get(.REALTIME, 1, &ns);
            assert(err == .SUCCESS);
            return .{ .offset = ns };
        },
        .uefi => {
            var value: std.os.uefi.Time = undefined;
            const status = std.os.uefi.system_table.runtime_services.getTime(&value, null);
            assert(status == .success);
            return .{ .offset = value.toEpoch() };
        },
        else => {
            const ts = posix.clock_gettime(.REALTIME) catch |err| switch (err) {
                error.UnsupportedClock, error.Unexpected => return .{ .offset = 0 }, // "Precision of timing depends on hardware and OS".
            };
            return .{ .offset = (@as(PosixNsec, ts.sec) * ns_per_s) + ts.nsec };
        },
    };
}

const PosixNsec = @TypeOf(@as(std.posix.timespec, undefined).nsec);

/// Get a calendar timestamp, in seconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `posix.clock_gettime` for a POSIX timestamp.
pub fn timestamp() Moment(.posix, .secs, .fromInt(i64)) {
    return now().convert(.posix, .secs, .fromInt(i64)) catch |e| switch (e) {
        error.MomentOutOfRange => unreachable,
    };
}

/// Get a calendar timestamp, in milliseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `posix.clock_gettime` for a POSIX timestamp.
pub fn milliTimestamp() Moment(.posix, .millis, .fromInt(i64)) {
    return now().convert(.posix, .millis, .fromInt(i64)) catch |e| switch (e) {
        error.MomentOutOfRange => unreachable,
    };
}

/// Get a calendar timestamp, in microseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `posix.clock_gettime` for a POSIX timestamp.
pub fn microTimestamp() Moment(.posix, .micros, .fromInt(i64)) {
    return now().convert(.posix, .micros, .fromInt(i64)) catch |e| switch (e) {
        error.MomentOutOfRange => unreachable,
    };
}

/// Get a calendar timestamp, in nanoseconds, relative to UTC 1970-01-01.
/// Precision of timing depends on the hardware and operating system.
/// On Windows this has a maximum granularity of 100 nanoseconds.
/// The return value is signed because it is possible to have a date that is
/// before the epoch.
/// See `posix.clock_gettime` for a POSIX timestamp.
pub fn nanoTimestamp() Moment(.posix, .nanos, .fromInt(i128)) {
    return now().convert(.posix, .nanos, .fromInt(i128)) catch |e| switch (e) {
        error.MomentOutOfRange => unreachable,
    };
}

test milliTimestamp {
    const time_0 = milliTimestamp();
    std.Thread.sleep(ns_per_ms);
    const time_1 = milliTimestamp();
    const interval = time_1.offset - time_0.offset;
    try testing.expect(interval > 0);
}

// Divisions of a nanosecond.
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

/// A "Moment" is moment in time, specifically, a time of day and a calendar day/year.
/// A moment is represented by an offset to an epoch where the epoch defines the time
/// at offset 0. The offset is a time unit that can be one of seconds, milliseconds,
/// microseconds, hectonanoseconds or nanoseconds.
pub fn Moment(
    comptime epoch_arg: Epoch,
    comptime unit_arg: Unit,
    comptime range_arg: ComptimeRange,
) type {
    return struct {
        /// The number of time units offset from the epoch.
        offset: range.Int(),

        pub const epoch = epoch_arg;
        pub const range = range_arg;
        pub const unit = unit_arg;
        pub const DayInteger = std.math.IntFittingRange(
            @divFloor(std.math.minInt(range.Int()), @as(range.Int(), unit.perDay())),
            @divFloor(std.math.maxInt(range.Int()), @as(range.Int(), unit.perDay())),
        );
        pub const Year = std.math.IntFittingRange(
            yearLowerBound(epoch, DayInteger),
            yearUpperBound(epoch, DayInteger),
        );

        const Self = @This();

        pub fn eq(self: Self, other: Self) bool {
            return self.offset == other.offset;
        }

        /// Performs a division to return the day this moment occurred.
        /// The resulting day is used to calculate the calendar year/month.
        pub fn asDay(self: Self) Day(epoch, DayInteger) {
            return .{ .offset = @intCast(@divFloor(self.offset, unit.perDay())) };
        }

        /// Performs a modulus to return the time of day this moment occurred.
        /// This operation should be performed after converting to the least granular
        /// time unit needed.
        pub fn timeOfDay(self: Self) TimeOfDay(unit) {
            return TimeOfDay(unit){
                .value = std.math.comptimeMod(self.offset, unit.perDay()),
            };
        }

        pub fn ConvertUnit(comptime target_unit: Unit) type {
            return Moment(epoch, target_unit, range.scale(unit.scaleTo(target_unit)));
        }

        /// Returns this moment converted to the given time unit.
        pub fn convertUnit(self: Self, comptime target_unit: Unit) ConvertUnit(target_unit) {
            const target_range = range.scale(unit.scaleTo(target_unit));
            return switch (unit.scaleTo(target_unit)) {
                .multiply => |mult| if (comptime mult == 1) .{ .offset = self.offset } else .{ .offset = target_range.clamp(
                    @as(target_range.Int(), self.offset) * @as(target_range.Int(), mult),
                ) },
                .divide => |divisor| .{ .offset = target_range.clamp(
                    @intCast(@divFloor((self.offset +% (divisor / 2)), divisor)),
                ) },
            };
        }

        pub fn convertMoment(self: Self, TargetMoment: type) error{MomentOutOfRange}!TargetMoment {
            return self.convert(TargetMoment.epoch, TargetMoment.unit, TargetMoment.range);
        }

        pub fn convert(
            self: Self,
            comptime target_epoch: Epoch,
            comptime target_unit: Unit,
            comptime target_range: ComptimeRange,
        ) error{MomentOutOfRange}!Moment(target_epoch, target_unit, target_range) {
            const converted_unit = self.convertUnit(target_unit);
            const epoch_diff = epoch.diff(target_epoch, target_unit);
            const Int = std.math.IntFittingRange(
                @min(range.min, ConvertUnit(target_unit).range.min, target_range.min, epoch_diff),
                @max(range.max, ConvertUnit(target_unit).range.max, target_range.max, epoch_diff),
            );
            const new_offset: Int = @as(Int, converted_unit.offset) + @as(Int, epoch_diff);
            if (new_offset < target_range.min) return error.MomentOutOfRange;
            if (new_offset > target_range.max) return error.MomentOutOfRange;
            return Moment(target_epoch, target_unit, target_range){ .offset = @intCast(new_offset) };
        }
    };
}

pub fn Day(comptime epoch: Epoch, comptime IntegerArg: type) type {
    return struct {
        offset: Integer,

        pub const Integer = IntegerArg;
        pub const Year = std.math.IntFittingRange(
            yearLowerBound(epoch, Integer),
            yearUpperBound(epoch, Integer),
        );

        const Self = @This();

        pub fn dayOfYear(self: Self) DayOfYear(Year) {
            var year: Year = epoch.year;
            if (epoch.days_into_year != 0) @compileError("todo");

            // TODO: make this more efficient, to do so, we can make a function
            // that can return the number of days in any given range of years.
            // We use that to get "close" to the year and calculate the new day
            // offset, then iterate until we're there.

            var offset_remaining = self.offset;
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
}

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

pub const DayOfMonth = struct {
    month: Month,
    day_index: u5, // days into the month (0 to 30)
};

pub fn DayOfYear(comptime Year: type) type {
    return struct {
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
}

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

    pub fn scaleTo(comptime unit: Unit, comptime target: Unit) Scale {
        return switch (unit) {
            .secs => switch (target) {
                inline else => .{ .multiply = target.perSecond() },
            },
            .millis => switch (target) {
                .secs => .{ .divide = 1000 },
                .millis => .{ .multiply = 1 },
                .micros => .{ .multiply = 1000 },
                .hectonanos => .{ .multiply = 10000 },
                .nanos => .{ .multiply = 1000000 },
            },
            .micros => switch (target) {
                .secs => .{ .divide = 1000000 },
                .millis => .{ .divide = 1000 },
                .micros => .{ .multiply = 1 },
                .hectonanos => .{ .multiply = 10 },
                .nanos => .{ .multiply = 1000 },
            },
            .hectonanos => switch (target) {
                .secs => .{ .divide = 10000000 },
                .millis => .{ .divide = 10000 },
                .micros => .{ .divide = 10 },
                .hectonanos => .{ .multiply = 1 },
                .nanos => .{ .multiply = 100 },
            },
            .nanos => switch (target) {
                .secs => .{ .divide = 1000000000 },
                .millis => .{ .divide = 1000000 },
                .micros => .{ .divide = 1000 },
                .hectonanos => .{ .divide = 100 },
                .nanos => .{ .multiply = 1 },
            },
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

pub const ComptimeRange = struct {
    min: comptime_int,
    max: comptime_int,

    pub fn fromInt(comptime IntArg: type) ComptimeRange {
        return .{ .min = std.math.minInt(IntArg), .max = std.math.maxInt(IntArg) };
    }

    pub fn Int(comptime range: ComptimeRange) type {
        return std.math.IntFittingRange(range.min, range.max);
    }

    pub fn clamp(comptime range: ComptimeRange, value: range.Int()) range.Int() {
        return std.math.clamp(value, range.min, range.max);
    }

    pub fn scale(comptime range: ComptimeRange, scale_value: Scale) ComptimeRange {
        return switch (scale_value) {
            .multiply => |m| .{ .min = range.min * m, .max = range.max * m },
            .divide => |d| .{ .min = range.min / d, .max = range.max / d },
        };
    }
};

pub const Scale = union(enum) {
    multiply: comptime_int,
    divide: comptime_int,
};

fn yearLowerBound(comptime epoch: Epoch, comptime DayInteger: type) comptime_int {
    const min_offset = std.math.minInt(DayInteger);
    return epoch.year + @divFloor(min_offset - 366, 366);
}
fn yearUpperBound(comptime epoch: Epoch, comptime DayInteger: type) comptime_int {
    const max_offset = std.math.maxInt(DayInteger);
    return epoch.year + @divFloor(max_offset, 365) + 1;
}

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
    _ = Epoch;
}
