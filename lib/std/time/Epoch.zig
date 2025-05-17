const Epoch = @This();

year: comptime_int,
/// The number of days into the year (0 to 365)
days_into_year: u9,
/// seconds are sufficient as there are no epoch times that divide the second
secs_into_day: std.math.IntFittingRange(0, std.time.Unit.secs.perDay()),

pub const posix: Epoch = .{ .year = 1970, .days_into_year = 0, .secs_into_day = 0 };
pub const dos: Epoch = .{ .year = 1980, .days_into_year = 0, .secs_into_day = 0 };
pub const ios: Epoch = .{ .year = 2001, .days_into_year = 0, .secs_into_day = 0 };
// !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
// TODO: insert the rest
// /// Nov 17, 1858 AD
// pub const openvms = -3506716800;
// /// Jan 01, 1900 AD
// pub const zos = -2208988800;
pub const windows: Epoch = .{ .year = 1601, .days_into_year = 0, .secs_into_day = 0 };
// /// Jan 01, 1978 AD
// pub const amiga = 252460800;
// /// Dec 31, 1967 AD
// pub const pickos = -63244800;
// /// Jan 06, 1980 AD
// pub const gps = 315964800;
// /// Jan 01, 0001 AD
// pub const clr = -62135769600;

// pub const unix = posix;
// pub const android = posix;
// pub const os2 = dos;
// pub const bios = dos;
// pub const vfat = dos;
// pub const ntfs = windows;
// pub const ntp = zos;
// pub const jbase = pickos;
// pub const aros = amiga;
// pub const morphos = amiga;
// pub const brew = gps;
// pub const atsc = gps;
// pub const go = clr;

pub fn dayOfMonth(epoch: Epoch) std.time.DayOfMonth {
    return (std.time.DayOfYear(std.math.IntFittingRange(epoch.year, epoch.year)){
        .year = epoch.year,
        .day_index = epoch.days_into_year,
    }).dayOfMonth();
}

pub fn diff(
    comptime source_epoch: Epoch,
    comptime target_epoch: Epoch,
    comptime unit: std.time.Unit,
) comptime_int {
    var days_diff: i64 = 0;
    const year_diff = target_epoch.year - source_epoch.year;

    @setEvalBranchQuota(@abs(year_diff) * 100);

    if (year_diff != 0) {
        // Add days for each year between the epochs
        if (year_diff > 0) {
            var year = source_epoch.year;
            while (year < target_epoch.year) : (year += 1) {
                days_diff += std.time.daysInYear(std.time.Leapness.fromYear(year));
            }
        } else {
            var year = target_epoch.year;
            while (year < source_epoch.year) : (year += 1) {
                days_diff -= std.time.daysInYear(std.time.Leapness.fromYear(year));
            }
        }
    }
    // Adjust for days into the year
    days_diff += @as(i64, target_epoch.days_into_year) - @as(i64, source_epoch.days_into_year);
    // Calculate the difference in seconds within a day
    const secs_diff = @as(i64, target_epoch.secs_into_day) - @as(i64, source_epoch.secs_into_day);
    // Convert the days and seconds to the target unit
    const days_in_unit = @as(i64, unit.perDay()) * days_diff;
    const secs_in_unit = @divTrunc(@as(i64, unit.perSecond()) * secs_diff, @as(i64, std.time.Unit.secs.perSecond()));
    return days_in_unit + secs_in_unit;
}

const std = @import("std");
