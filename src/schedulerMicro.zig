const std = @import("std");
const Job = @import("Job.zig");
const Schedule = @import("schedule.zig").Schedule;

// TODO: (3) review all the code and tests

/// Returns `void`: a job that can fail has to handle its own failure.
pub const Callback = *const fn (ctx: ?*anyopaque) void;

/// Everything `start` needs from the hardware: a way to read the time, and a way
/// to wait. The caller needs to provide both.
///
/// Asking for these two functions is what keeps the scheduler free of any
/// dependency on a specific chip.
pub const Clock = struct {
    /// Returns the current time, in the same units `add` was given (see `add`).
    now: *const fn () i64,
    /// Blocks the caller for at least `seconds`.
    sleep: *const fn (seconds: i64) void,
};

/// A Scheduler designed for microcontrollers (and MicroZig).
///
/// `size` is the number of jobs the scheduler can hold.
///
/// `support_rtc` says whether the board can tell you the date. Without a real-time
/// clock it cannot, so the calendar schedules (`hourly`, `daily`, `weekly`,
/// `monthly`, `yearly`) are unavailable and `add` rejects them with
/// `error.UnsupportedSchedule`. Only `every_n_seconds` and `every_n_minutes`
/// remain, which need nothing but a counter. Turning it off also keeps the calendar
/// code out of the firmware.
pub fn SchedulerMicro(comptime size: usize, comptime support_rtc: bool) type {
    return struct {
        const Task = struct {
            id: u16,
            schedule: Schedule,
            name: ?[]const u8,
            callback: Callback,
            ctx: ?*anyopaque,
            next_run: i64,

            /// Advances `next_run` past every elapsed occurrence *without firing
            /// any of them*, per the scheduler's "missed occurrences are dropped,
            /// not replayed" rule.
            fn advancePast(self: *Task, now: i64) void {
                // `add` already refused anything unsupported.
                if (self.next_run <= now) self.next_run = nextFireTime(self.schedule, now) catch unreachable;
            }
        };

        /// Flat slot array: a free slot is `null`. Removal clears a slot rather than
        /// compacting, so slot indices stay stable for the lifetime of a job.
        slots: [size]?Task = @splat(null),
        next_id: u16 = 1,
        /// Set by `start`, cleared by `stop`. Single-threaded and only ever
        /// touched by `start` itself or by a callback it invoked, so it needs no
        /// lock and no atomic.
        running: bool = false,

        const Self = @This();

        pub const init: Self = .{};

        /// Like `Schedule.nextFireTime` but restricted to what this build supports:
        /// with `support_rtc = false` the calendar schedules answer
        /// `error.UnsupportedSchedule`, and their code is left out of the binary.
        fn nextFireTime(schedule: Schedule, from: i64) error{UnsupportedSchedule}!i64 {
            if (support_rtc) return schedule.nextFireTime(from);

            return switch (schedule) {
                .every_n_seconds => |ens| ens.nextFireTime(from),
                .every_n_minutes => |enm| enm.nextFireTime(from),
                else => error.UnsupportedSchedule,
            };
        }

        /// Registers a job and returns its id.
        ///
        /// `now` is the instant the job's schedule is phased from: `next_run` is the
        /// first occurrence strictly after it. It must come from the same clock that
        /// `start` will later read.
        ///
        /// Returns `error.UnsupportedSchedule` for a calendar schedule when this
        /// scheduler was built with `support_rtc = false`.
        pub fn add(
            self: *Self,
            schedule: Schedule,
            job_name: ?[]const u8,
            callback: Callback,
            ctx: ?*anyopaque,
            now: i64,
        ) error{ FullQueue, UnsupportedSchedule }!u16 {
            const next_run = try nextFireTime(schedule, now);

            const id = self.next_id;
            const task: Task = .{
                .id = id,
                .schedule = schedule,
                .name = job_name,
                .callback = callback,
                .ctx = ctx,
                .next_run = next_run,
            };

            for (&self.slots) |*slot| {
                if (slot.* != null) continue;
                slot.* = task;

                self.next_id += 1;
                return id;
            }

            return error.FullQueue;
        }

        /// Runs the jobs. **Blocks** until `stop` is called or the queue is empty.
        ///
        /// This is the timer loop itself. A slow callback delays every other job,
        /// and a job can never overlap itself.
        /// Nothing can be added while this runs except from inside a callback.
        pub fn start(self: *Self, clock: Clock) void {
            // Steps:
            //   1. drops every occurrence already elapsed
            //   2. waits for the earliest remaining `next_run`
            //   3. fires whatever that wait was for.

            self.running = true;

            while (self.running) {
                const now = clock.now();

                // Drops every occurrence already elapsed
                for (&self.slots) |*slot| {
                    if (slot.*) |*task| task.advancePast(now);
                }

                // The earliest `next_run` in the queue
                const deadline = self.peek() orelse return;

                clock.sleep(deadline - now);

                for (&self.slots) |*slot| {
                    if (slot.*) |*task| {
                        // After `advancePast`, every `next_run` is > `now`, so this
                        // selects exactly the jobs sharing the earliest deadline.
                        if (task.next_run > deadline) continue;

                        // Advance before firing, not after: the callback may remove
                        // this job or add another, and an early return or an error
                        // must not leave the slot sitting on a spent deadline.
                        // TODO: try to avoid `unreachable`
                        task.next_run = nextFireTime(task.schedule, task.next_run) catch unreachable;

                        const callback = task.callback;
                        const ctx = task.ctx;

                        callback(ctx);
                    }
                }
            }
        }

        /// Removes a job by id.
        /// Returns `true` if it was found and removed.
        ///
        /// Safe to call from a callback, including on its own job: `start` reads
        /// everything it needs out of the slot before invoking the callback, and
        /// never touches that slot again afterwards.
        pub fn remove(self: *Self, id: u16) bool {
            for (&self.slots) |*slot| {
                if (slot.*) |task| {
                    if (task.id != id) continue;
                    slot.* = null;
                    return true;
                }
            }
            return false;
        }

        /// Makes `start` return after the current pass. Intended to be called from
        /// a callback; `start` blocks, so there is no other caller on a
        /// single-threaded board. Jobs sharing the current deadline still fire.
        pub fn stop(self: *Self) void {
            self.running = false;
        }

        /// Returns the earliest `next_run` in the queue, or `null` if no jobs are
        /// scheduled.
        pub fn peek(self: *const Self) ?i64 {
            var earliest: ?i64 = null;
            for (self.slots) |slot| {
                if (slot) |task| {
                    // Thanks to short-circuit evaluation, if `earliest` is null, it is never accessed.
                    if (earliest == null or task.next_run < earliest.?) earliest = task.next_run;
                }
            }
            return earliest;
        }

        /// Returns the number of queued jobs.
        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (self.slots) |slot| {
                if (slot != null) n += 1;
            }
            return n;
        }
    };
}

// --- TESTS ---

const testing = std.testing;

fn noopCallback(_: ?*anyopaque) void {}

test "append a job" {
    var scheduler: SchedulerMicro(3, false) = .init;

    _ = try scheduler.add(
        .{ .every_n_seconds = .{ .n = 3 } },
        "test",
        noopCallback,
        null,
        1000,
    );

    try testing.expectEqual(1, scheduler.count());
    // every_n_seconds aligns to epoch multiples, so this is 1002.
    try testing.expectEqual(1002, scheduler.slots[0].?.next_run);
}

test "separate instances do not share storage" {
    var scheduler1: SchedulerMicro(3, false) = .init;
    var scheduler2: SchedulerMicro(3, false) = .init;

    _ = try scheduler1.add(.{ .every_n_seconds = .{ .n = 3 } }, "job 1", noopCallback, null, 0);

    try std.testing.expectEqual(1, scheduler1.count());
    try std.testing.expectEqual(0, scheduler2.count());
}

test "add past capacity reports QueueFull" {
    var scheduler: SchedulerMicro(2, false) = .init;
    const sch: Schedule = .{ .every_n_seconds = .{ .n = 1 } };

    const first = try scheduler.add(sch, null, noopCallback, null, 0);
    _ = try scheduler.add(sch, null, noopCallback, null, 0);

    try std.testing.expectError(
        error.FullQueue,
        scheduler.add(sch, null, noopCallback, null, 0),
    );

    try std.testing.expect(scheduler.remove(first));
    try std.testing.expectEqual(3, try scheduler.add(sch, null, noopCallback, null, 0));
}

/// Test clock. Time moves only when `sleep` moves it, so these tests exercise
/// `start`'s real timing logic without waiting on a real second.
const VirtualClock = struct {
    var current: i64 = 0;

    fn now() i64 {
        return current;
    }

    fn sleep(seconds: i64) void {
        current += seconds;
    }

    /// Resets the clock to `start_at` and returns the `Clock` to hand `start`.
    fn at(start_at: i64) Clock {
        current = start_at;
        return .{ .now = &now, .sleep = &sleep };
    }
};

test "start fires a job at each deadline until stopped" {
    const H = struct {
        var fired: [4]i64 = undefined;
        var count: usize = 0;

        fn record(ctx: ?*anyopaque) void {
            const scheduler: *SchedulerMicro(2, false) = @ptrCast(@alignCast(ctx.?));
            fired[count] = VirtualClock.current;
            count += 1;
            if (count == 3) scheduler.stop();
        }
    };

    var scheduler: SchedulerMicro(2, false) = .init;
    _ = try scheduler.add(
        .{ .every_n_seconds = .{ .n = 3 } },
        "tick",
        H.record,
        &scheduler,
        0,
    );

    scheduler.start(VirtualClock.at(0));

    try std.testing.expectEqual(3, H.count);
    try std.testing.expectEqualSlices(i64, &.{ 3, 6, 9 }, H.fired[0..3]);
}

test "occurrences missed before start are dropped, not replayed" {
    const H = struct {
        var fired: [4]i64 = undefined;
        var count: usize = 0;

        fn record(ctx: ?*anyopaque) void {
            const scheduler: *SchedulerMicro(2, false) = @ptrCast(@alignCast(ctx.?));
            fired[count] = VirtualClock.current;
            count += 1;
            scheduler.stop();
        }
    };

    var scheduler: SchedulerMicro(2, false) = .init;
    // It is registered as if it were at the epoch, so the first occurrence is at 3.
    _ = try scheduler.add(
        .{ .every_n_seconds = .{ .n = 3 } },
        "stale",
        H.record,
        &scheduler,
        0,
    );
    try std.testing.expectEqual(3, scheduler.slots[0].?.next_run);

    // The loop only gets going at 100: occurrences 3 through 99 elapsed
    // while nothing was running.
    scheduler.start(VirtualClock.at(100));

    try std.testing.expectEqual(1, H.count);
    // The next occurrence after 100 — not the 33 that were missed.
    try std.testing.expectEqual(102, H.fired[0]);
}

test "jobs sharing a deadline all fire on the same pass" {
    const H = struct {
        var a_fires: usize = 0;
        var b_fires: usize = 0;

        fn a(_: ?*anyopaque) void {
            a_fires += 1;
        }

        fn b(ctx: ?*anyopaque) void {
            const scheduler: *SchedulerMicro(3, false) = @ptrCast(@alignCast(ctx.?));
            b_fires += 1;
            scheduler.stop();
        }
    };

    var scheduler: SchedulerMicro(3, false) = .init;
    const sch: Schedule = .{ .every_n_seconds = .{ .n = 6 } };
    _ = try scheduler.add(sch, "job a", H.a, null, 0);
    _ = try scheduler.add(sch, "job b", H.b, &scheduler, 0);

    scheduler.start(VirtualClock.at(0));

    // `b` stops the loop, but it runs in the same sweep as `a`, so both fired.
    try std.testing.expectEqual(1, H.a_fires);
    try std.testing.expectEqual(1, H.b_fires);
}

test "remove frees the slot and reports whether the id existed" {
    var scheduler: SchedulerMicro(2, false) = .init;
    const sch: Schedule = .{ .every_n_seconds = .{ .n = 3 } };

    const id = try scheduler.add(sch, "gone", noopCallback, null, 0);
    _ = try scheduler.add(sch, "stays", noopCallback, null, 0);

    try std.testing.expect(scheduler.remove(id));
    try std.testing.expectEqual(1, scheduler.count());

    // Already gone, and an id that was never issued.
    try std.testing.expect(!scheduler.remove(id));
    try std.testing.expect(!scheduler.remove(9999));

    // The freed slot is reusable.
    _ = try scheduler.add(sch, "new", noopCallback, null, 0);
    try std.testing.expectEqual(2, scheduler.count());
}

test "a callback can remove its own job" {
    const H = struct {
        var fires: usize = 0;
        var id: u16 = 0;

        fn selfRemove(ctx: ?*anyopaque) void {
            const scheduler: *SchedulerMicro(2, false) = @ptrCast(@alignCast(ctx.?));
            fires += 1;
            _ = scheduler.remove(id);
        }
    };

    var scheduler: SchedulerMicro(2, false) = .init;
    H.id = try scheduler.add(
        .{ .every_n_seconds = .{ .n = 3 } },
        "once",
        H.selfRemove,
        &scheduler,
        0,
    );

    // No `stop` needed: the job unschedules itself, and `start` returns once the
    // queue is empty.
    scheduler.start(VirtualClock.at(0));

    try std.testing.expectEqual(1, H.fires);
    try std.testing.expectEqual(0, scheduler.count());
}

test "advancePast lands where stepping one occurrence at a time would" {
    const cases = [_]Schedule{
        .{ .every_n_seconds = .{ .n = 3 } },
        .{ .every_n_minutes = .{ .n = 7 } },
        .{ .hourly = .{ .minute = 30 } },
        .{ .daily = .{ .hour = 9, .minute = 15, .second = 0 } },
        .{ .weekly = .{ .week_day = .WEDNESDAY, .hour = 6, .minute = 0 } },
    };

    const started_at: i64 = 0;
    const now: i64 = 1_700_000_000;

    for (cases) |schedule| {
        // Calendar schedules included, so this needs the RTC build.
        var task: SchedulerMicro(1, true).Task = .{
            .id = 1,
            .schedule = schedule,
            .name = null,
            .callback = undefined,
            .ctx = null,
            .next_run = schedule.nextFireTime(started_at),
        };
        task.advancePast(now);

        // The same walk `Job.advancePast` does, one occurrence at a time.
        var stepped = schedule.nextFireTime(started_at);
        while (stepped <= now) stepped = schedule.nextFireTime(stepped);

        try std.testing.expectEqual(stepped, task.next_run);
        try std.testing.expect(task.next_run > now);
    }
}

test "without an RTC, calendar schedules are rejected" {
    var scheduler: SchedulerMicro(2, false) = .init;

    try std.testing.expectError(
        error.UnsupportedSchedule,
        scheduler.add(
            .{ .daily = .{ .hour = 9, .minute = 0, .second = 0 } },
            "daily",
            noopCallback,
            null,
            0,
        ),
    );

    // A rejected job leaves nothing behind: no slot, and no id burned.
    try std.testing.expectEqual(0, scheduler.count());
    try std.testing.expectEqual(1, try scheduler.add(
        .{ .every_n_seconds = .{ .n = 3 } },
        "ok",
        noopCallback,
        null,
        0,
    ));
}

test "with an RTC, calendar schedules are accepted" {
    var scheduler: SchedulerMicro(2, true) = .init;

    const sch: Schedule = .{ .daily = .{ .hour = 9, .minute = 0, .second = 0 } };
    _ = try scheduler.add(sch, "daily", noopCallback, null, 0);

    try std.testing.expectEqual(1, scheduler.count());
    try std.testing.expectEqual(sch.nextFireTime(0), scheduler.slots[0].?.next_run);
}

test "start returns when the queue is empty" {
    var scheduler: SchedulerMicro(2, false) = .init;

    // Nothing to wait for, and with no callbacks nothing can ever add a job.
    scheduler.start(VirtualClock.at(0));

    try std.testing.expectEqual(0, scheduler.count());
}
