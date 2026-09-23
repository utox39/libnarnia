//! ## Thread safety
//!
//! Thread-safe methods: `add`, `remove`, `start`, `count`, `peek` and `wait`.
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
//! no scheduler lock is held while a callback runs. A job added from inside a
//! callback starts firing on its own, same as one added from anywhere else.
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
    /// on the next-fire-time.
    ///
    /// One shared loop drives every job, so N jobs cost a single task rather
    /// than N of them: this is the mode to reach for with many jobs.
    ///
    /// Firing semantics are otherwise identical to `concurrent`: callbacks are
    /// dispatched fire-and-forget so a slow one never delays the next
    /// occurrence, and missed occurrences are dropped rather than replayed.
    // TODO: rename to something more meaningful
    min_heap,
};

/// An entry for `concurrent` mode: the running timer loop (`future`) plus the `Job`
/// it was handed. The `Job` is kept here because it owns the heap-allocated args
/// tuple behind `ctx`, which has to be freed when the job goes away.
const ConcurrentTask = struct {
    job: Job,
    /// If it is `null`, the job is not running: either it has never been
    /// started, or `stop` canceled it and reset this, leaving it awaiting
    /// relaunch by the next `start`.
    future: ?std.Io.Future(void) = null,

    fn init(job: Job, future: ?std.Io.Future(void)) ConcurrentTask {
        return .{
            .job = job,
            .future = future,
        };
    }

    /// Stops the timer loop, waits for the job's in-flight callbacks to
    /// finish, then releases its captured args. Canceling the `Future`
    /// is what bounds the callbacks: `runJob` cancels its own callback
    /// group on the way out, so by the time this returns, nothing can
    /// still be reading `job.ctx`.
    fn deinit(task: ConcurrentTask, io: std.Io, gpa: std.mem.Allocator) void {
        if (task.future) |f| {
            var future = f;
            _ = future.cancel(io);
        }
        task.job.deinit(gpa);
    }
};

/// An entry for `min_heap` mode: the counterpart to `Task`, but for the shared
/// run loop. There is no per-job `Future` (one loop drives every job), and in
/// its place a per-job callback `Group`, which is what lets `remove` drain
/// exactly this job's callbacks the way canceling a `Future` does in
/// `concurrent` mode.
const MinHeapTask = struct {
    job: Job,
    /// Heap-allocated rather than held by value: `PriorityQueue` memmoves its
    /// elements while sifting, and the `Io` implementation keeps the pointer it
    /// was handed in `Group.concurrent`.
    group: *std.Io.Group,

    fn init(job: Job, group: *std.Io.Group) MinHeapTask {
        return .{
            .job = job,
            .group = group,
        };
    }

    /// Orders entries by `next_run` so the earliest-firing job sorts first,
    /// making `std.PriorityQueue` a min-heap over fire time.
    fn lessThanByNextRun(_: void, a: MinHeapTask, b: MinHeapTask) std.math.Order {
        return std.math.order(a.job.next_run, b.job.next_run);
    }

    /// Waits for the job's in-flight callbacks to finish, then releases its
    /// captured args. Mirrors `Task.deinit`; the caller must already have made
    /// this entry unreachable from the heap, so that nothing can dispatch into
    /// `group` while it is being drained.
    fn deinit(task: MinHeapTask, io: std.Io, gpa: std.mem.Allocator) void {
        task.group.cancel(io);
        task.job.deinit(gpa);
        gpa.destroy(task.group);
    }
};

/// The `min_heap` queue plus the state of the single run loop that drives it.
///
/// Heap-allocated and self-contained, and that is the point: `runQueue` holds a
/// `*MinHeap` rather than a `*Scheduler`, so the scheduler value itself stays
/// free to be moved or copied after `start()`. Everything the loop needs lives
/// here, including its own `mutex` — reaching back into the scheduler for one
/// would reintroduce exactly the pointer this design exists to avoid.
const MinHeap = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    /// Guards `heap`, `wakeup` and `loop_future`. Distinct from
    /// `Scheduler.mutex`, which guards the `hash_map` queue and the shutdown
    /// flag; a scheduler only ever uses one of the two, since its mode is fixed
    /// at `init`.
    mutex: std.Io.Mutex = .init,
    min_heap: std.PriorityQueue(MinHeapTask, void, MinHeapTask.lessThanByNextRun),
    /// Wakes the run loop when the heap changes under it: `add` may have queued
    /// a job sooner than the one the loop is sleeping on, and `remove` may have
    /// taken the root away (the root being the minimum element under
    /// `lessThanByNextRun`, i.e. the next job to fire).
    ///
    /// An `Event` rather than a `Condition` for two reasons: the loop has to
    /// sleep *until a deadline* while staying wakeable, which only
    /// `Event.waitTimeout` offers, and an `Event` remembers a `set` that no one
    /// was parked for, which is what keeps a wakeup from being lost.
    wakeup: std.Io.Event = .unset,
    /// Non-null while the run loop is live. `null` means it has never been
    /// started, or `stop` canceled it and reset this — the same protocol as
    /// `Task.future`.
    loop_future: ?std.Io.Future(void) = null,

    fn create(io: std.Io, gpa: std.mem.Allocator) !*MinHeap {
        const mh = try gpa.create(MinHeap);
        mh.* = .{ .io = io, .allocator = gpa, .min_heap = .initContext({}) };
        return mh;
    }

    /// Drains every root that has come due, firing it once (`fire`) or skipping it,
    /// then advancing it past `now` and reinserting it. On return nothing in the
    /// heap has a `next_run` at or before `now`, so the root is always a deadline
    /// the loop can actually sleep on. ("Root" = the heap's minimum under
    /// `lessThanByNextRun`, i.e. the next job to fire.)
    ///
    /// `fire = false` is the reconciliation `start` and `add` use to drop a stale
    /// job's backlog; `fire = true` is the run loop's own dispatch step. Sharing
    /// one path is what keeps this mode's firing semantics identical to
    /// `concurrent` mode's.
    ///
    /// Terminates because a reinserted entry is strictly later than `now` and so
    /// can never be selected again by this loop.
    ///
    /// The caller must hold `mh.mutex`.
    fn advanceStaleRoots(self: *MinHeap, now: i64, comptime fire: bool) void {
        while (self.min_heap.peek()) |root| {
            if (root.job.next_run > now) break;

            var task = self.min_heap.pop().?;
            if (fire) {
                // `Group.concurrent`, not `Group.async`: the strong variant never
                // runs the callback inline on this thread, which is what makes it
                // safe to dispatch while holding `mutex`. A callback calling back
                // into the scheduler then blocks on another thread until the loop
                // releases the lock, instead of deadlocking against itself here.
                // Dispatching under the lock is in turn what stops `remove` from
                // popping this entry — and freeing its `ctx` — mid-dispatch.
                task.group.concurrent(self.io, runCallback, .{
                    task.job.id,
                    task.job.name,
                    task.job.callback,
                    task.job.ctx,
                }) catch |err| {
                    // No unit of concurrency to be had. Drop this occurrence and
                    // keep the job, the same way a failing callback is logged
                    // without stopping its job.
                    if (task.job.name) |jb| {
                        std.log.warn("could not dispatch the job '{s}' with ID: {d}: {s}", .{ jb, task.job.id, @errorName(err) });
                    } else {
                        std.log.warn("could not dispatch the job with ID: {d}: {s}", .{ task.job.id, @errorName(err) });
                    }
                };
            }

            task.job.advancePast(now);
            // Cannot allocate, and so cannot fail: the `pop` above left the
            // capacity for this element in place.
            self.min_heap.push(self.allocator, task) catch unreachable;
        }
    }

    /// The single timer loop shared by every job in `min_heap` mode, run as a
    /// concurrent `Io` task. Each cycle fires whatever has come due, then sleeps
    /// until the earliest `next_run` left in the heap — or until `wakeup` says the
    /// heap changed under it.
    ///
    /// It has to re-read the queue every cycle to see `add`s and `remove`s, so it
    /// takes the heap-allocated `MinHeap` block rather than the scheduler: the
    /// block's address is stable no matter what happens to the scheduler value.
    fn runMinHeap(mh: *MinHeap) void {
        while (true) {
            mh.mutex.lockUncancelable(mh.io);

            // Reset *before* reading the heap. Any `add` or `remove` that signals
            // after this point is then guaranteed to be observed by the wait below
            // rather than slept through, because both signal while holding the
            // mutex this cycle still owns.
            mh.wakeup.reset();

            const now = std.Io.Timestamp.now(mh.io, .real).toSeconds();
            mh.advanceStaleRoots(now, true);
            const deadline: ?i64 = if (mh.min_heap.peek()) |task| task.job.next_run else null;

            mh.mutex.unlock(mh.io);

            if (deadline) |d| {
                // Strictly greater than `now`: `advanceStaleRoots` guarantees it.
                const wait_seconds = d - now;
                mh.wakeup.waitTimeout(mh.io, .{ .duration = .{
                    .raw = std.Io.Duration.fromSeconds(wait_seconds),
                    .clock = .real,
                } }) catch |err| switch (err) {
                    // The deadline arrived, or the wake was spurious. Either way
                    // the next cycle re-reads the clock and does the right thing.
                    error.Timeout => {},
                    // `stop` or `deinit` canceled this task.
                    error.Canceled => return,
                };
            } else {
                // Nothing queued: park until an `add` signals, or the loop is
                // canceled. Both waits are cancelation points, so a sleeping loop
                // is interrupted immediately rather than waiting out its deadline.
                mh.wakeup.wait(mh.io) catch return;
            }
        }
    }
};

const Queue = union(enum) {
    hash_map: std.AutoHashMap(u64, ConcurrentTask),
    /// `null` until the first `add` or `start` allocates the block.
    min_heap: ?*MinHeap,
};

const ShutdownControl = struct {
    shutting_down: bool = false,
    stopped: std.Io.Condition = .init,
};

/// Signals `runConcurrentPendingJobs` that the `concurrent` queue changed.
/// `pending` says only *that* it changed, not what: the launcher rescans for
/// every task still missing a `Future`, so one flag covers any number of
/// `add`s.
///
/// A `Condition` suffices, unlike `MinHeap.wakeup`, because the wait carries no
/// deadline and `pending` is re-checked under `mutex`, so no wakeup is lost.
const AddControl = struct {
    pending: bool = false,
    added: std.Io.Condition = .init,
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
next_id: std.atomic.Value(u64) = .init(1),
mode: SchedulerMode,
queue: Queue,
/// Guards the `hash_map` queue and `shutdown_control`.
/// The `min_heap` queue has its own lock inside `MinHeap`.
mutex: std.Io.Mutex = .init,
shutdown_control: ShutdownControl = .{},
add_control: AddControl = .{},
/// The task that launches jobs added while the scheduler is running, in
/// `concurrent` mode. Non-null between `start` and `stop`.
concurrent_launcher_future: ?std.Io.Future(void) = null,
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
            // Allocated on first use
            .min_heap => .{ .min_heap = null },
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

    // The launcher must stop before the queue is torn down, or it can spawn a
    // task into a map that is being freed.
    self.stopConcurrentLauncher();

    switch (self.queue) {
        .hash_map => |*q| {
            var it = q.valueIterator();
            while (it.next()) |task| task.deinit(self.io, self.allocator);
            q.deinit();
        },
        .min_heap => |maybe_mh| {
            const mh = maybe_mh orelse return;
            // The loop (MinHeap.runMinHeap) has to die before the groups it dispatches into are
            // drained, so cancel it first.
            if (mh.loop_future) |f| {
                var future = f;
                _ = future.cancel(self.io);
                mh.loop_future = null;
            }
            for (mh.min_heap.items) |task| task.deinit(self.io, self.allocator);
            mh.min_heap.deinit(self.allocator);
            self.allocator.destroy(mh);
        },
    }
}

/// Cancels the `concurrent` launcher and marks it relaunchable, if it is
/// running. Must be called with `mutex` released: canceling blocks until the
/// task has stopped, and it stops while holding the lock.
fn stopConcurrentLauncher(self: *Self) void {
    if (self.concurrent_launcher_future) |f| {
        var future = f;
        _ = future.cancel(self.io);
        self.concurrent_launcher_future = null;
    }
}

/// Number of currently scheduled jobs.
/// NOTE: A concurrent `add`/`remove` can make the answer stale the moment
/// it is returned.
pub fn count(self: *Self) usize {
    switch (self.queue) {
        .hash_map => |*q| {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            return q.count();
        },
        .min_heap => |maybe_mh| {
            const mh = maybe_mh orelse return 0;
            mh.mutex.lockUncancelable(mh.io);
            defer mh.mutex.unlock(mh.io);
            return mh.min_heap.count();
        },
    }
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
    switch (self.queue) {
        .hash_map => return null,
        .min_heap => |maybe_mh| {
            const mh = maybe_mh orelse return null;
            mh.mutex.lockUncancelable(mh.io);
            defer mh.mutex.unlock(mh.io);
            return if (mh.min_heap.peek()) |task| .{
                .id = task.job.id,
                .next_run = task.job.next_run,
            } else null;
        },
    }
}

/// Registers a job and returns its id (usable later with `remove`).
/// `now` is the unix timestamp (seconds, UTC) to compute the job's first
/// `next_run` from.
///
/// This only records the job; nothing fires until `start()` is called.
/// A job added to an already-running scheduler needs no second `start()`.
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

    // Claimed atomically, so two concurrent `add`s can't be handed the same id
    // even though the two modes go on to take different locks.
    const id = self.next_id.fetchAdd(1, .monotonic);

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
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            try q.put(id, ConcurrentTask.init(job, null));

            // Signal the queue change. If the launcher is running it wakes and
            // launches this job; if it isn't, the flag simply stays raised and
            // the next `start()` sweeps the job up anyway.
            self.add_control.pending = true;
            self.add_control.added.broadcast(self.io);
        },
        .min_heap => |*maybe_mh| {
            if (maybe_mh.* == null) maybe_mh.* = try MinHeap.create(self.io, self.allocator);
            const mh = maybe_mh.*.?;

            mh.mutex.lockUncancelable(mh.io);
            defer mh.mutex.unlock(mh.io);

            const group = try self.allocator.create(std.Io.Group);
            errdefer self.allocator.destroy(group);
            group.* = .init;

            var task: MinHeapTask = .init(job, group);
            // A job handed a stale `now` while the loop is already running
            // would otherwise fire its whole backlog back-to-back on the shared
            // loop, starving every other job. `now` still sets the job's phase
            // — this only drops the occurrences that are already past, exactly
            // as `start` does for a job that was queued before the loop began.
            if (mh.loop_future != null) {
                task.job.advancePast(std.Io.Timestamp.now(mh.io, .real).toSeconds());
            }
            try mh.min_heap.push(mh.allocator, task);

            // The new job may be sooner than the one the loop is sleeping on.
            // Signaling under the lock pairs with the loop's `reset`, which it
            // does before reading the heap, so this can never be slept through.
            mh.wakeup.set(mh.io);
        },
    }

    return id;
}

/// Removes a job by id.
/// Returns `true` if it was found and removed.
/// In `concurrent` mode, this cancels the job's `Future` and blocks
/// until its task has actually stopped (interrupting its `Io.sleep`
/// immediately rather than waiting out the remaining duration) *and* until
/// any callback it had already dispatched has finished.
///
/// The `min_heap` mode provides the same guarantee through a different approach.
/// There is no per-job task to cancel. Instead, each job owns its own callback group.
/// Canceling that group drains only this job's in-flight callbacks before its arguments
/// are freed.
pub fn remove(self: *Self, id: u64) bool {
    switch (self.queue) {
        .hash_map => |*q| {
            // The lock covers only the map mutation. `ConcurrentTask.deinit` (`kv.value.deinit`)
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
        .min_heap => |maybe_mh| {
            const mh = maybe_mh orelse return false;

            // As in the `hash_map` branch, the lock covers only the queue
            // mutation. `HeapTask.deinit` below blocks until this job's
            // callbacks have drained, and holding the mutex across that would
            // stall every other `add`/`remove` — and, for a job removing
            // itself, wedge the whole scheduler rather than just the one job.
            mh.mutex.lockUncancelable(mh.io);
            var found: ?MinHeapTask = null;
            for (mh.min_heap.items, 0..) |task, idx| {
                if (task.job.id == id) {
                    found = mh.min_heap.popIndex(idx);
                    // The root may have just vanished, so the loop's current
                    // deadline can be later than it should be.
                    mh.wakeup.set(mh.io);
                    break;
                }
            }
            mh.mutex.unlock(mh.io);

            const task = found orelse return false;
            task.deinit(mh.io, mh.allocator);
            return true;
        },
    }
}

/// Launches every registered job that isn't already running, then returns
/// immediately.
/// The jobs keep firing in the background until `stop` or `deinit`.
/// Use `remove` to delete a specific job.
///
/// This reconciles the runtime with the queue rather than starting it once, so
/// it is idempotent: jobs already launched are skipped, never restarted. Call
/// it again after an error return to retry whatever didn't get launched.
///
/// Both modes pick up a job added *after* this call on their own, so a second
/// `start()` is never needed for that: `.concurrent` leaves a launcher task
/// watching for new jobs, and `.min_heap` runs one shared loop that re-reads
/// the queue each cycle.
///
/// In `.min_heap`, jobs left overdue by a previous `stop` — or queued with a
/// stale `now` — have their elapsed occurrences dropped here, before the loop
/// can see them.
//
// Also clears the shutdown flag raised by `stop`, so a stopped scheduler can
// be started again and `wait` parks rather than returning at once.
pub fn start(self: *Self) !void {
    switch (self.queue) {
        .hash_map => |*q| {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            self.shutdown_control.shutting_down = false;

            if (self.concurrent_launcher_future == null) {
                self.concurrent_launcher_future = try std.Io.concurrent(self.io, runConcurrentPendingJobs, .{self});
            }

            var it = q.valueIterator();
            while (it.next()) |task| {
                // A non-null `future` means this job is already running.
                if (task.future == null) {
                    task.future = try std.Io.concurrent(self.io, runJob, .{ self.io, task.job });
                }
            }

            // Everything queued is now running, so the signal is consumed.
            self.add_control.pending = false;

            if (self.concurrent_launcher_future == null) {
                self.concurrent_launcher_future = try std.Io.concurrent(self.io, runConcurrentPendingJobs, .{self});
            }
        },
        .min_heap => |*maybe_mh| {
            self.mutex.lockUncancelable(self.io);
            self.shutdown_control.shutting_down = false;
            self.mutex.unlock(self.io);

            if (maybe_mh.* == null) maybe_mh.* = try MinHeap.create(self.io, self.allocator);
            const mh = maybe_mh.*.?;

            mh.mutex.lockUncancelable(mh.io);
            defer mh.mutex.unlock(mh.io);

            // Anything queued before the loop existed (or left behind by a
            // `stop`) may now be overdue. Drop those occurrences un-fired
            // before the loop can see them.
            mh.advanceStaleRoots(std.Io.Timestamp.now(mh.io, .real).toSeconds(), false);

            // A non-null `loop_future` means the loop is already running. It
            // picks up newly added jobs by itself, so there is nothing else to
            // reconcile here.
            if (mh.loop_future == null) {
                mh.loop_future = try std.Io.concurrent(mh.io, MinHeap.runMinHeap, .{mh});
            }
        },
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
/// the callbacks it had already dispatched have finished. In `.min_heap` mode
/// that is the shared loop plus every job's callback group; the jobs keep their
/// (now possibly overdue) `next_run`, which the next `start()` reconciles.
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
            // Cancel the launcher before touching the queue, so it cannot spawn a task
            // for a job while the walk below is canceling everything.
            self.stopConcurrentLauncher();

            var it = q.valueIterator();
            while (it.next()) |task| if (task.future) |f| {
                var future = f;
                _ = future.cancel(self.io);
                // Marks the job unlaunched so `start` relaunches it, and keeps
                // `deinit` from canceling the same `Future` a second time.
                task.future = null;
            };
        },
        .min_heap => |maybe_mh| {
            const mh = maybe_mh orelse return;
            // Order matters: the loop dispatches into these groups, so it has
            // to be dead before they are drained. Clearing `loop_future` also
            // marks the scheduler relaunchable and keeps `deinit` from
            // canceling the same `Future` twice.
            if (mh.loop_future) |f| {
                var future = f;
                _ = future.cancel(self.io);
                mh.loop_future = null;
            }
            for (mh.min_heap.items) |task| task.group.cancel(self.io);
        },
    }
}

/// Launches jobs added to a running scheduler in `concurrent` mode, so that an
/// `add` after `start()` needs no second `start()`. Run as a concurrent `Io`
/// task for the scheduler's lifetime; `stop`/`deinit` cancel it.
///
/// This is `concurrent` mode's counterpart to `runQueue`: one long-lived task
/// per scheduler reacting to queue changes. It does not know *what* was added —
/// it simply relaunches everything still missing a `Future`, which is the same
/// sweep `start` does.
fn runConcurrentPendingJobs(self: *Self) void {
    while (true) {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        while (!self.add_control.pending) {
            // Cancelable, unlike the `wait` in `Scheduler.wait`: this is how
            // `stop` and `deinit` end the task.
            self.add_control.added.wait(self.io, &self.mutex) catch return;
        }

        // Cleared before the sweep, not after: an `add` landing mid-sweep
        // then re-raises the flag and costs one harmless extra pass, whereas
        // clearing afterwards could swallow it.
        self.add_control.pending = false;

        var it = self.queue.hash_map.valueIterator();
        while (it.next()) |task| {
            if (task.future != null) continue;
            // `Io.concurrent` never runs the task inline, so spawning while
            // holding `mutex` cannot deadlock against a callback that calls
            // back into the scheduler.
            task.future = std.Io.concurrent(self.io, runJob, .{ self.io, task.job }) catch |err| {
                // Nothing to launch it with. Leave the job dormant and
                // relaunchable by the next `start()`; unlike `start`, there is
                // no caller here to return the error to.
                if (task.job.name) |job_name| {
                    std.log.warn("could not launch the job '{s}' with ID: {d}: {s}", .{ job_name, task.job.id, @errorName(err) });
                } else {
                    std.log.warn("could not launch the job with ID: {d}: {s}", .{ task.job.id, @errorName(err) });
                }
                continue;
            };
        }
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

        while (next_run <= now) next_run = job.schedule.nextFireTime(next_run);

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

test "min_heap: a scheduled job actually fires its callback" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .min_heap);
    defer scheduler.deinit();

    var counter = std.atomic.Value(u32).init(0);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, null, incrementCounter, .{&counter}, now);

    try scheduler.start();

    // Real wall-clock wait, as in the `concurrent` equivalent: give the loop at
    // least one full second-boundary to fire on. `scheduler.deinit()` then
    // cancels the loop and drains the job's callbacks, so `counter` is safe to
    // go out of scope right after this returns.
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);

    try testing.expect(counter.load(.monotonic) >= 1);
}

test "min_heap: a failing callback is logged but doesn't stop the loop" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .min_heap);
    defer scheduler.deinit();

    var counter = std.atomic.Value(u32).init(0);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, "failing job", failingCallback, .{&counter}, now);

    try scheduler.start();

    // Every firing returns an error; the shared loop must keep going anyway.
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(3), .real);

    try testing.expect(counter.load(.monotonic) >= 2);
}

test "min_heap: every queued job fires, not just the root" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .min_heap);
    defer scheduler.deinit();

    var fast = std.atomic.Value(u32).init(0);
    var slow = std.atomic.Value(u32).init(0);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, null, incrementCounter, .{&fast}, now);
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 2 } }, null, incrementCounter, .{&slow}, now);

    try scheduler.start();
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(5), .real);

    // The 1s job must not starve the 2s one: both share a single loop, and the
    // faster one is the root far more often.
    try testing.expect(slow.load(.monotonic) >= 1);
    try testing.expect(fast.load(.monotonic) > slow.load(.monotonic));
}

test "min_heap: a job added after start is picked up without another start" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .min_heap);
    defer scheduler.deinit();

    var counter = std.atomic.Value(u32).init(0);

    // Start with a job far enough out that the loop parks on a long deadline:
    // the late `add` below has to interrupt that sleep, not wait it out.
    var now = std.Io.Timestamp.now(io, .real).toSeconds();
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 3600 } }, null, noopCallback, .{}, now);

    try scheduler.start();
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real);

    now = std.Io.Timestamp.now(io, .real).toSeconds();
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, null, incrementCounter, .{&counter}, now);

    // No second `start()`: the wakeup event is what makes this mode notice.
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);

    try testing.expect(counter.load(.monotonic) >= 1);
}

test "min_heap: an overdue job is dropped, not replayed" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .min_heap);
    defer scheduler.deinit();

    var counter = std.atomic.Value(u32).init(0);

    // A day's worth of backlog on a 1s schedule: 86400 occurrences that must
    // all be skipped un-fired. Replaying them would fire back-to-back on
    // zero-length sleeps and starve everything else on the shared loop.
    const stale = std.Io.Timestamp.now(io, .real).toSeconds() - std.time.s_per_day;
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, null, incrementCounter, .{&counter}, stale);

    try scheduler.start();
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(3), .real);

    // Only the occurrences that genuinely came due during the sleep above.
    try testing.expect(counter.load(.monotonic) >= 1);
    try testing.expect(counter.load(.monotonic) <= 5);
}

test "min_heap: a job added overdue to a live loop is dropped, not replayed" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .min_heap);
    defer scheduler.deinit();

    var counter = std.atomic.Value(u32).init(0);

    try scheduler.start(); // empty queue: the loop parks on the wakeup event

    // Same backlog as above, but arriving after the loop is already live, so
    // it is `add` rather than `start` that has to drop the elapsed occurrences.
    const stale = std.Io.Timestamp.now(io, .real).toSeconds() - std.time.s_per_day;
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, null, incrementCounter, .{&counter}, stale);

    try std.Io.sleep(io, std.Io.Duration.fromSeconds(3), .real);

    try testing.expect(counter.load(.monotonic) >= 1);
    try testing.expect(counter.load(.monotonic) <= 5);
}

test "min_heap: remove waits for an in-flight callback before freeing its args" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .min_heap);
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

    // `remove` cancels this job's own callback group, which blocks until the
    // spinning callback returns. So by the time it returns, the callback is
    // provably done — it cannot still be reading the args tuple just freed.
    try testing.expect(state.finished.load(.acquire));
}

test "min_heap: removed job stops firing" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .min_heap);
    defer scheduler.deinit();

    var counter = std.atomic.Value(u32).init(0);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const id = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, null, incrementCounter, .{&counter}, now);

    try scheduler.start();

    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);
    try testing.expect(scheduler.remove(id));

    const count_at_removal = counter.load(.monotonic);
    try testing.expect(count_at_removal >= 1);

    // The job is out of the heap and its callbacks have drained, so no further
    // firing is possible even after waiting.
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);
    try testing.expectEqual(count_at_removal, counter.load(.monotonic));
}

test "min_heap: stop halts firing but keeps jobs, and start relaunches them" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .min_heap);
    defer scheduler.deinit();

    var counter = std.atomic.Value(u32).init(0);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, null, incrementCounter, .{&counter}, now);

    try scheduler.start();
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);

    scheduler.stop();
    const count_at_stop = counter.load(.monotonic);
    try testing.expect(count_at_stop >= 1);

    // `stop` blocks until the loop has actually stopped, so nothing may fire
    // afterwards — but the job itself stays registered.
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);
    try testing.expectEqual(count_at_stop, counter.load(.monotonic));
    try testing.expectEqual(@as(usize, 1), scheduler.count());

    // `stop` cleared `loop_future`, so `start` relaunches rather than treating
    // the loop as already running. The two seconds missed above are dropped,
    // not replayed.
    try scheduler.start();
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);
    const after_relaunch = counter.load(.monotonic);
    try testing.expect(after_relaunch > count_at_stop);
    try testing.expect(after_relaunch - count_at_stop <= 5);
}

test "min_heap: stop before wait does not block" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .min_heap);
    defer scheduler.deinit();

    scheduler.stop();
    scheduler.wait();
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

test "concurrent: a job added after start is picked up without another start" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .concurrent);
    defer scheduler.deinit();

    var counter = std.atomic.Value(u32).init(0);

    // Start with an empty queue, so the launcher has nothing to do until the
    // `add` below signals it.
    try scheduler.start();
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .real);

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, null, incrementCounter, .{&counter}, now);

    // No second `start()`: `runConcurrentJobs` is what launches this.
    try std.Io.sleep(io, std.Io.Duration.fromSeconds(2), .real);

    try testing.expect(counter.load(.monotonic) >= 1);
}

test "concurrent: a job added while running is launched exactly once" {
    var threaded = testIo();
    defer threaded.deinit();
    const io = threaded.io();

    var scheduler = Self.init(io, testing.allocator, .concurrent);
    defer scheduler.deinit();

    var counter = std.atomic.Value(u32).init(0);

    try scheduler.start();

    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    _ = try scheduler.add(.{ .every_n_seconds = .{ .n = 1 } }, null, incrementCounter, .{&counter}, now);

    // A redundant `start()` must not launch a second timer task for a job the
    // launcher has already picked up — that would double every firing.
    try std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .real);
    try scheduler.start();

    try std.Io.sleep(io, std.Io.Duration.fromSeconds(3), .real);

    // ~3 firings for one task; a double launch would show up as ~6.
    try testing.expect(counter.load(.monotonic) >= 2);
    try testing.expect(counter.load(.monotonic) <= 4);
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
