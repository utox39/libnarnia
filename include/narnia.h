/*
 * narnia.h - C bindings for libnarnia, a job-scheduling library.
 *
 * Typical use:
 *
 *     NarniaScheduler *s = narnia_scheduler_new();
 *     uint64_t id;
 *     narnia_scheduler_add(s, narnia_every_n_seconds(5), "tick",
 *                          on_tick, NULL, NULL, narnia_now(s), &id);
 *     narnia_scheduler_start(s);
 *     narnia_scheduler_wait(s);
 *     narnia_scheduler_destroy(s);
 *
 * All timestamps are unix seconds, UTC. Times before 1970 are not supported.
 *
 * THREADING
 * ---------
 * The scheduler owns an internal thread pool. Job callbacks run on that pool,
 * never on the thread that called narnia_scheduler_start, and two invocations
 * of the same callback can overlap if one outlasts its own interval — a
 * callback holding mutable state must synchronise it itself.
 *
 * narnia_scheduler_add, narnia_scheduler_remove, narnia_scheduler_start and
 * narnia_scheduler_wait are thread-safe.
 *
 * narnia_scheduler_stop and narnia_scheduler_destroy are NOT: they require
 * exclusive access and must not race any other call on the same scheduler.
 *
 * A job's callback must never remove its own job: narnia_scheduler_remove
 * waits for the job's callbacks to finish, so the callback would wait on
 * itself and deadlock. Removing a *different* job from inside a callback is
 * fine, as is adding one.
 */

#ifndef NARNIA_H
#define NARNIA_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ------------------------------------------------------------------ */
/* Errors                                                             */
/* ------------------------------------------------------------------ */

typedef enum {
    NARNIA_OK = 0,
    NARNIA_ERR_OUT_OF_MEMORY = 1,
    /* A schedule field was outside its valid range. */
    NARNIA_ERR_INVALID_SCHEDULE = 2,
    /* A required pointer argument was NULL. */
    NARNIA_ERR_INVALID_ARGUMENT = 3
} NarniaError;

/* Static description of an error code. Never free the result. */
const char *narnia_strerror(NarniaError err);

/* ------------------------------------------------------------------ */
/* Schedules                                                          */
/* ------------------------------------------------------------------ */

typedef enum {
    NARNIA_EVERY_N_SECONDS = 0,
    NARNIA_EVERY_N_MINUTES = 1,
    NARNIA_HOURLY = 2,
    NARNIA_DAILY = 3,
    NARNIA_WEEKLY = 4,
    NARNIA_MONTHLY = 5,
    NARNIA_YEARLY = 6
} NarniaScheduleKind;

/* Weekday values for narnia_weekly. */
#define NARNIA_SUNDAY    0
#define NARNIA_MONDAY    1
#define NARNIA_TUESDAY   2
#define NARNIA_WEDNESDAY 3
#define NARNIA_THURSDAY  4
#define NARNIA_FRIDAY    5
#define NARNIA_SATURDAY  6

typedef struct {
    uint64_t n;
} NarniaEveryNSecondsSchedule;

typedef struct {
    uint64_t n;
} NarniaEveryNMinutesSchedule;

typedef struct {
    uint8_t minute;
    uint8_t second;
} NarniaHourlySchedule;

typedef struct {
    uint8_t hour;
    uint8_t minute;
    uint8_t second;
} NarniaDailySchedule;

typedef struct {
    uint8_t week_day;
    uint8_t hour;
    uint8_t minute;
    uint8_t second;
} NarniaWeeklySchedule;

typedef struct {
    uint8_t day_of_month;
    bool last_day;
    uint8_t hour;
    uint8_t minute;
    uint8_t second;
} NarniaMonthlySchedule;

typedef struct {
    uint8_t month;
    uint8_t day_of_month;
    bool last_day;
    uint8_t hour;
    uint8_t minute;
    uint8_t second;
} NarniaYearlySchedule;

/*
 * Pass as the `day` of narnia_monthly / narnia_yearly to fire on the last
 * calendar day of the month, whatever it is (28/29/30/31).
 */
#define NARNIA_LAST_DAY 0xFF

typedef union {
    NarniaEveryNSecondsSchedule every_n_seconds;
    NarniaEveryNMinutesSchedule every_n_minutes;
    NarniaHourlySchedule hourly;
    NarniaDailySchedule daily;
    NarniaWeeklySchedule weekly;
    NarniaMonthlySchedule monthly;
    NarniaYearlySchedule yearly;
} NarniaScheduleData;

/*
 * Build these with the constructors below rather than filling the fields by
 * hand. Fields are validated by narnia_scheduler_add, which reports
 * NARNIA_ERR_INVALID_SCHEDULE.
 */
typedef struct {
    NarniaScheduleKind kind;
    NarniaScheduleData data;
} NarniaSchedule;

/* Every `n` seconds, aligned to the unix epoch. `n` must be >= 1. */
NarniaSchedule narnia_every_n_seconds(uint64_t n);

/* Every `n` minutes, aligned to the unix epoch. `n` must be >= 1. */
NarniaSchedule narnia_every_n_minutes(uint64_t n);

/* Every hour at MM:SS. */
NarniaSchedule narnia_hourly(uint8_t minute, uint8_t second);

/* Every day at HH:MM:SS. */
NarniaSchedule narnia_daily(uint8_t hour, uint8_t minute, uint8_t second);

/* Every week on `weekday` at HH:MM:SS. */
NarniaSchedule narnia_weekly(uint8_t weekday, uint8_t hour, uint8_t minute,
                             uint8_t second);

/*
 * Every month on `day` at HH:MM:SS. A month too short for `day` (the 31st in
 * April) is skipped entirely, not clamped. Pass NARNIA_LAST_DAY for `day` to
 * fire on the last calendar day instead.
 */
NarniaSchedule narnia_monthly(uint8_t day, uint8_t hour, uint8_t minute,
                              uint8_t second);

/*
 * Every year on `month`/`day` at HH:MM:SS. A year where `day` doesn't fall
 * inside `month` is skipped, so February 29 only fires on leap years, while
 * NARNIA_LAST_DAY always fires.
 */
NarniaSchedule narnia_yearly(uint8_t month, uint8_t day, uint8_t hour,
                             uint8_t minute, uint8_t second);

/* ------------------------------------------------------------------ */
/* Scheduler                                                          */
/* ------------------------------------------------------------------ */

typedef struct NarniaScheduler NarniaScheduler;

/* Callback invoked on each firing, and the disposer for its user_data. */
typedef void (*NarniaJobFn)(void *user_data);
typedef void (*NarniaDestroyFn)(void *user_data);

/*
 * Creates a scheduler and its internal thread pool. Returns NULL on
 * allocation failure. Free it with narnia_scheduler_destroy.
 */
NarniaScheduler *narnia_scheduler_new(void);

/*
 * Current unix timestamp in seconds, UTC — the reference point
 * narnia_scheduler_add computes a job's first run from. Returns 0 if
 * `scheduler` is NULL.
 *
 * It takes the scheduler because the clock is read through that scheduler's
 * internal event loop, the same source its running jobs compare against.
 */
int64_t narnia_now(NarniaScheduler *scheduler);

/*
 * Cancels every job, waits for in-flight callbacks to finish, runs every
 * registered destroy-notify, and frees the scheduler. Passing NULL is a
 * no-op. Requires exclusive access.
 */
void narnia_scheduler_destroy(NarniaScheduler *scheduler);

/*
 * Registers a job, writing its id to `out_job_id` (may be NULL). Ids start at
 * 1 and are never reused.
 *
 * `name` may be NULL; it is copied and only used in log messages about failing
 * callbacks. `destroy` may be NULL, otherwise it is called with `user_data`
 * once the job is removed or the scheduler destroyed — after the job's
 * callbacks have provably stopped. When `destroy` is NULL, `user_data` must
 * outlive the job.
 *
 * `now` is the timestamp the job's first run is computed from; the next fire
 * time is always strictly after it. Pass narnia_now() unless you are
 * deliberately scheduling relative to some other instant.
 *
 * Nothing fires until narnia_scheduler_start. A job added after a previous
 * start stays dormant until the next one.
 */
NarniaError narnia_scheduler_add(NarniaScheduler *scheduler,
                                 NarniaSchedule schedule, const char *name,
                                 NarniaJobFn callback, void *user_data,
                                 NarniaDestroyFn destroy, int64_t now,
                                 uint64_t *out_job_id);

/*
 * Launches every registered job that isn't already running, then returns
 * immediately. Idempotent: already-running jobs are skipped, never restarted,
 * so call it again after adding jobs to pick them up.
 */
NarniaError narnia_scheduler_start(NarniaScheduler *scheduler);

/*
 * Removes a job by id, returning true if it was found. Blocks until the job's
 * timer loop has stopped and its in-flight callbacks have finished, then runs
 * its destroy-notify. See the deadlock note at the top of this file.
 */
bool narnia_scheduler_remove(NarniaScheduler *scheduler, uint64_t job_id);

/*
 * Stops every running job and wakes anything parked in narnia_scheduler_wait,
 * without unregistering anything — a later narnia_scheduler_start relaunches
 * them. Blocks until the jobs have actually stopped. Requires exclusive
 * access.
 */
void narnia_scheduler_stop(NarniaScheduler *scheduler);

/*
 * Blocks until another thread calls narnia_scheduler_stop. Jobs never finish
 * on their own, so a shutdown signal is the only thing that ends this. Returns
 * immediately if a stop has already happened.
 */
void narnia_scheduler_wait(NarniaScheduler *scheduler);

#ifdef __cplusplus
}
#endif

#endif /* NARNIA_H */
