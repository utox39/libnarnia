/*
 * Tests for the C ABI in include/narnia.h, linked against the static library
 * exactly the way a downstream C project would link it.
 *
 * These complement the Zig-side tests in src/c_api.zig: those reach inside the
 * module (toSchedule, the Handle), while these only ever touch the header's
 * public surface, so they also check that the header and src/c_api.zig are
 * still in lockstep — field order in NarniaSchedule, the enum values, and
 * NARNIA_LAST_DAY.
 *
 * Several tests wait on real wall-clock time (the scheduler has no injectable
 * clock through C), which is what makes the suite take ~20s.
 */

#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "narnia.h"

static unsigned g_checks_failed;
static unsigned g_total_checks;
static const char *g_current_test;

/*
 * Records the failure and keeps going: a failed expectation in one test says
 * nothing about the others, and running them all gives a fuller report than
 * aborting on the first one.
 */
#define CHECK(cond)                                                            \
    do {                                                                       \
        if (!(cond)) {                                                         \
            g_checks_failed++;                                                 \
            fprintf(stderr, "  FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);  \
        }                                                                      \
    } while (0)

#define CHECK_ERR(expected, expr)                                              \
    do {                                                                       \
        NarniaError got_ = (expr);                                             \
        if (got_ != (expected)) {                                              \
            g_checks_failed++;                                                 \
            fprintf(stderr, "  FAIL %s:%d: %s: expected %s, got %s\n",         \
                    __FILE__, __LINE__, #expr, narnia_strerror(expected),      \
                    narnia_strerror(got_));                                    \
        }                                                                      \
    } while (0)

#define RUN(test)                                                              \
    do {                                                                       \
        g_total_checks++;                                                      \
        unsigned before_ = g_checks_failed;                                    \
        g_current_test = #test;                                                \
        printf("running %s\n", #test);                                         \
        fflush(stdout);                                                        \
        test();                                                                \
        if (g_checks_failed != before_)                                        \
            fprintf(stderr, "  %s FAILED\n", #test);                           \
    } while (0)

/* ------------------------------------------------------------------ */
/* Shared job state                                                   */
/* ------------------------------------------------------------------ */

/*
 * Callbacks run on the scheduler's pool and two invocations of the same job
 * can overlap, so every field a callback touches is atomic.
 */
typedef struct {
    _Atomic unsigned fired;
    _Atomic bool destroyed;
} Counter;

static void on_fire(void *user_data) {
    Counter *counter = user_data;
    counter->fired++;
}

static void on_destroy(void *user_data) {
    Counter *counter = user_data;
    counter->destroyed = true;
}

/* A scheduler or a bail-out: there is no sane way to continue without one. */
static NarniaScheduler *must_new_concurrent(void) {
    NarniaScheduler *scheduler = narnia_scheduler_new(NARNIA_MODE_CONCURRENT);
    if (scheduler == NULL) {
        fprintf(stderr, "%s: narnia_scheduler_new returned NULL\n",
                g_current_test);
        exit(1);
    }
    return scheduler;
}

static NarniaScheduler *must_new_min_heap(void) {
    NarniaScheduler *scheduler = narnia_scheduler_new(NARNIA_MODE_MIN_HEAP);
    if (scheduler == NULL) {
        fprintf(stderr, "%s: narnia_scheduler_new returned NULL\n",
                g_current_test);
        exit(1);
    }
    return scheduler;
}

/* ------------------------------------------------------------------ */
/* Schedule constructors                                              */
/* ------------------------------------------------------------------ */

/*
 * The constructors are by-value and can't report errors, so all they owe us is
 * the right kind and the fields landing where the header says they do. A
 * mismatch here is the symptom of NarniaSchedule having drifted out of order
 * from CSchedule in src/c_api.zig.
 */
static void test_constructors_set_kind_and_fields(void) {
    NarniaSchedule secs = narnia_every_n_seconds(15);
    CHECK(secs.kind == NARNIA_EVERY_N_SECONDS);
    CHECK(secs.data.every_n_seconds.n == 15);

    NarniaSchedule mins = narnia_every_n_minutes(5);
    CHECK(mins.kind == NARNIA_EVERY_N_MINUTES);
    CHECK(mins.data.every_n_minutes.n == 5);

    NarniaSchedule hourly = narnia_hourly(30, 15);
    CHECK(hourly.kind == NARNIA_HOURLY);
    CHECK(hourly.data.hourly.minute == 30);
    CHECK(hourly.data.hourly.second == 15);

    NarniaSchedule daily = narnia_daily(9, 30, 15);
    CHECK(daily.kind == NARNIA_DAILY);
    CHECK(daily.data.daily.hour == 9);
    CHECK(daily.data.daily.minute == 30);
    CHECK(daily.data.daily.second == 15);

    NarniaSchedule weekly = narnia_weekly(NARNIA_WEDNESDAY, 17, 45, 30);
    CHECK(weekly.kind == NARNIA_WEEKLY);
    CHECK(weekly.data.weekly.week_day == NARNIA_WEDNESDAY);
    CHECK(weekly.data.weekly.hour == 17);
    CHECK(weekly.data.weekly.minute == 45);
    CHECK(weekly.data.weekly.second == 30);

    NarniaSchedule monthly = narnia_monthly(25, 1, 2, 3);
    CHECK(monthly.kind == NARNIA_MONTHLY);
    CHECK(monthly.data.monthly.day_of_month == 25);
    CHECK(!monthly.data.monthly.last_day);
    CHECK(monthly.data.monthly.hour == 1);
    CHECK(monthly.data.monthly.minute == 2);
    CHECK(monthly.data.monthly.second == 3);

    // Merry Christmas!
    NarniaSchedule yearly = narnia_yearly(12, 25, 0, 0, 0);
    CHECK(yearly.kind == NARNIA_YEARLY);
    CHECK(yearly.data.yearly.month == 12);
    CHECK(yearly.data.yearly.day_of_month == 25);
}

/* NARNIA_LAST_DAY is a sentinel in `day`, and must set the separate flag. */
static void test_last_day_sentinel_sets_the_flag(void) {
    NarniaSchedule monthly = narnia_monthly(NARNIA_LAST_DAY, 0, 0, 0);
    CHECK(monthly.data.monthly.last_day);

    NarniaSchedule yearly = narnia_yearly(2, NARNIA_LAST_DAY, 0, 0, 0);
    CHECK(yearly.data.yearly.last_day);
    CHECK(yearly.data.yearly.month == 2);

    /* An ordinary day must not be mistaken for the sentinel. */
    CHECK(!narnia_monthly(31, 0, 0, 0).data.monthly.last_day);
}

static void test_strerror_describes_every_code(void) {
    CHECK(strcmp(narnia_strerror(NARNIA_OK), "ok") == 0);
    CHECK(strlen(narnia_strerror(NARNIA_ERR_OUT_OF_MEMORY)) > 0);
    CHECK(strlen(narnia_strerror(NARNIA_ERR_INVALID_SCHEDULE)) > 0);
    CHECK(strlen(narnia_strerror(NARNIA_ERR_INVALID_ARGUMENT)) > 0);
}

/* ------------------------------------------------------------------ */
/* Registration                                                       */
/* ------------------------------------------------------------------ */

static void test_add_assigns_increasing_ids(void) {
    NarniaScheduler *scheduler = must_new_concurrent();

    uint64_t first = 0, second = 0;
    CHECK_ERR(NARNIA_OK,
              narnia_scheduler_add(scheduler, narnia_every_n_seconds(3600),
                                   "first", on_fire, NULL, NULL, 0, &first));
    CHECK_ERR(NARNIA_OK,
              narnia_scheduler_add(scheduler, narnia_every_n_seconds(3600),
                                   "second", on_fire, NULL, NULL, 0, &second));

    CHECK(first == 1);
    CHECK(second == 2);

    /* A NULL out_job_id and a NULL name are both allowed. */
    CHECK_ERR(NARNIA_OK,
              narnia_scheduler_add(scheduler, narnia_every_n_seconds(3600),
                                   NULL, on_fire, NULL, NULL, 0, NULL));

    narnia_scheduler_destroy(scheduler);
}

static void test_add_rejects_invalid_arguments(void) {
    NarniaScheduler *scheduler = must_new_concurrent();

    uint64_t id = 0;
    CHECK_ERR(NARNIA_ERR_INVALID_ARGUMENT,
              narnia_scheduler_add(NULL, narnia_every_n_seconds(1), NULL,
                                   on_fire, NULL, NULL, 0, &id));
    CHECK_ERR(NARNIA_ERR_INVALID_ARGUMENT,
              narnia_scheduler_add(scheduler, narnia_every_n_seconds(1), NULL,
                                   NULL, NULL, NULL, 0, &id));

    narnia_scheduler_destroy(scheduler);
}

/*
 * The header's uint8_t fields can express values the Zig schedule types can't
 * hold, so every one of them has to be rejected at the boundary rather than
 * tripping an assert deeper in.
 */
static void test_add_rejects_out_of_range_schedules(void) {
    NarniaScheduler *scheduler = must_new_concurrent();

    const NarniaSchedule invalid[] = {
        narnia_every_n_seconds(0),     narnia_every_n_minutes(0),
        narnia_daily(24, 0, 0),        narnia_daily(0, 60, 0),
        narnia_daily(0, 0, 60),        narnia_hourly(60, 0),
        narnia_weekly(7, 0, 0, 0),     narnia_monthly(0, 0, 0, 0),
        narnia_monthly(32, 0, 0, 0),   narnia_yearly(0, 1, 0, 0, 0),
        narnia_yearly(13, 1, 0, 0, 0),
    };

    for (size_t i = 0; i < sizeof invalid / sizeof invalid[0]; i++) {
        NarniaError err = narnia_scheduler_add(scheduler, invalid[i], NULL,
                                               on_fire, NULL, NULL, 0, NULL);
        if (err != NARNIA_ERR_INVALID_SCHEDULE) {
            g_checks_failed++;
            fprintf(
                stderr,
                "  FAIL %s:%d: schedule #%zu (kind %u): expected %s, got %s\n",
                __FILE__, __LINE__, i, invalid[i].kind,
                narnia_strerror(NARNIA_ERR_INVALID_SCHEDULE),
                narnia_strerror(err));
        }
    }

    /* An unknown kind is a schedule error too, not a crash. */
    NarniaSchedule bogus = narnia_daily(0, 0, 0);
    bogus.kind = 99;
    CHECK_ERR(NARNIA_ERR_INVALID_SCHEDULE,
              narnia_scheduler_add(scheduler, bogus, NULL, on_fire, NULL, NULL,
                                   0, NULL));

    narnia_scheduler_destroy(scheduler);
}

/* NULL is documented as a no-op or a benign default on every entry point. */
static void test_null_handle_is_handled_everywhere(void) {
    CHECK(narnia_now(NULL) == 0);
    CHECK_ERR(NARNIA_ERR_INVALID_ARGUMENT, narnia_scheduler_start(NULL));
    CHECK(!narnia_scheduler_remove(NULL, 1));
    narnia_scheduler_stop(NULL);
    narnia_scheduler_wait(NULL);
    narnia_scheduler_destroy(NULL);
}

static void test_now_returns_a_plausible_timestamp(void) {
    NarniaScheduler *scheduler = must_new_concurrent();

    int64_t now = narnia_now(scheduler);
    // 2020-01-01 < now < 2100-01-01: catches a wrong unit far more than a skew.
    // 2020-01-01: 1577836800
    // 2100-01-01: 4102444800
    CHECK(now > 1577836800);
    CHECK(now < 4102444800);

    narnia_scheduler_destroy(scheduler);
}

/* ------------------------------------------------------------------ */
/* Running                                                            */
/* ------------------------------------------------------------------ */

static void test_job_fires_after_start(void) {
    NarniaScheduler *scheduler = must_new_concurrent();
    Counter counter = {0, false};

    uint64_t id = 0;
    CHECK_ERR(NARNIA_OK,
              narnia_scheduler_add(scheduler, narnia_every_n_seconds(1),
                                   "ticker", on_fire, &counter, NULL,
                                   narnia_now(scheduler), &id));

    /* Nothing may fire before start(). */
    sleep(2);
    CHECK(counter.fired == 0);

    CHECK_ERR(NARNIA_OK, narnia_scheduler_start(scheduler));
    sleep(2);
    CHECK(counter.fired >= 1);

    /* `counter` is on this stack, so the job has to be gone before we return.
     */
    narnia_scheduler_destroy(scheduler);
}

/*
 * remove() blocks until the job's callbacks have stopped, so the destroy-notify
 * it then runs can never race a callback still reading the same user_data.
 */
static void test_remove_stops_the_job_and_runs_destroy(void) {
    NarniaScheduler *scheduler = must_new_concurrent();
    Counter counter = {0, false};

    uint64_t id = 0;
    CHECK_ERR(NARNIA_OK,
              narnia_scheduler_add(scheduler, narnia_every_n_seconds(1),
                                   "ticker", on_fire, &counter, on_destroy,
                                   narnia_now(scheduler), &id));
    CHECK_ERR(NARNIA_OK, narnia_scheduler_start(scheduler));
    sleep(2);

    CHECK(narnia_scheduler_remove(scheduler, id));
    CHECK(counter.destroyed);

    unsigned at_removal = counter.fired;
    CHECK(at_removal >= 1);

    /* The job's timer loop is provably stopped, so this count must not move. */
    sleep(2);
    CHECK(counter.fired == at_removal);

    /* Removing twice, or removing an id that never existed, is just false. */
    CHECK(!narnia_scheduler_remove(scheduler, id));
    CHECK(!narnia_scheduler_remove(scheduler, 9999));

    narnia_scheduler_destroy(scheduler);
}

/* A job that outlives every remove() still gets its disposer run on destroy. */
static void test_destroy_runs_pending_destroy_notifies(void) {
    NarniaScheduler *scheduler = must_new_concurrent();
    Counter counter = {0, false};

    CHECK_ERR(NARNIA_OK, narnia_scheduler_add(
                             scheduler, narnia_every_n_seconds(3600), "dormant",
                             on_fire, &counter, on_destroy, 0, NULL));

    narnia_scheduler_destroy(scheduler);
    CHECK(counter.destroyed);
}

/*
 * A job registered after a start() is launched on its own, and a redundant
 * start() does not restart anything already running.
 */
static void test_start_is_idempotent_and_picks_up_late_jobs(void) {
    NarniaScheduler *scheduler = must_new_concurrent();
    Counter early = {0, false};
    Counter late = {0, false};

    CHECK_ERR(NARNIA_OK,
              narnia_scheduler_add(scheduler, narnia_every_n_seconds(1),
                                   "early", on_fire, &early, NULL,
                                   narnia_now(scheduler), NULL));
    CHECK_ERR(NARNIA_OK, narnia_scheduler_start(scheduler));
    sleep(2);
    CHECK(early.fired >= 1);

    CHECK_ERR(NARNIA_OK,
              narnia_scheduler_add(scheduler, narnia_every_n_seconds(1), "late",
                                   on_fire, &late, NULL, narnia_now(scheduler),
                                   NULL));
    sleep(2);
    CHECK(late.fired >= 1); /* picked up without a second start() */

    unsigned early_before_restart = early.fired;
    unsigned late_before_restart = late.fired;

    /* A redundant start() must not launch a second timer task for either job:
     * that would double every firing from here on.
     */
    CHECK_ERR(NARNIA_OK, narnia_scheduler_start(scheduler));
    sleep(3);
    CHECK(early.fired > early_before_restart);
    CHECK(early.fired - early_before_restart <= 4);
    CHECK(late.fired - late_before_restart <= 4);

    narnia_scheduler_destroy(scheduler);
}

/* stop() unschedules nothing: the jobs stay registered and relaunchable. */
static void test_stop_halts_firing_and_start_relaunches(void) {
    NarniaScheduler *scheduler = must_new_concurrent();
    Counter counter = {0, false};

    CHECK_ERR(NARNIA_OK,
              narnia_scheduler_add(scheduler, narnia_every_n_seconds(1),
                                   "ticker", on_fire, &counter, NULL,
                                   narnia_now(scheduler), NULL));
    CHECK_ERR(NARNIA_OK, narnia_scheduler_start(scheduler));
    sleep(2);

    /* Blocks until the jobs have actually stopped. */
    narnia_scheduler_stop(scheduler);
    unsigned at_stop = counter.fired;
    CHECK(at_stop >= 1);

    sleep(2);
    CHECK(counter.fired == at_stop);

    CHECK_ERR(NARNIA_OK, narnia_scheduler_start(scheduler));
    sleep(2);
    CHECK(counter.fired > at_stop);

    narnia_scheduler_destroy(scheduler);
}

/* ------------------------------------------------------------------ */
/* wait / stop                                                        */
/* ------------------------------------------------------------------ */

static void *stop_after_a_second(void *arg) {
    NarniaScheduler *scheduler = arg;
    sleep(1);
    narnia_scheduler_stop(scheduler);
    return NULL;
}

/* A stop that already happened must not leave wait() parked forever. */
static void test_wait_returns_immediately_after_a_stop(void) {
    NarniaScheduler *scheduler = must_new_concurrent();

    narnia_scheduler_stop(scheduler);
    narnia_scheduler_wait(scheduler); /* hangs the suite if this regresses */

    narnia_scheduler_destroy(scheduler);
}

/* The shutdown handshake a real C program uses: park here, stop from a thread.
 */
static void test_wait_is_woken_by_a_stop_from_another_thread(void) {
    NarniaScheduler *scheduler = must_new_concurrent();
    Counter counter = {0, false};

    CHECK_ERR(NARNIA_OK,
              narnia_scheduler_add(scheduler, narnia_every_n_seconds(1),
                                   "ticker", on_fire, &counter, NULL,
                                   narnia_now(scheduler), NULL));
    CHECK_ERR(NARNIA_OK, narnia_scheduler_start(scheduler));

    pthread_t stopper;
    if (pthread_create(&stopper, NULL, stop_after_a_second, scheduler) != 0) {
        fprintf(stderr, "%s: failed to spawn the stopper thread\n",
                g_current_test);
        exit(1);
    }

    int64_t before = narnia_now(scheduler);
    narnia_scheduler_wait(scheduler);
    int64_t waited = narnia_now(scheduler) - before;
    pthread_join(stopper, NULL);

    /* It parked for the stopper rather than falling straight through. */
    CHECK(waited >= 1);

    narnia_scheduler_destroy(scheduler);
}

/* An unknown mode must be refused rather than silently defaulted. */
static void test_new_rejects_an_unknown_mode(void) {
    CHECK(narnia_scheduler_new((NarniaSchedulerMode)99) == NULL);
    CHECK(narnia_scheduler_new((NarniaSchedulerMode)-1) == NULL);
}

/* The min_heap mode has to be a drop-in for concurrent across the C surface. */
static void test_min_heap_mode_fires_and_removes(void) {
    NarniaScheduler *scheduler = must_new_min_heap();
    Counter counter = {0, false};

    uint64_t id = 0;
    CHECK_ERR(NARNIA_OK,
              narnia_scheduler_add(scheduler, narnia_every_n_seconds(1),
                                   "heap ticker", on_fire, &counter,
                                   on_destroy, narnia_now(scheduler), &id));

    /* Nothing may fire before start(), in this mode either. */
    sleep(2);
    CHECK(counter.fired == 0);

    CHECK_ERR(NARNIA_OK, narnia_scheduler_start(scheduler));
    sleep(2);
    CHECK(counter.fired >= 1);

    /* remove() waits for the job's callbacks, then runs the destroy-notify. */
    CHECK(narnia_scheduler_remove(scheduler, id));
    CHECK(counter.destroyed);

    unsigned int after_removal = counter.fired;
    sleep(2);
    CHECK(counter.fired == after_removal);

    narnia_scheduler_destroy(scheduler);
}

/* A job added to a running min_heap scheduler needs no second start(). */
static void test_min_heap_picks_up_late_jobs(void) {
    NarniaScheduler *scheduler = must_new_min_heap();
    Counter counter = {0, false};

    CHECK_ERR(NARNIA_OK, narnia_scheduler_start(scheduler));

    uint64_t id = 0;
    CHECK_ERR(NARNIA_OK,
              narnia_scheduler_add(scheduler, narnia_every_n_seconds(1),
                                   "late heap ticker", on_fire, &counter, NULL,
                                   narnia_now(scheduler), &id));

    sleep(2);
    CHECK(counter.fired >= 1);

    narnia_scheduler_destroy(scheduler);
}

/* ------------------------------------------------------------------ */

int main(void) {
    RUN(test_constructors_set_kind_and_fields);
    RUN(test_last_day_sentinel_sets_the_flag);
    RUN(test_strerror_describes_every_code);
    RUN(test_add_assigns_increasing_ids);
    RUN(test_add_rejects_invalid_arguments);
    RUN(test_add_rejects_out_of_range_schedules);
    RUN(test_null_handle_is_handled_everywhere);
    RUN(test_now_returns_a_plausible_timestamp);
    RUN(test_job_fires_after_start);
    RUN(test_remove_stops_the_job_and_runs_destroy);
    RUN(test_destroy_runs_pending_destroy_notifies);
    RUN(test_start_is_idempotent_and_picks_up_late_jobs);
    RUN(test_stop_halts_firing_and_start_relaunches);
    RUN(test_wait_returns_immediately_after_a_stop);
    RUN(test_wait_is_woken_by_a_stop_from_another_thread);
    RUN(test_new_rejects_an_unknown_mode);
    RUN(test_min_heap_mode_fires_and_removes);
    RUN(test_min_heap_picks_up_late_jobs);

    printf("\n- %u/%u C API tests passed.\n", g_total_checks - g_checks_failed,
           g_total_checks);

    if (g_checks_failed != 0) {
        fprintf(stderr, "- %u test(s) failed\n", g_checks_failed);
        return 1;
    }
    return 0;
}
