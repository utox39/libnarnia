//! ## Thread safety
//!
//! Thread-safe methods: `add`, `remove`, `start`, `count`, `peek` and `wait`.
//! (`start` in `.min_heap` mode is not implemented at all — see its doc.)
//!
//! NOT thread-safe methods: `deinit` and `stop`.
//!
//! `deinit`: destroying a scheduler while other threads are still using it is
//! a use-after-free of the scheduler itself, which no internal lock can fix.
//!
//! `stop`: it has to cancel each job's `Future` with `mutex` released (canceling
//! blocks until that job's callbacks drain, and holding the lock across it
//! would deadlock against any callback calling back into the scheduler), so it
//! walks the queue unlocked and must not race an `add` or `remove`.
//!
//! ### Job callback must never remove its own job
//!
//! `remove` blocks until the job's task has stopped, which includes waiting
//! on the callback group the calling callback is running in (so the callback
//! would wait on itself).
//! This deadlocks with or without the lock; it is a consequence of the
//! cancelation protocol, not of the locking.
//!
//! Removing a *different* job from inside a callback is fine, as is `add`:
//! no scheduler lock is held while a callback runs. Note that a job added
//! from inside a callback stays dormant until the next `start()`, same as
//! one added from anywhere else.
//!
//! ### Job's callback can overlap with itself
//!
//! Each firing is dispatched fire-and-forget so that a slow callback never
//! delays the next occurrence, so a callback outlasting its own interval
//! will be running more than once at a time, every invocation sharing the
//! one copy of the args the job was registered with.
//! Callbacks holding mutable state must synchronize it themselves.

const std = @import("std");
const Job = @import("Job.zig");
const Schedule = @import("schedule.zig").Schedule;

/// Scheduler job execution modes.
pub const SchedulerMode = enum {
    /// Uses async I/O `concurrent` model.
    /// The jobs will run simultaneously.
    /// This scheduler mode is designed for a small quantity of scheduled jobs.
    /// It would not be scalable for many long-running jobs.
    concurrent,
    /// The scheduler will use a min_heap to select which job should run based
    /// on the next-fire-time
    min_heap,
};

/// An entry for `concurrent` mode: the running timer loop (`future`) plus the `Job`
/// it was handed. The `Job` is kept here because it owns the heap-allocated args
/// tuple behind `ctx`, which has to be freed when the job goes away.
const Task = struct {
    job: Job,
    /// If it is `null`, the job is not running: either it has never been
    /// started, or `stop` canceled it and reset this, leaving it awaiting
    /// relaunch by the next `start`.
    future: ?std.Io.Future(void) = null,

    /// Stops the timer loop, waits for the job's in-flight callbacks to
    /// finish, then releases its captured args. Canceling the `Future`
    /// is what bounds the callbacks: `runJob` cancels its own callback
    /// group on the way out, so by the time this returns, nothing can
    /// still be reading `job.ctx`.
    fn deinit(task: Task, io: std.Io, gpa: std.mem.Allocator) void {
        if (task.future) |f| {
            var future = f;
            _ = future.cancel(io);
        }
        task.job.deinit(gpa);
    }
};

const Queue = union(enum) {
    hash_map: std.AutoHashMap(u64, Task),
    min_heap: std.PriorityQueue(Job, void, Job.lessThanByNextRun),
};

const ShutdownControl = struct {
    shutting_down: bool = false,
    stopped: std.Io.Condition = .init,
};

/// A view of a queued job.
/// `Job` itself is deliberately *not* handed out, because its `ctx`
/// and `name` are owned by the scheduler.
pub const JobSnapshot = struct {
    id: u64,
    next_run: i64,
};

io: std.Io,
allocator: std.mem.Allocator,
next_id: u64 = 1,
mode: SchedulerMode,
queue: Queue,
mutex: std.Io.Mutex = .init,
shutdown_control: ShutdownControl = .{},
// TODO: add an on_error policy
// TODO: add SchedulerConfig (?)

const Self = @This();

pub fn init(io: std.Io, allocator: std.mem.Allocator, mode: SchedulerMode) Self {
    return .{
        .io = io,
        .allocator = allocator,
        .mode = mode,
        .queue = switch (mode) {
            .concurrent => .{ .hash_map = .init(allocator) },
            .min_heap => .{ .min_heap = .initContext({}) },
        },
    };
}

/// Cancels every running job and releases the queue. Requires exclusive
/// access (see the thread-safety note).
pub fn deinit(self: *Self) void {
    self.mutex.lockUncancelable(self.io);
    self.shutdown_control.shutting_down = true;
    self.shutdown_control.stopped.broadcast(self.io);
    self.mutex.unlock(self.io);

    switch (self.queue) {
        .hash_map => |*q| {
            var it = q.valueIterator();
            while (it.next()) |task| task.deinit(self.io, self.allocator);
            q.deinit();
        },
        .min_heap => |*q| {
            for (q.items) |job| job.deinit(self.allocator);
            q.deinit(self.allocator);
        },
    }
}

/// Number of currently scheduled jobs.
/// NOTE: A concurrent `add`/`remove` can make the answer stale the moment
/// it is returned.
pub fn count(self: *Self) usize {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    return switch (self.queue) {
        .hash_map => |*q| q.count(),
        .min_heap => |*q| q.count(),
    };
}

/// A snapshot of the next job to fire, if any. Only meaningful in `.min_heap`
/// mode, since `concurrent` mode has no shared ordering between jobs.
/// It always returns `null` in `concurrent` mode.
///
/// This is an observation for callers *outside* the scheduler, and like
/// `count` it may be stale as soon as it returns: the job it describes can be
/// removed, or overtaken by a sooner one, before the caller looks at it. So it
/// reports only `id` and `next_run`, never the `Job` itself, whose `ctx` and
/// `name` would dangle once that job is removed.
// NOTE: Internal `min_heap` code wanting the real entry should call the priority
// queue's own `peek` under `mutex` instead of going through here.
pub fn peek(self: *Self) ?JobSnapshot {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    return switch (self.queue) {
        .hash_map => null,
        .min_heap => |*q| if (q.peek()) |job| .{
            .id = job.id,
            .next_run = job.next_run,
        } else null,
    };
}

/// Registers a job and returns its id (usable later with `remove`).
/// `now` is the unix timestamp (seconds, UTC) to compute the job's first
/// `next_run` from.
///
/// This only records the job. Nothing fires until `start()` is called,
/// and a job added after a previous `start()` stays dormant until the
/// next one. Call `start()` again to pick it up (it is idempotent and
/// will not restart jobs already running).
///
/// NOTE: in `.min_heap` mode the job is queued but will never fire — that
/// mode has no run loop yet (see `start`).
///
/// NOTE: a job added while another thread is inside `start()` may land too
/// late for that call to see it, in which case it stays dormant until the
/// *next* `start()` call. Registering every job before the first `start()`
/// avoids the question entirely.
pub fn add(
    self: *Self,
    schedule: Schedule,
    job_name: ?[]const u8,
    comptime function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
    now: i64,
) !u64 {
    const Args = @TypeOf(args);

    // `function` and `Args` are comptime, so this struct's decls close over
    // both: `invoke` is the single type-erased entry point the job stores,
    // and `destroy` is the matching deallocator for the captured tuple.
    const Erased = struct {
        fn invoke(ctx: ?*anyopaque) anyerror!void {
            const args_ptr: *const Args = @ptrCast(@alignCast(ctx.?));
            const result = @call(.auto, function, args_ptr.*);
            // Accept `void`, `!void` and `!T` callbacks alike; a non-error
            // return value is simply discarded.
            if (@typeInfo(@TypeOf(result)) == .error_union) {
                _ = try result;
            }
        }

        fn destroy(gpa: std.mem.Allocator, ctx: ?*anyopaque) void {
            const args_ptr: *Args = @ptrCast(@alignCast(ctx.?));
            gpa.destroy(args_ptr);
        }
    };

    // The tuple has to outlive this call: the job fires long after `add`
    // returns, so it can't reference `args` on the caller's stack.
    // `Allocator.create` handles a zero-sized tuple (no-arg callbacks) by
    // returning a dangling-but-aligned pointer, which is safe to load from
    // since a zero-sized load reads nothing.
    // TODO: check if the args tuple is empty to prevent the allocation (?)
    const args_ptr = try self.allocator.create(Args);
    errdefer self.allocator.destroy(args_ptr);
    args_ptr.* = args;

    // Taken before `next_id` is read, so two concurrent `add`s can't be
    // handed the same id.
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    const id = self.next_id;

    const job: Job = try .init(
        self.allocator,
        id,
        job_name,
        schedule,
        schedule.nextFireTime(now),
        Erased.invoke,
        args_ptr,
        Erased.destroy,
    );
    errdefer if (job.name) |n| self.allocator.free(n);

    switch (self.queue) {
        .hash_map => |*q| {
            try q.put(id, .{ .job = job });
        },
        .min_heap => |*q| {
            try q.push(self.allocator, job);
            // TODO: implement
        },
    }

    self.next_id += 1;
    return id;
}

/// Removes a job by id.
/// Returns `true` if it was found and removed.
/// In `concurrent` mode, this cancels the job's `Future` and blocks
/// until its task has actually stopped (interrupting its `Io.sleep`
/// immediately rather than waiting out the remaining duration) *and* until
/// any callback it had already dispatched has finished.
pub fn remove(self: *Self, id: u64) bool {
    switch (self.queue) {
        .hash_map => |*q| {
            // The lock covers only the map mutation. `Task.deinit` (`kv.value.deinit`)
            // below cancels the job's `Future`, which blocks until its callbacks have drained
            // (as long as the slowest callback takes). Holding the mutex across that would stall
            // every other `add`/`remove`, and in the self-removal deadlock it would wedge the
            // whole scheduler instead of just the one job.
            // Unlocking early is safe because a removed entry is unreachable from the
            // map, so exactly one thread owns it here.
            self.mutex.lockUncancelable(self.io);
            const found = q.fetchRemove(id);
            self.mutex.unlock(self.io);

            const kv = found orelse return false;
            kv.value.deinit(self.io, self.allocator);
            return true;
        },
        .min_heap => |*q| {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            for (q.items, 0..) |job, idx| {
                if (job.id == id) {
                    _ = q.popIndex(idx);
                    job.deinit(self.allocator);
                    return true;
                }
            }
            return false;
        },
    }
}

/// Launches every registered job that isn't already running, then returns
/// immediately.
/// The jobs keep firing in the background until `stop` or `deinit`.
/// Use `remove` to delete a specific job.
///
/// This reconciles the runtime with the queue rather than starting it once,
/// so it is idempotent: jobs already launched are skipped, never restarted.
/// Call it again after any `add` to pick up the new jobs, and after an error
/// return to retry the ones that didn't get launched.
///
/// Only implemented for `.concurrent` mode: `.min_heap` has no run loop yet
/// and hits `unreachable` here.
//
// Also clears the shutdown flag raised by `stop`, so a stopped scheduler can
// be started again and `wait` parks rather than returning at once.
pub fn start(self: *Self) !void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);

    self.shutdown_control.shutting_down = false;

    switch (self.queue) {
        .hash_map => |*q| {
            var it = q.valueIterator();
            while (it.next()) |task| {
                // A non-null `future` means this job is already running.
                if (task.future == null) {
                    task.future = try std.Io.concurrent(self.io, runJob, .{ self.io, task.job });
                }
            }
        },
        .min_heap => unreachable,
    }
}

/// Blocks until `stop` (or `deinit`) raises the shutdown flag. Jobs never
/// finish on their own (`runJob` loops until canceled) so a shutdown signal
/// is the only thing that ends this.
///
/// The flag is re-checked on every wake, so a `stop` that happened *before*
/// this call returns immediately rather than parking on a broadcast that has
/// already gone out. While parked, the mutex is released, so `add`, `remove`,
/// `count` and `peek` keep working.
pub fn wait(self: *Self) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    while (!self.shutdown_control.shutting_down) {
        self.shutdown_control.stopped.waitUncancelable(self.io, &self.mutex);
    }
}

/// Stops every running job and wakes anything parked in `wait`, without
/// unregistering anything: the jobs stay in the queue with their args intact,
/// so a later `start()` relaunches them. Freeing is `deinit`'s job.
///
/// Like `remove`, this blocks until each job's task has actually stopped and
/// the callbacks it had already dispatched have finished.
///
/// Requires exclusive access, like `deinit` (see the thread-safety note).
/// Canceling under `mutex` would deadlock (a callback calling back into the
/// scheduler would wait on the lock its canceler holds) so the queue is
/// walked unlocked. That leaves no protection against a racing `add`
/// (rehashes the map mid-iteration) or `remove` (frees a `ctx` still in use).
pub fn stop(self: *Self) void {
    self.mutex.lockUncancelable(self.io);
    self.shutdown_control.shutting_down = true;
    self.shutdown_control.stopped.broadcast(self.io);
    self.mutex.unlock(self.io);

    switch (self.queue) {
        .hash_map => |*q| {
            var it = q.valueIterator();
            while (it.next()) |task| if (task.future) |f| {
                var future = f;
                _ = future.cancel(self.io);
                // Marks the job unlaunched so `start` relaunches it, and keeps
                // `deinit` from canceling the same `Future` a second time.
                task.future = null;
            };
        },
        // Nothing runs in this mode yet (`start` is unimplemented for it),
        // so there is nothing to cancel.
        .min_heap => {},
    }
}

/// One job's independent timer loop: run as a concurrent `Io` task. Sleeps
/// until `next_run`, fires the callback as a fire-and-forget task in
/// `group`, then recomputes `next_run` from the *previous* `next_run`
/// (not a fresh wall-clock read) and loops, which keeps the job on its
/// original phase rather than realigning it to when it was launched.
///
/// A job can be overdue on arrival (a stale `now` handed to `add`, a launch
/// long after it, a relaunch after `stop`) or fall behind a callback slower
/// than its own interval. Per the scheduler's design those occurrences are
/// dropped rather than caught up, which is what the loop-top guard does:
/// it advances past every elapsed `next_run` without firing it. Without the
/// guard the backlog would instead fire back-to-back on zero-length sleeps.
fn runJob(io: std.Io, job: Job) void {
    var next_run = job.next_run;

    // Each firing's callback is "fire-and-forget" in this job's *own* group,
    // living on this task's stack. That prevents a slow callback from delaying
    // the next occurrence, while still tying every callback's lifetime to
    // this task.
    var group: std.Io.Group = .init;
    // This `defer` cancels any still-running callback and blocks until
    // it has finished, so canceling this job's `Future` also
    // transitively drains its callbacks. Without that, `remove` could free
    // the job's `ctx` from under a callback still reading it.
    defer group.cancel(io);

    while (true) {
        const now = std.Io.Timestamp.now(io, .real).toSeconds();

        if (next_run <= now) {
            next_run = job.schedule.nextFireTime(next_run);
            continue;
        }

        // `next_run` is always strictly greater than `now` thanks to the check above
        const wait_seconds = next_run - now;
        std.Io.sleep(io, std.Io.Duration.fromSeconds(wait_seconds), .real) catch return;

        group.async(io, runCallback, .{ job.id, job.name, job.callback, job.ctx });

        next_run = job.schedule.nextFireTime(next_run);
    }
}

fn runCallback(id: u64, job_name: ?[]const u8, callback: *const fn (ctx: ?*anyopaque) anyerror!void, ctx: ?*anyopaque) void {
    callback(ctx) catch |err| {
        // A callback returning an error is handled. The job loop keeps going
        if (job_name) |jb| {
            std.log.warn("the callback of the job '{s}' with ID: {d} failed: {s}", .{ jb, id, @errorName(err) });
        } else {
            std.log.warn("the callback of the job with ID: {d} failed: {s}", .{ id, @errorName(err) });
        }
    };
}

// --- TESTS ---

const testing = std.testing;

fn noopCallback() void {}

fn incrementCounter(counter: *std.atomic.Value(u32)) void {
    _ = counter.fetchAdd(1, .monotonic);
}

fn failingCallback(counter: *std.atomic.Value(u32)) !void {
    _ = counter.fetchAdd(1, .monotonic);
    return error.DeliberateError;
}

/// Deliberately busy-waits instead of using `Io.sleep`: a spin loop has no
/// cancelation point, so the callback cannot be cut short. That's what makes
/// "did `remove` wait for me?" observable.
const SlowState = struct {
    io: std.Io,
    started: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),

    fn callback(state: *SlowState) void {
        state.started.store(true, .release);
        const start_time = std.Io.Timestamp.now(state.io, .awake);
        while (start_time.untilNow(state.io, .awake).toMilliseconds() < 300) {
            std.atomic.spinLoopHint();
        }
        state.finished.store(true, .release);
    }
};

fn testIo() std.Io.Threaded {
    return std.Io.Threaded.init(testing.allocator, .{});
}

test "add returns increasing ids" {
    var threaded = testIo();
    defer threaded.deinit();

    var scheduler = Self.init(threaded.io(), testing.allocator, .min_heap);
    defer scheduler.deinit();

    const id1 = try scheduler.add(.{ .every_n_seconds = .{ .n = 60 } }, null, noopCallback, .{}, 0);
    const id2 = try scheduler.add(.{ .every_n_seconds = .{ .n = 60 } }, null, noopCallback, .{}, 0);

    try testing.expectEqual(@as(u64, 1), id1);
    try testing.expectEqual(@as(u64, 2), id2);
    try testing.expectEqual(@as(usize, 2), scheduler.count());
}

test "add computes next_run from the given `now`" {
    var threaded = testIo();
    defer threaded.deinit();

    var scheduler = Self.init(threaded.io(), testing.allocator, .min_heap);
    defer scheduler.deinit();

    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 15 } }, null, noopCallback, .{}, 10);

    const job = scheduler.peek().?;
    try testing.expectEqual(@as(i64, 15), job.next_run);
}

test "queue peek always returns the earliest-firing job" {
    var threaded = testIo();
    defer threaded.deinit();

    var scheduler = Self.init(threaded.io(), testing.allocator, .min_heap);
    defer scheduler.deinit();

    // Fires at 3600 (from = 0)
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 3600 } }, null, noopCallback, .{}, 0);
    // Fires at 60 (from = 0) - earliest
    const soonest_id = try scheduler.add(.{ .every_n_seconds = .{ .n = 60 } }, null, noopCallback, .{}, 0);
    // Fires at 1800 (from = 0)
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 1800 } }, null, noopCallback, .{}, 0);

    const soonest = scheduler.peek().?;
    try testing.expectEqual(soonest_id, soonest.id);
    try testing.expectEqual(@as(i64, 60), soonest.next_run);
}

test "remove deletes a job by id and reports success" {
    var threaded = testIo();
    defer threaded.deinit();

    var scheduler = Self.init(threaded.io(), testing.allocator, .min_heap);
    defer scheduler.deinit();

    const id = try scheduler.add(.{ .every_n_seconds = .{ .n = 60 } }, null, noopCallback, .{}, 0);

    try testing.expect(scheduler.remove(id));
    try testing.expectEqual(@as(usize, 0), scheduler.count());
    try testing.expect(!scheduler.remove(id)); // already removed
}

test "min_heap: remove on unknown id returns false" {
    var threaded = testIo();
    defer threaded.deinit();

    var scheduler = Self.init(threaded.io(), testing.allocator, .min_heap);
    defer scheduler.deinit();

    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 60 } }, null, noopCallback, .{}, 0);

    try testing.expect(!scheduler.remove(999));
    try testing.expectEqual(@as(usize, 1), scheduler.count());
}

test "removing the peeked job exposes the next earliest job" {
    var threaded = testIo();
    defer threaded.deinit();

    var scheduler = Self.init(threaded.io(), testing.allocator, .min_heap);
    defer scheduler.deinit();

    const soonest_id = try scheduler.add(.{ .every_n_seconds = .{ .n = 60 } }, null, noopCallback, .{}, 0);
    const later_id = try scheduler.add(.{ .every_n_seconds = .{ .n = 3600 } }, null, noopCallback, .{}, 0);

    try testing.expect(scheduler.remove(soonest_id));

    const next = scheduler.peek().?;
    try testing.expectEqual(later_id, next.id);
}

test "concurrent: add stores jobs and count reflects them" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .concurrent);
    defer scheduler.deinit();

    // Far in the future so these jobs stay parked in their initial sleep
    // for the lifetime of this test.
    const now = std.Io.Timestamp.now(io, .real).toSeconds();

    const id1 = try scheduler.add(.{ .every_n_seconds = .{ .n = 3600 } }, null, noopCallback, .{}, now);
    const id2 = try scheduler.add(.{ .every_n_seconds = .{ .n = 3600 } }, null, noopCallback, .{}, now);

    try testing.expectEqual(@as(u64, 1), id1);
    try testing.expectEqual(@as(u64, 2), id2);
    try testing.expectEqual(@as(usize, 2), scheduler.count());
    try testing.expectEqual(@as(?JobSnapshot, null), scheduler.peek()); // no shared ordering in this mode
}

test "concurrent: remove cancels and deletes by id" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .concurrent);
    defer scheduler.deinit();

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const id = try scheduler.add(.{ .every_n_seconds = .{ .n = 3600 } }, null, noopCallback, .{}, now);

    try testing.expect(scheduler.remove(id));
    try testing.expectEqual(@as(usize, 0), scheduler.count());
    try testing.expect(!scheduler.remove(id)); // already removed
    try testing.expect(!scheduler.remove(999)); // unknown id
}

test "concurrent: a scheduled job actually fires its callback" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .concurrent);
    defer scheduler.deinit();

    var counter = std.atomic.Value(u32).init(0);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, null, incrementCounter, .{&counter}, now);

    try scheduler.start();

    // Real wall-clock wait: give the job at least one full second-boundary
    // to fire on. `scheduler.deinit()` (deferred above) then cancels the
    // job's Future and blocks until its loop has actually stopped, so it's
    // safe for `counter` to go out of scope right after this test returns.
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);

    try testing.expect(counter.load(.monotonic) >= 1);
}

test "concurrent: a failing callback is logged but doesn't stop the job" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .concurrent);
    defer scheduler.deinit();

    var counter = std.atomic.Value(u32).init(0);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, "failing job", failingCallback, .{&counter}, now);

    try scheduler.start();

    // Every firing returns an error; the job loop must keep going anyway,
    // so the counter should still climb past a single firing.
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(3), .real);

    try testing.expect(counter.load(.monotonic) >= 2);
}

test "concurrent: remove waits for an in-flight callback before freeing its args" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .concurrent);
    defer scheduler.deinit();

    var state = SlowState{ .io = io };

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const id = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, null, SlowState.callback, .{&state}, now);

    try scheduler.start();

    // Wait for the callback to be mid-flight, so `remove` below races it.
    while (!state.started.load(.acquire)) {
        try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(10), .real);
    }

    try testing.expect(scheduler.remove(id));

    // `remove` cancels the job's `Future`, which makes `runJob` cancel its
    // own callback group and block until the spinning callback returns. So
    // by the time `remove` returns, the callback is provably done — it
    // cannot still be reading the args tuple `remove` just freed.
    try testing.expect(state.finished.load(.acquire));
}

test "concurrent: stop before wait does not block" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .concurrent);
    defer scheduler.deinit();

    // `stop` before `wait`: the shutdown flag is already set, so `wait` must
    // observe it and return instead of parking forever on a broadcast that
    // has already happened.
    scheduler.stop();
    scheduler.wait();
}

test "concurrent: stop halts firing but keeps jobs, and start relaunches them" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .concurrent);
    defer scheduler.deinit();

    var counter = std.atomic.Value(u32).init(0);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, null, incrementCounter, .{&counter}, now);

    try scheduler.start();
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);

    scheduler.stop();
    const count_at_stop = counter.load(.monotonic);
    try testing.expect(count_at_stop >= 1);

    // `stop` blocks until the tasks have actually stopped, so nothing may
    // fire afterwards — but the job itself stays registered.
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);
    try testing.expectEqual(count_at_stop, counter.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), scheduler.count());

    // `stop` cleared `future`, so the job is relaunchable rather than being
    // skipped as "already running".
    try scheduler.start();
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);
    try testing.expect(counter.load(.monotonic) > count_at_stop);
}

test "concurrent: removed job stops firing" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .concurrent);
    defer scheduler.deinit();

    var counter = std.atomic.Value(u32).init(0);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const id = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, null, incrementCounter, .{&counter}, now);

    try scheduler.start();

    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);
    try testing.expect(scheduler.remove(id));

    const count_at_removal = counter.load(.monotonic);
    try testing.expect(count_at_removal >= 1);

    // `remove` already blocked until the job's task fully stopped, so no
    // more firings should be possible even after waiting further.
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);
    try testing.expectEqual(count_at_removal, counter.load(.monotonic));
}
