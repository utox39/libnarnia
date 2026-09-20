//! C ABI bindings for `libnarnia`.
//!
//! This layer exists to bridge three gaps between the Zig API and C:
//!
//! 1. **`std.Io` has no C representation.** A C caller has nothing to hand us,
//!    so `narnia_scheduler_new` owns a `std.Io.Threaded` event loop itself and
//!    keeps it next to the `Scheduler` behind one opaque handle. Job callbacks
//!    are therefore invoked on that pool's threads, never on the caller's.
//! 2. **`Scheduler.add` is generic over a comptime function.** It is
//!    instantiated exactly once here, with `trampoline` as the function and
//!    `.{ callback, user_data }` as the args tuple, which turns the whole
//!    generic machinery into the one `(fn, void*)` shape C wants.
//! 3. **`Schedule` is a Zig tagged union** with a nested union and `u5`/`u6`
//!    fields, none of which are C-ABI representable. `CSchedule` is a flat
//!    `extern struct` mirror; `toSchedule` converts and does the range
//!    validation that C's `uint8_t` doesn't give us for free.
//!
//! On top of that it adds a destroy-notify facility the Zig API doesn't have:
//! `Job.destroy_ctx` frees the *args tuple*, not the caller's `user_data`, so
//! `finalizers` maps job id -> (fn, user_data) and is drained on `remove` and
//! `destroy`.

const std = @import("std");
const narnia = @import("libnarnia");

const Scheduler = narnia.Scheduler;
const schedule_mod = narnia.schedule;
const Schedule = schedule_mod.Schedule;

/// Matches `NarniaError` in `include/narnia.h`.
const Error = enum(c_int) {
    ok = 0,
    out_of_memory = 1,
    invalid_schedule = 2,
    invalid_argument = 3,
};

/// Matches `NarniaScheduleTag` in `include/narnia.h`.
const Tag = enum(u8) {
    every_n_seconds = 0,
    every_n_minutes = 1,
    hourly = 2,
    daily = 3,
    weekly = 4,
    monthly = 5,
    yearly = 6,
    _,
};

/// Flat, C-ABI-representable mirror of `Schedule`. Only the fields relevant to
/// the active `tag` are read; the constructors below zero the rest. Field
/// order must stay in lockstep with `NarniaSchedule` in the header.
pub const CSchedule = extern struct {
    tag: u8,
    /// `every_n_seconds` / `every_n_minutes`.
    n: u64,
    /// `yearly`: 1-12.
    month: u8,
    /// `monthly` / `yearly`: 1-31, ignored when `last_day` is set.
    day: u8,
    /// `weekly`: 0 = Sunday .. 6 = Saturday.
    weekday: u8,
    hour: u8,
    minute: u8,
    second: u8,
    /// `monthly` / `yearly`: fire on the last calendar day of the month.
    last_day: bool,
};

const JobFn = *const fn (user_data: ?*anyopaque) callconv(.c) void;
const DestroyFn = *const fn (user_data: ?*anyopaque) callconv(.c) void;

/// The caller's `user_data` disposer, kept aside because the scheduler only
/// knows how to free the args tuple it allocated itself.
const Finalizer = struct {
    destroy: DestroyFn,
    user_data: ?*anyopaque,

    fn run(self: Finalizer) void {
        self.destroy(self.user_data);
    }
};

/// What a `NarniaScheduler*` really points at. Heap-allocated so that the
/// address stays stable: `Scheduler` holds the `std.Io` produced by
/// `threaded.io()`, which borrows `&threaded`.
const Handle = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    scheduler: Scheduler,
    finalizers: std.AutoHashMap(u64, Finalizer),
    /// Guards `finalizers`. `std.Io.Mutex` rather than `std.Thread.Mutex` for
    /// the same reason `Scheduler` uses one: parking the OS thread would stall
    /// a fiber-based `Io`.
    mutex: std.Io.Mutex = .init,

    fn lock(self: *Handle) void {
        self.mutex.lockUncancelable(self.scheduler.io);
    }

    fn unlock(self: *Handle) void {
        self.mutex.unlock(self.scheduler.io);
    }
};

/// The single instantiation of `Scheduler.add`'s comptime `function`
/// parameter. The scheduler heap-copies `.{ callback, user_data }` and frees
/// that copy through `Job.destroy_ctx`; `user_data` itself is the caller's,
/// and is disposed of through `Finalizer` instead.
fn trampoline(callback: JobFn, user_data: ?*anyopaque) void {
    callback(user_data);
}

fn hourMinuteSecond(cs: CSchedule) ?struct { u5, u6, u6 } {
    if (cs.hour > 23 or cs.minute > 59 or cs.second > 59) return null;
    return .{ @intCast(cs.hour), @intCast(cs.minute), @intCast(cs.second) };
}

fn dayOfMonth(cs: CSchedule) ?schedule_mod.DayOfMonth {
    if (cs.last_day) return .last_day;
    if (cs.day < 1 or cs.day > 31) return null;
    return .{ .day = @intCast(cs.day) };
}

/// Validates and converts. Returns `null` for any out-of-range field, which
/// the caller reports as `NARNIA_ERR_INVALID_SCHEDULE`.
fn toSchedule(cs: CSchedule) ?Schedule {
    const hms = hourMinuteSecond(cs) orelse return null;
    const hour, const minute, const second = hms;

    return switch (@as(Tag, @enumFromInt(cs.tag))) {
        .every_n_seconds => blk: {
            if (cs.n == 0 or cs.n > std.math.maxInt(usize)) break :blk null;
            break :blk .{ .every_n_seconds = .{ .n = @intCast(cs.n) } };
        },
        .every_n_minutes => blk: {
            if (cs.n == 0 or cs.n > std.math.maxInt(usize) / std.time.s_per_min) break :blk null;
            break :blk .{ .every_n_minutes = .{ .n = @intCast(cs.n) } };
        },
        .hourly => .{ .hourly = .{ .minutes = minute, .seconds = second } },
        .daily => .{ .daily = .{ .hour = hour, .minute = minute, .second = second } },
        .weekly => blk: {
            if (cs.weekday > 6) break :blk null;
            break :blk .{ .weekly = .{
                .day = @enumFromInt(@as(u3, @intCast(cs.weekday))),
                .hour = hour,
                .minute = minute,
                .second = second,
            } };
        },
        .monthly => blk: {
            const day = dayOfMonth(cs) orelse break :blk null;
            break :blk .{ .monthly = .{
                .day = day,
                .hour = hour,
                .minute = minute,
                .second = second,
            } };
        },
        .yearly => blk: {
            if (cs.month < 1 or cs.month > 12) break :blk null;
            const day = dayOfMonth(cs) orelse break :blk null;
            break :blk .{ .yearly = .{
                .month = @enumFromInt(@as(u4, @intCast(cs.month))),
                .day = day,
                .hour = hour,
                .minute = minute,
                .second = second,
            } };
        },
        _ => null,
    };
}

// ---------------------------------------------------------------------------
// Schedule constructors
// ---------------------------------------------------------------------------
//
// These only fill the struct; range validation happens in
// `narnia_scheduler_add`, since a by-value constructor has no way to report an
// error.

export fn narnia_every_n_seconds(n: u64) CSchedule {
    return .{
        .tag = @intFromEnum(Tag.every_n_seconds),
        .n = n,
        .month = 0,
        .day = 0,
        .weekday = 0,
        .hour = 0,
        .minute = 0,
        .second = 0,
        .last_day = false,
    };
}

export fn narnia_every_n_minutes(n: u64) CSchedule {
    var cs = narnia_every_n_seconds(n);
    cs.tag = @intFromEnum(Tag.every_n_minutes);
    return cs;
}

export fn narnia_hourly(minute: u8, second: u8) CSchedule {
    var cs = narnia_every_n_seconds(0);
    cs.tag = @intFromEnum(Tag.hourly);
    cs.minute = minute;
    cs.second = second;
    return cs;
}

export fn narnia_daily(hour: u8, minute: u8, second: u8) CSchedule {
    var cs = narnia_every_n_seconds(0);
    cs.tag = @intFromEnum(Tag.daily);
    cs.hour = hour;
    cs.minute = minute;
    cs.second = second;
    return cs;
}

export fn narnia_weekly(weekday: u8, hour: u8, minute: u8, second: u8) CSchedule {
    var cs = narnia_daily(hour, minute, second);
    cs.tag = @intFromEnum(Tag.weekly);
    cs.weekday = weekday;
    return cs;
}

/// `day` is 1-31; a month too short for it is skipped entirely, not clamped.
/// Pass `day = NARNIA_LAST_DAY` to fire on the last calendar day instead.
export fn narnia_monthly(day: u8, hour: u8, minute: u8, second: u8) CSchedule {
    var cs = narnia_daily(hour, minute, second);
    cs.tag = @intFromEnum(Tag.monthly);
    cs.day = day;
    cs.last_day = day == last_day_sentinel;
    return cs;
}

/// `month` is 1-12, `day` is 1-31 or `NARNIA_LAST_DAY`. A year where `day`
/// doesn't fall inside `month` (Feb 29 on a common year) is skipped.
export fn narnia_yearly(month: u8, day: u8, hour: u8, minute: u8, second: u8) CSchedule {
    var cs = narnia_monthly(day, hour, minute, second);
    cs.tag = @intFromEnum(Tag.yearly);
    cs.month = month;
    return cs;
}

/// Matches `NARNIA_LAST_DAY` in the header.
const last_day_sentinel: u8 = 0xFF;

// ---------------------------------------------------------------------------
// Scheduler lifecycle
// ---------------------------------------------------------------------------

/// Unix timestamp in seconds, UTC — the reference point
/// `narnia_scheduler_add` computes a job's first run from. Returns 0 for a
/// `NULL` handle.
///
/// It takes the scheduler because the clock is read through that scheduler's
/// `Io`, which is the same source its running jobs compare against.
export fn narnia_now(handle: ?*Handle) i64 {
    const self = handle orelse return 0;
    return std.Io.Timestamp.now(self.scheduler.io, .real).toSeconds();
}

export fn narnia_scheduler_new() ?*Handle {
    const gpa = std.heap.c_allocator;

    const handle = gpa.create(Handle) catch return null;
    handle.* = .{
        .gpa = gpa,
        .threaded = .init(gpa, .{}),
        // Patched immediately below: `threaded.io()` borrows `&handle.threaded`,
        // so it can only be taken once the struct sits at its final address.
        .scheduler = undefined,
        .finalizers = .init(gpa),
    };
    handle.scheduler = .init(handle.threaded.io(), gpa, .concurrent);
    return handle;
}

/// Cancels every job, waits for in-flight callbacks to drain, then releases
/// the scheduler, the event loop and the handle itself. Every registered
/// destroy-notify runs after the callbacks have stopped, so a disposer can
/// never race the callback using the same `user_data`.
///
/// Like the Zig `deinit`, this requires exclusive access: no other thread may
/// be inside any `narnia_scheduler_*` call.
export fn narnia_scheduler_destroy(handle: ?*Handle) void {
    const self = handle orelse return;

    self.scheduler.deinit();

    var it = self.finalizers.valueIterator();
    while (it.next()) |finalizer| finalizer.run();
    self.finalizers.deinit();

    self.threaded.deinit();
    self.gpa.destroy(self);
}

/// Registers a job and writes its id to `out_job_id` (may be `NULL`).
///
/// `name` may be `NULL`; it is copied. `destroy` may be `NULL`, otherwise it
/// is called with `user_data` once the job is removed or the scheduler is
/// destroyed. When `destroy` is `NULL`, `user_data` must outlive the job.
///
/// Nothing fires until `narnia_scheduler_start`.
export fn narnia_scheduler_add(
    handle: ?*Handle,
    c_schedule: CSchedule,
    name: ?[*:0]const u8,
    callback: ?JobFn,
    user_data: ?*anyopaque,
    destroy: ?DestroyFn,
    now: i64,
    out_job_id: ?*u64,
) Error {
    const self = handle orelse return .invalid_argument;
    const cb = callback orelse return .invalid_argument;
    const sched = toSchedule(c_schedule) orelse return .invalid_schedule;

    self.lock();
    defer self.unlock();

    // Reserved before the job exists so that recording the finalizer below
    // cannot fail after the job is already scheduled.
    if (destroy != null) {
        self.finalizers.ensureUnusedCapacity(1) catch return .out_of_memory;
    }

    const id = self.scheduler.add(
        sched,
        if (name) |n| std.mem.span(n) else null,
        trampoline,
        .{ cb, user_data },
        now,
    ) catch return .out_of_memory;

    if (destroy) |d| {
        self.finalizers.putAssumeCapacity(id, .{ .destroy = d, .user_data = user_data });
    }

    if (out_job_id) |out| out.* = id;
    return .ok;
}

/// Launches every registered job that isn't already running, then returns
/// immediately. Idempotent — call it again after adding jobs to pick them up.
export fn narnia_scheduler_start(handle: ?*Handle) Error {
    const self = handle orelse return .invalid_argument;
    self.scheduler.start() catch return .out_of_memory;
    return .ok;
}

/// Removes a job by id, returning `true` if it was found. Blocks until the
/// job's timer loop has stopped and its in-flight callbacks have finished,
/// then runs the job's destroy-notify, if any.
///
/// A job's callback must never remove its own job — it would wait on itself.
/// Removing a *different* job from inside a callback is fine.
export fn narnia_scheduler_remove(handle: ?*Handle, job_id: u64) bool {
    const self = handle orelse return false;

    // Taken out of the table before the blocking cancel below, so the lock is
    // never held while callbacks drain: a callback calling back into
    // `narnia_scheduler_add` would otherwise deadlock against us.
    self.lock();
    const finalizer = self.finalizers.fetchRemove(job_id);
    self.unlock();

    const removed = self.scheduler.remove(job_id);
    if (removed) {
        if (finalizer) |kv| kv.value.run();
    }
    return removed;
}

/// Stops every running job and wakes anything parked in `narnia_scheduler_wait`
/// without unregistering anything, so a later `narnia_scheduler_start`
/// relaunches them. Blocks until the jobs have actually stopped.
///
/// Requires exclusive access: it must not race an add or a remove.
export fn narnia_scheduler_stop(handle: ?*Handle) void {
    const self = handle orelse return;
    self.scheduler.stop();
}

/// Blocks until `narnia_scheduler_stop` (or `narnia_scheduler_destroy`) is
/// called from another thread. Jobs never finish on their own, so a shutdown
/// signal is the only thing that ends this. Returns immediately if a stop has
/// already happened.
export fn narnia_scheduler_wait(handle: ?*Handle) void {
    const self = handle orelse return;
    self.scheduler.wait();
}

/// Static, never-freed description of an error code.
export fn narnia_strerror(err: Error) [*:0]const u8 {
    return switch (err) {
        .ok => "ok",
        .out_of_memory => "out of memory",
        .invalid_schedule => "invalid schedule",
        .invalid_argument => "invalid argument",
    };
}

const testing = std.testing;

test "toSchedule accepts every constructor" {
    try testing.expect(toSchedule(narnia_every_n_seconds(15)) != null);
    try testing.expect(toSchedule(narnia_every_n_minutes(5)) != null);
    try testing.expect(toSchedule(narnia_hourly(30, 0)) != null);
    try testing.expect(toSchedule(narnia_daily(9, 0, 0)) != null);
    try testing.expect(toSchedule(narnia_weekly(1, 9, 0, 0)) != null);
    try testing.expect(toSchedule(narnia_monthly(1, 9, 0, 0)) != null);
    try testing.expect(toSchedule(narnia_monthly(last_day_sentinel, 9, 0, 0)) != null);
    try testing.expect(toSchedule(narnia_yearly(12, 25, 9, 0, 0)) != null);
    try testing.expect(toSchedule(narnia_yearly(2, last_day_sentinel, 0, 0, 0)) != null);
}

test "toSchedule rejects out-of-range fields C can express but Zig cannot" {
    try testing.expect(toSchedule(narnia_daily(24, 0, 0)) == null);
    try testing.expect(toSchedule(narnia_daily(0, 60, 0)) == null);
    try testing.expect(toSchedule(narnia_daily(0, 0, 60)) == null);
    try testing.expect(toSchedule(narnia_weekly(7, 0, 0, 0)) == null);
    try testing.expect(toSchedule(narnia_monthly(0, 0, 0, 0)) == null);
    try testing.expect(toSchedule(narnia_monthly(32, 0, 0, 0)) == null);
    try testing.expect(toSchedule(narnia_yearly(0, 1, 0, 0, 0)) == null);
    try testing.expect(toSchedule(narnia_yearly(13, 1, 0, 0, 0)) == null);
    // `n == 0` would trip the `assert(self.n > 0)` inside `nextFireTime`.
    try testing.expect(toSchedule(narnia_every_n_seconds(0)) == null);
    try testing.expect(toSchedule(narnia_every_n_minutes(0)) == null);
    // Unknown tag.
    var bogus = narnia_daily(0, 0, 0);
    bogus.tag = 99;
    try testing.expect(toSchedule(bogus) == null);
}

test "toSchedule maps fields onto the right variant" {
    const weekly = toSchedule(narnia_weekly(3, 17, 45, 30)).?;
    try testing.expectEqual(schedule_mod.WeekDay.WEDNESDAY, weekly.weekly.day);
    try testing.expectEqual(@as(u5, 17), weekly.weekly.hour);
    try testing.expectEqual(@as(u6, 45), weekly.weekly.minute);
    try testing.expectEqual(@as(u6, 30), weekly.weekly.second);

    const monthly = toSchedule(narnia_monthly(last_day_sentinel, 1, 2, 3)).?;
    try testing.expectEqual(schedule_mod.DayOfMonth.last_day, monthly.monthly.day);

    const yearly = toSchedule(narnia_yearly(12, 25, 0, 0, 0)).?;
    try testing.expectEqual(std.time.epoch.Month.dec, yearly.yearly.month);
    try testing.expectEqual(@as(u5, 25), yearly.yearly.day.day);
}

test "a job added through the C API fires and its destroy-notify runs" {
    const State = struct {
        var fired: std.atomic.Value(u32) = .init(0);
        var destroyed: std.atomic.Value(bool) = .init(false);

        fn callback(_: ?*anyopaque) callconv(.c) void {
            _ = fired.fetchAdd(1, .monotonic);
        }

        fn destroy(_: ?*anyopaque) callconv(.c) void {
            destroyed.store(true, .release);
        }
    };

    const handle = narnia_scheduler_new().?;
    defer narnia_scheduler_destroy(handle);

    var id: u64 = 0;
    try testing.expectEqual(Error.ok, narnia_scheduler_add(
        handle,
        narnia_every_n_seconds(1),
        "c api job",
        State.callback,
        null,
        State.destroy,
        narnia_now(handle),
        &id,
    ));
    try testing.expectEqual(@as(u64, 1), id);
    try testing.expectEqual(Error.ok, narnia_scheduler_start(handle));

    const io = handle.scheduler.io;
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);

    try testing.expect(State.fired.load(.monotonic) >= 1);

    // `remove` blocks until the job has stopped, so the disposer below cannot
    // race a callback still reading `user_data`.
    try testing.expect(narnia_scheduler_remove(handle, id));
    try testing.expect(State.destroyed.load(.acquire));
    try testing.expect(!narnia_scheduler_remove(handle, id));
}

test "add rejects bad arguments without registering anything" {
    const handle = narnia_scheduler_new().?;
    defer narnia_scheduler_destroy(handle);

    const noop = struct {
        fn f(_: ?*anyopaque) callconv(.c) void {}
    }.f;

    try testing.expectEqual(Error.invalid_argument, narnia_scheduler_add(handle, narnia_every_n_seconds(1), null, null, null, null, 0, null));
    try testing.expectEqual(Error.invalid_schedule, narnia_scheduler_add(handle, narnia_daily(24, 0, 0), null, noop, null, null, 0, null));
    try testing.expectEqual(Error.invalid_argument, narnia_scheduler_add(null, narnia_every_n_seconds(1), null, noop, null, null, 0, null));
    try testing.expectEqual(@as(usize, 0), handle.scheduler.count());
}
