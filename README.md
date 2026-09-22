# libnarnia

- [Description](#description)
- [Requirements](#requirements)
- [Usage (Zig)](#usage-zig)
  - [Add libnarnia to your project](#add-libnarnia-to-your-project)
  - [Zig API usage](#zig-api-usage)
- [Schedules](#schedules)
- [Threading and lifetimes](#threading-and-lifetimes)
- [Usage (C bindings)](#usage-c-bindings)
  - [Build](#build)
  - [Compile and link against it](#compile-and-link-against-it)
  - [Cross-compiling](#cross-compiling)
  - [pkg-config and CMake](#pkg-config-and-cmake)
  - [C API usage](#c-api-usage)
- [Examples](#examples)
  - [Zig example](#zig-example)
  - [C example](#c-example)
- [Tests](#tests)
- [Roadtrip](#roadtrip)
- [Contributing](#contributing)
- [License](#license)

## Description

libnarnia is a job-scheduling library (cron-like recurring jobs) for Zig 0.16.0,
with C bindings.

> [!NOTE]
> The cron syntax and the `min_heap` scheduler mode are not implemented yet.

## Requirements

- [Zig v0.16.0](https://ziglang.org/)

## Usage (Zig)

### Add libnarnia to your project

This will fetch from the main branch:

```sh
zig fetch --save git+https://github.com/utox39/libnarnia.git
```

If you want to use Zig master, use the zig-master branch:

```sh
zig fetch --save git+https://github.com/utox39/libnarnia.git#zig-master
```

In `build.zig`:

```zig
    const libnarnia = b.dependency("libnarnia", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("libnarnia", libnarnia.module("libnarnia"));
```

Or:

```zig
    const libnarnia = b.dependency("libnarnia", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my_project",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "libnarnia", .module = libnarnia.module("libnarnia") },
            },
        }),
    });
```

### Zig API usage

```zig
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

```

A long-running program would park in `scheduler.wait()` instead of sleeping;
it returns once another thread calls `scheduler.stop()`.

Full API documentation: [libnarnia-docs](https://utox39.github.io/libnarnia/)

Or:

```sh
cd path/to/libnarnia

zig build docs

python3 -m http.server 8000 -d zig-out/docs
```

And go to `http://localhost:8000`

## Schedules

All timestamps are unix seconds, UTC. Times before 1970 are not supported.

| Variant             | Fires                          | Example                                                                |
| ------------------- | ------------------------------ | ---------------------------------------------------------------------- |
| `every_n_seconds`   | every N seconds, epoch-aligned | `.{ .every_n_seconds = .{ .n = 30 } }`                                 |
| `every_n_minutes`   | every N minutes, epoch-aligned | `.{ .every_n_minutes = .{ .n = 15 } }`                                 |
| `hourly`            | every hour at MM:SS            | `.{ .hourly = .{ .minutes = 30 } }`                                    |
| `daily`             | every day at HH:MM:SS          | `.{ .daily = .{ .hour = 9, .minute = 0, .second = 0 } }`               |
| `weekly`            | every week on a weekday        | `.{ .weekly = .{ .day = .MONDAY, .hour = 9, .minute = 0 } }`           |
| `monthly`           | every month on a day           | `.{ .monthly = .{ .day = .{ .day = 1 }, .minute = 0 } }`               |
| `yearly`            | every year on a month/day      | `.{ .yearly = .{ .month = .jan, .day = .{ .day = 1 }, .minute = 0 } }` |

`monthly` and `yearly` take a `DayOfMonth`: either `.{ .day = 1..31 }` or
`.last_day`, which resolves to whatever the month's last day is (28/29/30/31).

Three behaviours worth knowing before you rely on one:

- **The next fire time is strictly after the reference instant.** Handing
  `add` a timestamp that is itself a fire instant schedules the *following*
  occurrence, never that same second.
- **Missed occurrences are dropped, not replayed.** A job that starts out
  overdue (a stale `now`, a late `start()`, a relaunch after `stop()`) or that
  falls behind a callback slower than its own interval skips the elapsed
  occurrences un-fired and resumes at the next future one.
- **A month too short for the requested day is skipped, not clamped.**
  `.{ .day = 31 }` does not fire in April, and February 29 only fires on leap
  years. Use `.last_day` if you want the end of every month.

## Threading and lifetimes

Job callbacks run on the scheduler's internal thread pool, never on the thread
that called `start()`.

- **`add`, `remove`, `start`, `count`, `peek` and `wait` are thread-safe.**
- **`stop` and `deinit` are not.** Both require exclusive access: they walk the
  queue with the lock released (cancelling a job blocks until its callbacks
  drain, and holding the lock across that would deadlock against any callback
  calling back into the scheduler), so neither may race an `add` or `remove`.
- **A callback must never remove its own job.** `remove` waits for the job's
  callbacks to finish, so the callback would wait on itself and deadlock.
  Removing a *different* job from inside a callback is fine, as is `add` — but
  a job added from a callback still stays dormant until the next `start()`.
- **A callback can overlap with itself.** Each firing is dispatched
  fire-and-forget so a slow callback never delays the next occurrence, so a
  callback outlasting its own interval runs more than once at a time, every
  invocation sharing the one copy of the arguments the job was registered with.
  Callbacks holding mutable state must synchronise it themselves.
- **The scheduler owns the arguments tuple** it copied in `add`, and frees it
  once `remove` or `deinit` has proven the callbacks have stopped. Anything
  the tuple only *points* at is still yours to keep alive.
- **A callback returning an error doesn't stop its job:** the error is logged
  and the timer loop keeps running.

## Usage (C bindings)

### Build

```sh
zig build
```

That installs, under `zig-out/`:

```
zig-out/include/narnia.h      # the C header
zig-out/lib/libnarnia.a       # static library
zig-out/lib/libnarnia.dylib   # shared library (libnarnia.so on Linux)
zig-out/bin/libnarnia         # the Zig demo, `zig build run`
zig-out/bin/narnia-example    # the C example, `zig build example`
```

On Windows the libraries are `narnia.lib` and `narnia.dll` — Zig drops the
`lib` prefix there.

Override the install prefix with `--prefix`, e.g. `zig build --prefix /usr/local`.

### Compile and link against it

Static:

> Name the ar archive directly, so the linker can't prefer the shared library sitting next to it:

```sh
zig cc my_app.c -I zig-out/include zig-out/lib/libnarnia.a -o my_app
```

**macOS static caveat:** link the archive with `zig cc`, not Apple's `cc`. Zig
0.16 writes archive members that Apple's `ld` rejects with *"64-bit mach-o not
8-byte aligned"*, in every optimize mode. Zig's own linker handles it, which is
also why `zig build example` works. On Linux, plain `cc` links the archive
fine.

Shared:

```sh
cc my_app.c -I zig-out/include -L zig-out/lib -lnarnia -lpthread \
   -Wl,-rpath,"$PWD/zig-out/lib" -o my_app
```

The `-rpath` is not optional on macOS: the dylib's install name is
`@rpath/libnarnia.dylib`, which `DYLD_LIBRARY_PATH` does not satisfy. On Linux
you can drop it and set `LD_LIBRARY_PATH=$PWD/zig-out/lib` at runtime instead.

The scheduler runs jobs on an internal thread pool, so `-lpthread` is required
on Linux. It is a no-op on macOS, where pthreads live in libc.

### Cross-compiling

Pass a target triple through to the build; the resulting library is linked the
same way from that platform's toolchain.

```sh
zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast
```

### pkg-config and CMake

There is no generated `.pc` or CMake package config. Point your build system at
`zig-out/include` and `zig-out/lib` directly — in CMake:

```cmake
add_library(narnia STATIC IMPORTED)
set_target_properties(narnia PROPERTIES
    IMPORTED_LOCATION "${NARNIA_ROOT}/zig-out/lib/libnarnia.a"
    INTERFACE_INCLUDE_DIRECTORIES "${NARNIA_ROOT}/zig-out/include")
target_link_libraries(my_app PRIVATE narnia Threads::Threads)
```

### C API usage

See: [include/narnia.h](https://github.com/utox39/libnarnia/blob/main/include/narnia.h)

Read `include/narnia.h` for the API. Two rules the header spells out and the
compiler cannot enforce:

- `narnia_scheduler_stop` and `narnia_scheduler_destroy` require exclusive
  access — they must not race any other call on the same scheduler.
- A job's callback must never remove *its own* job; that deadlocks. Removing a
  different job, or adding one, is fine.

## Examples

### Zig example

See: [src/main.zig](https://github.com/utox39/libnarnia/blob/main/src/main.zig)

Run it with:

```sh
zig build run
```

### C example

See: [examples/example.c](https://github.com/utox39/libnarnia/blob/main/examples/example.c)

`examples/example.c` is a complete program built and linked by the same `build.zig`.

Run it with:

```sh
zig build example
```

## Tests

```sh
zig build test --summary all
```

The `.concurrent` scheduler tests wait on real wall-clock time rather than
a mocked one (for now).

The two files that import nothing can also be tested on their own, which is
much faster while iterating on the time math:

```sh
zig test src/Scheduler.zig
zig test src/schedule.zig
zig test src/schedule.zig --test-filter "monthly"   # a subset, by name
```

`src/c_api.zig` cannot be run with `zig test src/c_api.zig` because it imports
the `libnarnia` module, which only the build graph supplies.

### C API

```sh
zig build c-test
```

## Roadtrip

- [ ] Add cron syntax support
- [ ] Experiments with [MicroZig](https://microzig.tech/)
- [ ] Add more C API tests
- [ ] Add an on_error policy

## Contributing

Please see [CONTRIBUTING](https://github.com/utox39/libnarnia/blob/main/CONTRIBUTING.md). Thanks!

## License

MIT License. See: [LICENSE](https://github.com/utox39/libnarnia/blob/main/LICENSE)
