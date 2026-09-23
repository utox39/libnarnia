const std = @import("std");
const epoch = std.time.epoch;

/// Day of the week.
/// `SUN = 0` so that `(epoch_day + 4) % 7` maps directly onto it:
/// 1970-01-01 (epoch day 0) was a Thursday.
pub const WeekDay = enum(u3) {
    SUNDAY = 0,
    MONDAY,
    TUESDAY,
    WEDNESDAY,
    THURSDAY,
    FRIDAY,
    SATURDAY,
};

/// Calendar representation of a UTC unix timestamp
pub const CalendarFields = struct {
    year: epoch.Year,
    month: epoch.Month,
    /// 1-indexed day of month (1-31)
    day: u5,
    hour: u5,
    minute: u6,
    second: u6,
    weekday: WeekDay,

    pub fn format(self: CalendarFields, writer: *std.Io.Writer) !void {
        try writer.print("{d:0>2}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
            self.year,
            self.month.numeric(),
            self.day,
            self.hour,
            self.minute,
            self.second,
        });
        if (std.enums.tagName(WeekDay, self.weekday)) |week_day_str| {
            try writer.print(" ({s})", .{week_day_str});
        }
    }

    /// Decompose a unix timestamp (seconds, UTC) into calendar fields.
    pub fn fromEpochSeconds(secs: i64) CalendarFields {
        if (secs < 0) unreachable;

        const epoch_seconds = epoch.EpochSeconds{ .secs = @intCast(secs) };
        const epoch_day = epoch_seconds.getEpochDay();
        const day_seconds = epoch_seconds.getDaySeconds();
        const year_day = epoch_day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        return .{
            .year = year_day.year,
            .month = month_day.month,
            .day = month_day.day_index + 1,
            .hour = day_seconds.getHoursIntoDay(),
            .minute = day_seconds.getMinutesIntoHour(),
            .second = day_seconds.getSecondsIntoMinute(),
            .weekday = @enumFromInt(@as(u3, @intCast((epoch_day.day + 4) % 7))),
        };
    }

    /// Re-compose calendar fields (assumed UTC) back into a unix timestamp.
    /// `day` must be a valid day for `(year, month)`.
    pub fn toEpochSeconds(year: epoch.Year, month: epoch.Month, day: u5, hour: u5, minute: u6, second: u6) i64 {
        if ((day < 1) and (day > epoch.getDaysInMonth(year, month))) unreachable;

        var days: i64 = 0;

        var y: epoch.Year = epoch.epoch_year;
        while (y < year) : (y += 1) {
            days += epoch.getDaysInYear(y);
        }

        var m: u4 = 1;
        while (m < month.numeric()) : (m += 1) {
            days += epoch.getDaysInMonth(year, @enumFromInt(m));
        }

        days += day - 1;

        return days * @as(i64, epoch.secs_per_day) +
            @as(i64, hour) * std.time.s_per_hour +
            @as(i64, minute) * std.time.s_per_min +
            second;
    }
};

/// The type of schedule.
///
/// Every `nextFireTime` method takes a `from: i64` parameter: a unix
/// timestamp (seconds, UTC) marking the point in time to search forward
/// from. It is not required to be "now" — the scheduler passes the current
/// time in practice, but tests and pre-computation may pass any reference
/// point. The returned fire time is always strictly greater than `from`:
/// if `from` is exactly a fire instant, the *next* occurrence is returned,
/// not that same instant again.
pub const Schedule = union(enum) {
    /// Run a job every N seconds
    every_n_seconds: EveryNSecondsSchedule,
    /// Run a job every N minutes
    every_n_minutes: EveryNMinutesSchedule,
    /// Run a job every hour at MM:SS
    hourly: HourlySchedule,
    /// Run a job every day at HH:MM:SS
    daily: DailySchedule,
    /// Run a job every week on WEEK_DAY at HH:MM:SS
    weekly: WeeklySchedule,
    /// Run a job every month on DAY at HH:MM:SS
    monthly: MonthlySchedule, // day 1-31
    /// Run a job every year on MONTH/DAY at HH:MM:SS
    yearly: YearlySchedule,

    const Self = @This();

    /// Dispatches to the active variant's own `nextFireTime`.
    pub fn nextFireTime(self: Self, from: i64) i64 {
        return switch (self) {
            inline else => |sched| sched.nextFireTime(from),
        };
    }
};

/// Every N seconds
pub const EveryNSecondsSchedule = struct {
    n: usize,

    /// Returns the next multiple of `n` seconds (aligned to the unix epoch)
    /// strictly after `from`.
    /// Panics when `n == 0`.
    pub fn nextFireTime(self: EveryNSecondsSchedule, from: i64) i64 {
        if (self.n == 0) unreachable;

        const interval: i64 = @intCast(self.n);
        return from + interval - @mod(from, interval);
    }
};

/// Every N minutes
pub const EveryNMinutesSchedule = struct {
    n: usize,

    /// Returns the next multiple of `n` minutes (aligned to the unix epoch)
    /// strictly after `from`.
    /// Panics when `n == 0`.
    pub fn nextFireTime(self: EveryNMinutesSchedule, from: i64) i64 {
        if (self.n == 0) unreachable;

        const interval: i64 = @as(i64, @intCast(self.n)) * std.time.s_per_min;
        return from + interval - @mod(from, interval);
    }
};

/// Every hour at MM:SS
pub const HourlySchedule = struct {
    minute: u6, // 2^6 = 64 (0-63). Minutes 0-59
    second: u6 = 0, // 2^6 = 64 (0-63). Seconds 0-59

    /// Returns the next hour boundary (minute:second within the hour)
    /// strictly after `from`.
    pub fn nextFireTime(self: HourlySchedule, from: i64) i64 {
        const fields = CalendarFields.fromEpochSeconds(from);

        var candidate = CalendarFields.toEpochSeconds(
            fields.year,
            fields.month,
            fields.day,
            fields.hour,
            self.minute,
            self.second,
        );

        if (candidate <= from) {
            candidate += std.time.s_per_hour;
        }

        return candidate;
    }
};

/// Every day at HH:MM:SS
pub const DailySchedule = struct {
    hour: u5 = 0, // 2^5 = 32 (0-31). Hours: 0-23
    minute: u6, // 2^6 = 64 (0-63). Minutes 0-59
    second: u6, // 2^6 = 64 (0-63). Seconds 0-59

    /// Returns the next hour:minute:second of day strictly after `from`.
    pub fn nextFireTime(self: DailySchedule, from: i64) i64 {
        const fields = CalendarFields.fromEpochSeconds(from);

        var candidate = CalendarFields.toEpochSeconds(
            fields.year,
            fields.month,
            fields.day,
            self.hour,
            self.minute,
            self.second,
        );

        if (candidate <= from) {
            candidate += epoch.secs_per_day;
        }

        return candidate;
    }
};

/// Every week on WEEK_DAY at HH:MM:SS
pub const WeeklySchedule = struct {
    week_day: WeekDay,
    hour: u5, // 2^5 = 32 (0-31). Hours: 0-23
    minute: u6, // 2^6 = 64 (0-63). Minutes 0-59
    second: u6 = 0, // 2^6 = 64 (0-63). Seconds 0-59

    /// Returns the next occurrence of `day` at hour:minute:second strictly
    /// after `from`.
    pub fn nextFireTime(self: WeeklySchedule, from: i64) i64 {
        const fields = CalendarFields.fromEpochSeconds(from);

        const current_weekday = @intFromEnum(fields.weekday);
        const target_weekday = @intFromEnum(self.week_day);
        const days_until = @mod(@as(i64, target_weekday) - @as(i64, current_weekday), 7);

        const epoch_day = (epoch.EpochSeconds{ .secs = @intCast(from) }).getEpochDay().day;
        const target_epoch_day: u47 = @intCast(@as(i64, epoch_day) + days_until);
        const year_day = (epoch.EpochDay{ .day = target_epoch_day }).calculateYearDay();
        const month_day = year_day.calculateMonthDay();

        var candidate = CalendarFields.toEpochSeconds(
            year_day.year,
            month_day.month,
            month_day.day_index + 1,
            self.hour,
            self.minute,
            self.second,
        );

        if (candidate <= from) {
            candidate += 7 * @as(i64, epoch.secs_per_day);
        }

        return candidate;
    }
};

/// A target day within a month.
pub const DayOfMonth = union(enum) {
    /// A specific day of month (1-31). If a given month doesn't have that
    /// many days (e.g. 31 in April), that month is skipped entirely rather
    /// than clamped.
    day: u5,
    /// The last calendar day of the month, whatever it is (28/29/30/31).
    last_day,

    fn resolve(self: DayOfMonth, year: epoch.Year, month: epoch.Month) ?u5 {
        const days_in_month = epoch.getDaysInMonth(year, month);
        return switch (self) {
            .day => |d| if (d >= 1 and d <= days_in_month) d else null,
            .last_day => days_in_month,
        };
    }
};

/// Every month on DAY at HH:MM:SS
pub const MonthlySchedule = struct {
    day_of_month: DayOfMonth,
    hour: u5 = 0, // 2^5 = 32 (0-31). Hours: 0-23
    minute: u6, // 2^6 = 64 (0-63). Minutes 0-59
    second: u6 = 0, // 2^6 = 64 (0-63). Seconds 0-59

    /// Returns the next month/day/hour:minute:second strictly after `from`.
    pub fn nextFireTime(self: MonthlySchedule, from: i64) i64 {
        const fields = CalendarFields.fromEpochSeconds(from);
        var year = fields.year;
        var month = fields.month;

        while (true) {
            if (self.day_of_month.resolve(year, month)) |day| {
                const candidate = CalendarFields.toEpochSeconds(year, month, day, self.hour, self.minute, self.second);
                if (candidate > from) return candidate;
            }

            if (month == .dec) {
                month = .jan;
                year += 1;
            } else {
                month = @enumFromInt(month.numeric() + 1);
            }
        }
    }
};

/// Every year on MONTH/DAY at HH:MM:SS
pub const YearlySchedule = struct {
    month: epoch.Month,
    day_of_month: DayOfMonth,
    hour: u5 = 0, // 2^5 = 32 (0-31). Hours: 0-23
    minute: u6, // 2^6 = 64 (0-63). Minutes 0-59
    second: u6 = 0, // 2^6 = 64 (0-63). Seconds 0-59

    /// Returns the next occurrence of `month`/`day` at hour:minute:second
    /// strictly after `from`. Years are searched forward one at a time,
    /// skipping any year where `day` doesn't fall inside `month` — so a
    /// `.day = .{ .day = 29 }` schedule on February only fires on leap
    /// years, while `.day = .last_day` always fires every year.
    pub fn nextFireTime(self: YearlySchedule, from: i64) i64 {
        const fields = CalendarFields.fromEpochSeconds(from);
        var year = fields.year;

        while (true) {
            if (self.day_of_month.resolve(year, self.month)) |day| {
                const candidate = CalendarFields.toEpochSeconds(year, self.month, day, self.hour, self.minute, self.second);
                if (candidate > from) return candidate;
            }

            year += 1;
        }
    }
};

// --- TESTS ---

const testing = std.testing;

fn ts(y: epoch.Year, m: u4, d: u5, h: u5, mi: u6, s: u6) i64 {
    return CalendarFields.toEpochSeconds(y, @enumFromInt(m), d, h, mi, s);
}

test "every_n_seconds aligns to epoch boundaries" {
    const sch = EveryNSecondsSchedule{ .n = 15 };
    try testing.expectEqual(@as(i64, 15), sch.nextFireTime(0));
    try testing.expectEqual(@as(i64, 30), sch.nextFireTime(16));
    try testing.expectEqual(@as(i64, 30), sch.nextFireTime(29));
    try testing.expectEqual(@as(i64, 45), sch.nextFireTime(30)); // exclusive `from`
}

test "every_n_minutes aligns to epoch boundaries" {
    const sch = EveryNMinutesSchedule{ .n = 5 };
    try testing.expectEqual(ts(1970, 1, 1, 0, 5, 0), sch.nextFireTime(0));
    try testing.expectEqual(
        ts(1970, 1, 1, 0, 10, 0),
        sch.nextFireTime(
            ts(1970, 1, 1, 0, 5, 0),
        ),
    );
}

test "hourly fires later this hour" {
    const sch = HourlySchedule{ .minute = 30 };
    const from = ts(2026, 9, 12, 10, 0, 0);
    try testing.expectEqual(ts(2026, 9, 12, 10, 30, 0), sch.nextFireTime(from));
}

test "hourly wraps to next hour" {
    const sch = HourlySchedule{ .minute = 30 };
    const from = ts(2026, 9, 12, 23, 45, 0);
    try testing.expectEqual(ts(2026, 9, 13, 0, 30, 0), sch.nextFireTime(from));
}

test "daily fires later today" {
    const sch = DailySchedule{ .hour = 22, .minute = 0, .second = 0 };
    const from = ts(2026, 9, 12, 10, 0, 0);
    try testing.expectEqual(ts(2026, 9, 12, 22, 0, 0), sch.nextFireTime(from));
}

test "daily at exact fire instant rolls to tomorrow" {
    const sch = DailySchedule{ .hour = 22, .minute = 0, .second = 0 };
    const from = ts(2026, 9, 12, 22, 0, 0);
    try testing.expectEqual(ts(2026, 9, 13, 22, 0, 0), sch.nextFireTime(from));
}

test "daily crosses year boundary" {
    const sch = DailySchedule{ .hour = 0, .minute = 0, .second = 0 };
    const from = ts(2026, 12, 31, 23, 59, 59);
    try testing.expectEqual(ts(2027, 1, 1, 0, 0, 0), sch.nextFireTime(from));
}

test "weekly fires later same week" {
    const sch = WeeklySchedule{ .week_day = .FRIDAY, .hour = 9, .minute = 0, .second = 0 };
    const from = ts(2026, 9, 7, 8, 0, 0); // Monday 2026-09-07
    try testing.expectEqual(ts(2026, 9, 11, 9, 0, 0), sch.nextFireTime(from)); // Friday
}

test "weekly at exact fire instant rolls to next week" {
    const sch = WeeklySchedule{ .week_day = .FRIDAY, .hour = 9, .minute = 0, .second = 0 };
    const from = ts(2026, 9, 11, 9, 0, 0); // Friday, exact fire instant
    try testing.expectEqual(ts(2026, 9, 18, 9, 0, 0), sch.nextFireTime(from));
}

test "monthly fires later same month" {
    const sch = MonthlySchedule{ .day_of_month = .{ .day = 20 }, .hour = 12, .minute = 0, .second = 0 };
    const from = ts(2026, 9, 1, 0, 0, 0);
    try testing.expectEqual(ts(2026, 9, 20, 12, 0, 0), sch.nextFireTime(from));
}

test "monthly at exact fire instant rolls to next month" {
    const sch = MonthlySchedule{ .day_of_month = .{ .day = 20 }, .hour = 12, .minute = 0, .second = 0 };
    const from = ts(2026, 9, 20, 12, 0, 0);
    try testing.expectEqual(ts(2026, 10, 20, 12, 0, 0), sch.nextFireTime(from));
}

test "monthly skips months without the target day" {
    // day 31 doesn't exist in April, so March 31 rolls forward to May 31,
    // skipping April entirely (not clamped to April 30).
    const sch = MonthlySchedule{ .day_of_month = .{ .day = 31 }, .hour = 0, .minute = 0, .second = 0 };
    const from = ts(2026, 3, 31, 0, 0, 0); // exact fire instant, March 31
    try testing.expectEqual(ts(2026, 5, 31, 0, 0, 0), sch.nextFireTime(from));
}

test "monthly skips a year boundary while searching for the target day" {
    // day 31: Dec has it, Jan has it, so Dec 31 -> Jan 31 next year.
    const sch = MonthlySchedule{ .day_of_month = .{ .day = 31 }, .hour = 0, .minute = 0, .second = 0 };
    const from = ts(2026, 12, 31, 0, 0, 0);
    try testing.expectEqual(ts(2027, 1, 31, 0, 0, 0), sch.nextFireTime(from));
}

test "monthly last_day tracks each month's actual length" {
    const sch = MonthlySchedule{ .day_of_month = .last_day, .hour = 0, .minute = 0, .second = 0 };

    // February 2026 (not a leap year) -> last day is the 28th.
    try testing.expectEqual(
        ts(2026, 2, 28, 0, 0, 0),
        sch.nextFireTime(ts(2026, 2, 1, 0, 0, 0)),
    );

    // April -> last day is the 30th, then rolls into May's last day (31st).
    try testing.expectEqual(
        ts(2026, 4, 30, 0, 0, 0),
        sch.nextFireTime(ts(2026, 4, 1, 0, 0, 0)),
    );
    try testing.expectEqual(
        ts(2026, 5, 31, 0, 0, 0),
        sch.nextFireTime(ts(2026, 4, 30, 0, 0, 0)),
    );
}

test "yearly fires later same year" {
    const sch = YearlySchedule{ .month = .jun, .day_of_month = .{ .day = 15 }, .hour = 0, .minute = 0, .second = 0 };
    const from = ts(2026, 1, 1, 0, 0, 0);
    try testing.expectEqual(ts(2026, 6, 15, 0, 0, 0), sch.nextFireTime(from));
}

test "yearly at exact fire instant rolls to next year" {
    const sch = YearlySchedule{ .month = .jun, .day_of_month = .{ .day = 15 }, .hour = 0, .minute = 0, .second = 0 };
    const from = ts(2026, 6, 15, 0, 0, 0);
    try testing.expectEqual(ts(2027, 6, 15, 0, 0, 0), sch.nextFireTime(from));
}

test "yearly on Feb 29 only fires on leap years" {
    const sch = YearlySchedule{ .month = .feb, .day_of_month = .{ .day = 29 }, .hour = 0, .minute = 0, .second = 0 };
    // 2026 is not a leap year; next Feb 29 is 2028.
    const from = ts(2026, 1, 1, 0, 0, 0);
    try testing.expectEqual(ts(2028, 2, 29, 0, 0, 0), sch.nextFireTime(from));
}

test "Schedule dispatcher forwards to the active variant" {
    const sch = Schedule{ .every_n_seconds = .{ .n = 5 } };
    try testing.expectEqual(@as(i64, 5), sch.nextFireTime(0));
}

test "yearly last_day on Feb tracks leap years" {
    const sch = YearlySchedule{ .month = .feb, .day_of_month = .last_day, .hour = 0, .minute = 0, .second = 0 };
    try testing.expectEqual(
        ts(2026, 2, 28, 0, 0, 0),
        sch.nextFireTime(ts(2026, 1, 1, 0, 0, 0)),
    );
    try testing.expectEqual(
        ts(2028, 2, 29, 0, 0, 0),
        sch.nextFireTime(ts(2028, 1, 1, 0, 0, 0)),
    );
}
