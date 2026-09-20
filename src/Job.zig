const std = @import("std");
const Schedule = @import("schedule.zig").Schedule;

/// The job ID.
id: u64,
name: ?[]const u8 = null,
schedule: Schedule,
next_run: i64,
callback: *const fn (ctx: ?*anyopaque) anyerror!void,
/// Points at the heap-allocated args tuple captured by `Scheduler.add`.
/// Only `callback` knows its real type.
ctx: ?*anyopaque,
/// Frees what `ctx` points at. Type-erased per job, since the args tuple's
/// type is only known at the `add` call site.
destroy_ctx: *const fn (gpa: std.mem.Allocator, ctx: ?*anyopaque) void,

const Self = @This();

pub fn init(
    gpa: std.mem.Allocator,
    id: u64,
    name: ?[]const u8,
    schedule: Schedule,
    next_run: i64,
    callback: *const fn (ctx: ?*anyopaque) anyerror!void,
    ctx: ?*anyopaque,
    destroy_ctx: *const fn (gpa: std.mem.Allocator, ctx: ?*anyopaque) void,
) !Self {
    return Self{
        .id = id,
        .name = if (name) |n| try gpa.dupe(u8, n) else null,
        .schedule = schedule,
        .next_run = next_run,
        .callback = callback,
        .ctx = ctx,
        .destroy_ctx = destroy_ctx,
    };
}

/// Releases the job's captured args. The caller must first ensure no
/// callback using `ctx` is still in flight.
pub fn deinit(self: Self, gpa: std.mem.Allocator) void {
    self.destroy_ctx(gpa, self.ctx);
    if (self.name) |n| gpa.free(n);
}

/// Orders jobs by `next_run` so the earliest-firing job sorts first,
/// making `std.PriorityQueue` a min-heap over fire time.
pub fn lessThanByNextRun(context: void, a: Self, b: Self) std.math.Order {
    _ = context;
    return std.math.order(a.next_run, b.next_run);
}
