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

    // `.concurrent` gives every job its own timer task. `.min_heap` is not
    // implemented yet.
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
    // Nothing fires before this, and a job added later stays dormant until the
    // next `start()` — it is idempotent, so just call it again.
    try scheduler.start();

    try std.Io.sleep(init.io, std.Io.Duration.fromSeconds(16), .real);

    // Blocks until the job's timer loop and its in-flight callbacks have
    // stopped, then frees the captured arguments.
    _ = scheduler.remove(job_id);
}
