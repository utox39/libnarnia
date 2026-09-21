/*
 * Schedule a job, let it fire, remove it, schedule a second one, then shut
 * down.
 *
 * The one addition is the shutdown path. src/main.zig just falls off the end
 * of main; here a helper thread calls narnia_scheduler_stop while the main
 * thread parks in narnia_scheduler_wait, which is how a real C program would
 * hand control to the scheduler.
 */

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#include "narnia.h"

/* Shared between the job callbacks, which run on scheduler threads. */
typedef struct {
    const char *message;
    /* Callbacks of the same job can overlap, so this is not a plain int. */
    _Atomic unsigned fired;
} Tick;

static void on_tick(void *user_data) {
    Tick *tick = user_data;
    unsigned n = ++tick->fired;
    printf("- %s (firing #%u)\n", tick->message, n);
    fflush(stdout);
}

/*
 * Registered as the job's destroy-notify, so the scheduler frees this for us
 * once the job is gone and its callbacks have provably stopped.
 */
static void free_tick(void *user_data) {
    Tick *tick = user_data;
    printf("  [destroy-notify] releasing \"%s\" after %u firings\n",
           tick->message, tick->fired);
    free(tick);
}

static Tick *tick_new(const char *message) {
    Tick *tick = calloc(1, sizeof *tick);
    if (tick == NULL) {
        fprintf(stderr, "out of memory\n");
        exit(1);
    }
    tick->message = message;
    return tick;
}

/* Fails loudly instead of limping on with a job that was never registered. */
static uint64_t must_add(NarniaScheduler *scheduler, NarniaSchedule schedule,
                         const char *name, Tick *tick) {
    uint64_t id = 0;
    NarniaError err =
        narnia_scheduler_add(scheduler, schedule, name, on_tick, tick,
                             free_tick, narnia_now(scheduler), &id);
    if (err != NARNIA_OK) {
        fprintf(stderr, "failed to add \"%s\": %s\n", name,
                narnia_strerror(err));
        exit(1);
    }
    printf("added \"%s\" as job %llu\n", name, (unsigned long long)id);
    return id;
}

/*
 * narnia_scheduler_stop requires exclusive access, so this sleeps well clear
 * of the main thread's last add/remove rather than racing it.
 */
static void *stop_after_delay(void *arg) {
    NarniaScheduler *scheduler = arg;
    sleep(5);
    printf("--- stopping ---\n");
    narnia_scheduler_stop(scheduler);
    return NULL;
}

int main(void) {
    NarniaScheduler *scheduler = narnia_scheduler_new();
    if (scheduler == NULL) {
        fprintf(stderr, "failed to create the scheduler\n");
        return 1;
    }

    uint64_t job_id = must_add(scheduler, narnia_every_n_seconds(1),
                               "every 1 second", tick_new("tick every 1s"));

    NarniaError err = narnia_scheduler_start(scheduler);
    if (err != NARNIA_OK) {
        fprintf(stderr, "failed to start: %s\n", narnia_strerror(err));
        narnia_scheduler_destroy(scheduler);
        return 1;
    }

    sleep(4);

    printf("---\n");
    /* Blocks until the job has stopped, then runs free_tick. */
    if (!narnia_scheduler_remove(scheduler, job_id)) {
        fprintf(stderr, "job %llu was already gone\n",
                (unsigned long long)job_id);
    }

    must_add(scheduler, narnia_every_n_seconds(2), "every 2 seconds",
             tick_new("tick every 2s"));
    /* start() again: the new job stayed dormant until this call. */
    narnia_scheduler_start(scheduler);

    pthread_t stopper;
    if (pthread_create(&stopper, NULL, stop_after_delay, scheduler) != 0) {
        fprintf(stderr, "failed to spawn the stopper thread\n");
        narnia_scheduler_destroy(scheduler);
        return 1;
    }

    /* Parks until the thread above signals shutdown. */
    narnia_scheduler_wait(scheduler);
    pthread_join(stopper, NULL);

    printf("--- stopped, destroying ---\n");
    narnia_scheduler_destroy(scheduler);
    return 0;
}
