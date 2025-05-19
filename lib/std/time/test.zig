test "Moment.convert" {
    // try testMomentConvert(.posix, .fromInt(i32));
    // try testMomentConvert(.posix, .fromInt(i64));
    // try testMomentConvert(.posix, .fromInt(u64));
    // try testMomentConvert(.windows, .fromInt(i32));
    // try testMomentConvert(.windows, .fromInt(i64));
    // try testMomentConvert(.windows, .fromInt(u64));
    // try testMomentConvert(.{
    //     .year = -1000,
    //     .days_into_year = 100,
    //     .secs_into_day = 10000,
    // }, .fromInt(i32));
}

// fn testMomentConvert(comptime epoch: std.time.Epoch, comptime range: std.time.ComptimeRange) !void {
//     try testConvertUnit(Moment(epoch, .secs, range){ .offset = 0 });
//     try testConvertUnit(Moment(epoch, .nanos, range){ .offset = 0 });

//     {
//         const MomentSecs = Moment(epoch, .secs, range);
//         const secs0: MomentSecs = .{ .offset = 0 };
//         const secs1: MomentSecs = .{ .offset = 1 };
//         _ = try secs0.convert(epoch, .secs, .{ .min = 0, .max = 0 });
//         _ = try secs1.convert(epoch, .secs, .{ .min = 1, .max = 1 });
//         try testing.expectError(
//             error.MomentOutOfRange,
//             secs0.convert(epoch, .secs, .{ .min = 1, .max = 1 }),
//         );
//     }

//     {
//         const posix_diff = epoch.diff(.posix, .secs);
//         const posix_range: std.time.ComptimeRange = .{
//             .min = @min(0, posix_diff),
//             .max = @max(0, posix_diff),
//         };
//         const zero: Moment(epoch, .secs, range) = .{ .offset = 0 };
//         const zero_posix = try zero.convert(.posix, .secs, posix_range);
//         try testing.expectEqual(posix_diff, zero_posix.offset);
//         const roundtrip = try zero_posix.convert(epoch, .secs, range);
//         try testing.expectEqual(@as(@TypeOf(roundtrip.offset), 0), roundtrip.offset);
//     }
// }

test Moment {
    // try testMoment(.{
    //     .year = 0,
    //     .days_into_year = 0,
    //     .secs_into_day = 0,
    // }, .fromInt(i64), .secs);

    try testMoment(.secs);
    try testMoment(.millis);
    // try testMoment(epoch, .fromInt(i32), .secs);
    // try testMoment(epoch, .fromInt(i32), .millis);
    // try testMoment(epoch, .fromInt(u64), .micros);
    // try testMoment(epoch, .fromInt(i64), .micros);
    // try testMoment(epoch, .fromInt(u64), .nanos);
    // try testMoment(epoch, .fromInt(i64), .nanos);

    //
    // try testEpoch(@as(i32, secs_per_day), .{ .year = 1970, .day = 1 }, .{
    //     .month = .jan,
    //     .day_index = 1,
    // }, .{ .hours_into_day = 0, .minutes_into_hour = 0, .seconds_into_minute = 0 });

    // try testEpoch(@as(i32, -1), .{ .year = 1969, .day = 364 }, .{
    //     .month = .dec,
    //     .day_index = 30,
    // }, .{ .hours_into_day = 23, .minutes_into_hour = 59, .seconds_into_minute = 59 });

    // try testEpoch(@as(i32, -secs_per_day), .{ .year = 1969, .day = 364 }, .{
    //     .month = .dec,
    //     .day_index = 30,
    // }, .{ .hours_into_day = 0, .minutes_into_hour = 0, .seconds_into_minute = 0 });

    // try testEpoch(@as(i32, -(secs_per_day * 365)), .{ .year = 1969, .day = 0 }, .{
    //     .month = .jan,
    //     .day_index = 0,
    // }, .{ .hours_into_day = 0, .minutes_into_hour = 0, .seconds_into_minute = 0 });

    // try testEpoch(@as(u32, 31535999), .{ .year = 1970, .day = 364 }, .{
    //     .month = .dec,
    //     .day_index = 30,
    // }, .{ .hours_into_day = 23, .minutes_into_hour = 59, .seconds_into_minute = 59 });

    // try testEpoch(@as(u32, 1622924906), .{ .year = 2021, .day = 31 + 28 + 31 + 30 + 31 + 4 }, .{
    //     .month = .jun,
    //     .day_index = 4,
    // }, .{ .hours_into_day = 20, .minutes_into_hour = 28, .seconds_into_minute = 26 });

    // try testEpoch(@as(u32, 1625159473), .{ .year = 2021, .day = 31 + 28 + 31 + 30 + 31 + 30 }, .{
    //     .month = .jul,
    //     .day_index = 0,
    // }, .{ .hours_into_day = 17, .minutes_into_hour = 11, .seconds_into_minute = 13 });

    // try testEpoch(@as(i64, windows), .{ .year = 1601, .day = 0 }, .{
    //     .month = .jan,
    //     .day_index = 0,
    // }, .{ .hours_into_day = 0, .minutes_into_hour = 0, .seconds_into_minute = 0 });

}

fn testMoment(comptime unit: std.time.Unit) !void {
    _ = unit;
    try expectMoment(
        @enumFromInt(0),
        .{ .year = 2000, .day_index = 0 },
        .{ .month = .jan, .day_index = 0 },
        .{ .hour = 0, .minute = 0, .second = 0 },
    );

    // {
    //     const m = Moment(epoch, unit, range){ .offset = std.math.maxInt(range.Int()) };
    //     _ = m.timeOfDay();
    //     const day = m.asDay();
    //     _ = day.dayOfYear();
    //     try testConvertUnit(m);
    // }

    // {
    //     const m = Moment(epoch, unit, range){ .offset = std.math.minInt(range.Int()) };
    //     _ = m.timeOfDay();
    //     const day = m.asDay();
    //     _ = day.dayOfYear();
    //     try testConvertUnit(m);
    // }
}

fn expectMoment(
    moment: std.time.Moment,
    expected_day_of_year: std.time.DayOfYear,
    expected_day_of_month: std.time.DayOfMonth,
    expected_time_of_day: struct {
        /// 0 to 23
        hour: u5,
        /// 0 to 59
        minute: u6,
        /// 0 to 59
        second: u6,
    },
) !void {
    const day = moment.day();
    const time_of_day = moment.timeOfDay(.secs);
    const day_of_year = day.dayOfYear();
    try testing.expectEqual(expected_day_of_year.year, @as(@TypeOf(expected_day_of_year.year), @intCast(day_of_year.year)));
    try testing.expectEqual(expected_day_of_year.day_index, day_of_year.day_index);
    try testing.expectEqual(expected_day_of_month, day_of_year.dayOfMonth());
    try testing.expectEqual(expected_time_of_day.hour, time_of_day.hour());
    try testing.expectEqual(expected_time_of_day.minute, time_of_day.minute());
    try testing.expectEqual(expected_time_of_day.second, time_of_day.second());
    // try testConvertUnit(moment);
}

// fn testConvertUnit(moment: anytype) !void {
//     inline for (std.meta.fields(std.time.Unit)) |unit_field| {
//         const test_unit: std.time.Unit = @enumFromInt(unit_field.value);
//         const converted = moment.convertUnit(test_unit);
//         const roundtrip = converted.convertUnit(@TypeOf(moment).unit);
//         switch (@TypeOf(moment).unit.scaleTo(test_unit)) {
//             .multiply => try testing.expectEqual(moment, roundtrip),
//             .divide => {
//                 // we can't guarantee that converting back will be equal because
//                 // we lose information going to a less granular time unit, but
//                 // we should be able to guarantee that converting the roundtrip value
//                 // should have the same result as the original.
//                 try testing.expectEqual(converted, roundtrip.convertUnit(test_unit));
//             },
//         }
//     }
// }

// test "months" {
//     try testMonths(.posix, 1970, 0); // non-leap year
//     try testMonths(.posix, 1972, std.time.Unit.secs.perDay() * 730); // leap year
// }

// fn testMonths(epoch: std.time.Epoch, year: anytype, second_offset: i32) !void {
//     const range: std.time.ComptimeRange = .fromInt(i32);
//     var day_count: range.Int() = 0;
//     inline for (std.meta.fields(std.time.Month)) |month_field| {
//         const month: std.time.Month = .fromNumeric(month_field.value);
//         try expectMoment(
//             Moment(epoch, .secs, range){
//                 .offset = second_offset + std.time.Unit.secs.perDay() * day_count,
//             },
//             .{ .year = year, .day_index = @intCast(day_count) },
//             .{ .month = month, .day_index = 0 },
//             .{ .hour = 0, .minute = 0, .second = 0 },
//         );
//         day_count += month.dayCount(.fromYear(year));
//     }
// }

const std = @import("../std.zig");
const testing = std.testing;
const Moment = std.time.Moment;
