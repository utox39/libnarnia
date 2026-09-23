const std = @import("std");
const libnarnia = @import("libnarnia");

fn tick(io: std.Io, label: []const u8) void {
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    const fields = libnarnia.schedule.CalendarFields.fromEpochSeconds(now);
    std.debug.print("{f} - {s}\n", .{ fields, label });
}

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{ .thread_safe = true }) = .init;
    defer _ = gpa.deinit();

    // `.concurrent` gives every job its own timer task; `.min_heap` drives them
    // all from one shared loop (see the second scheduler below).
    var scheduler = libnarnia.Scheduler.init(init.io, gpa.allocator(), .concurrent);
    defer scheduler.deinit();

    const now = std.Io.Timestamp.now(init.io, .real).toSeconds();

    // The callback and its arguments are passed separately: the tuple is
    // copied into the scheduler, so it outlives this scope.
    const job_id = try scheduler.add(
        .{ .every_n_seconds = .{ .n = 5 } },
        "tick", // optional; only used in log messages about failing callbacks
        tick,
        .{ init.io, "every 5 seconds" },
        now, // the first run is computed from this instant, strictly after it
    );

    // Launches every job that isn't already running, then returns immediately.
    // Nothing fires before this; a job added *after* it is picked up on its
    // own, in either mode, so one call is enough.
    try scheduler.start();

    // The same jobs under `.min_heap`: one loop for the whole queue instead of
    // a task per job.
    var heap_scheduler = libnarnia.Scheduler.init(init.io, gpa.allocator(), .min_heap);
    defer heap_scheduler.deinit();

    const heap_job_id = try heap_scheduler.add(
        .{ .every_n_seconds = .{ .n = 3 } },
        "heap tick",
        tick,
        .{ init.io, "min_heap: every 3 seconds" },
        now,
    );

    try heap_scheduler.start();

    // Unlike `.concurrent`, this mode has a shared ordering, so it can say what
    // fires next.
    if (heap_scheduler.peek()) |next| {
        const fields = libnarnia.schedule.CalendarFields.fromEpochSeconds(next.next_run);
        std.debug.print("next up: job {d} at {f}\n", .{ next.id, fields });
    }

    try std.Io.sleep(init.io, std.Io.Duration.fromSeconds(8), .real);

    // Added to an already-running scheduler: the run loop is woken and picks it
    // up straight away, with no second `start()`. The same holds for the
    // `.concurrent` scheduler above, where a launcher task does the honours.
    const late_job_id = try heap_scheduler.add(
        .{ .every_n_seconds = .{ .n = 2 } },
        "late tick",
        tick,
        .{ init.io, "min_heap: added after start, every 2 seconds" },
        std.Io.Timestamp.now(init.io, .real).toSeconds(),
    );

    try std.Io.sleep(init.io, std.Io.Duration.fromSeconds(8), .real);

    // Blocks until the job's timer loop and its in-flight callbacks have
    // stopped, then frees the captured arguments.
    _ = scheduler.remove(job_id);

    // In `.min_heap` there is no per-job loop to stop, but the guarantee is the
    // same: this job's callback group is drained before its args are freed.
    _ = heap_scheduler.remove(late_job_id);
    _ = heap_scheduler.remove(heap_job_id);
}
