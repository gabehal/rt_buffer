# Project Context

Last updated: 2026-10-02

## What this project is
A hands-on way to learn real-time programming in C++. The goal is a control loop that runs
every 1 ms with as little timing error (jitter) as possible, measured on Linux and compared
against a baseline of what the kernel alone can do.

## How it works today
The program runs three threads that pass data through small shared buffers:

    vision thread  -->  vision_ring  -->  control thread  -->  log_ring  -->  log thread

- **Vision** simulates a camera. It sleeps a random 10 to 60 ms, then publishes a random x/y position.
- **Control** wakes every 1 ms, picks up the newest vision sample if there is one, and records
  timing data. It schedules each wake-up against a fixed deadline, so small delays don't add up
  over time. With `--rt` it gets real-time priority.
- **Log** collects the timing data. When you press Ctrl-C, it prints summary statistics and histograms.

The buffers (`RingBuffer`) hold 3 slots and only keep the latest value, so a slow reader
skips older values instead of queueing them.

The program measures three numbers, all in microseconds:
- **sample_delay**: how old a vision sample is when control reads it.
- **tick_duration**: how long control's own work takes each tick, not counting sleep.
- **jitter**: how late control woke up compared with its scheduled deadline.

## Files
- `thread.cpp`: the whole program, with the threads, the ring buffer, and the statistics.
- `rt_bench.sh`: a Linux benchmark battery with two modes. By default it runs `cyclictest`
  (a standard latency tester) to measure the kernel on its own. With `--thread` it builds
  `thread.cpp` with `-O2` and runs it with `--rt` instead. Both modes use the same `stress-ng`
  loads, then a 45-minute soak test and a hardware latency check (`hwlatdetect`). The results
  go to `results/<timestamp>_cyclictest/` or `results/<timestamp>_thread/`. Each test adds one
  row to `summary.log` there as it finishes: p50, p99 and max latency in microseconds, plus
  "RT ok" or "RT FAILED" in thread mode. The bottom of the file has a plain-English
  walkthrough for readers new to bash.
- `summarize.sh`: takes two results folders and prints their `summary.log` tables side by
  side, with the difference for p99 and max. It only reads summaries and never the raw logs.
- `.gitignore`: keeps the compiled `thread` binary out of git. Rebuild it locally from source.

## How to build and run
    g++ -std=c++17 -O2 -pthread thread.cpp -o thread   # same command on the Mac and on Linux
    ./thread            # press Ctrl-C to stop and print the stats
    sudo ./thread --rt  # locks memory and gives the control thread real-time priority
    ./rt_bench.sh           # Linux only: kernel baseline with cyclictest
    ./rt_bench.sh --thread  # Linux only: same battery, with this program instead
    ./summarize.sh results/<baseline folder> results/<thread folder>   # side-by-side comparison

`--rt` locks all memory in RAM (`mlockall`), so the loop never stalls on a page fault.
It also puts the control thread on `SCHED_FIFO` priority 50. Both need root on Linux.

## Where things stand
The pipeline builds and runs on the Mac and prints its statistics. The cyclictest kernel
baseline has been run on Linux, but test 08 (interrupt load) changed on 2026-10-02, so the
baseline needs to be re-run before it can be compared with a `--thread` run. cyclictest's flags
also changed on 2026-10-02 (`-q -H400`), and old runs have no `summary.log`, which is another
reason to re-run. `rt_bench.sh --thread` is ready but hasn't run on Linux yet, so there are no
real numbers for this program so far. The summary parsing was tested on the Mac with real
`thread` output and hand-made cyclictest logs in the format from cyclictest's source code. It
hasn't been checked against real cyclictest output yet.

**Comparing the two runs.** cyclictest's latency is how late it woke up after its 1 ms timer,
which is the same idea as this program's `jitter`. Both are in microseconds. The setups aren't
identical: cyclictest runs one thread per CPU at priority 99, while this program runs one
control thread at priority 50 next to the vision and log threads, and the log thread
busy-waits. Both still preempt `stress-ng`, which runs at normal priority. Use `summarize.sh`
with the baseline folder first and the thread folder second.

## Decisions and why
- **2026-09-26: vision uses a latest-value buffer.** Control only cares about the newest
  position, so an old sample is worth nothing.
- **2026-09-26: control sleeps until an absolute deadline** (`sleep_until`) rather than for a
  duration. That way lateness in one tick doesn't push every later tick back.
- **2026-09-26: only the control thread gets real-time priority.** It's the only thread with a
  hard deadline.
- **2026-09-30: build with `-O2` and record the build flags with every benchmark.** Unoptimized
  code makes `tick_duration` look slower than a real build would be, and numbers from different
  flags can't be compared.
- **2026-09-30: `rt_bench.sh --thread` builds the binary itself.** The flags are then fixed and
  written to `metadata.txt`, so a stale or debug build can't sneak into a benchmark.
- **2026-09-30: the benchmark stops the program with SIGINT** (`timeout -s INT`). That uses the
  program's normal Ctrl-C shutdown, so it prints its statistics into the log.
- **2026-10-02: test 08 runs every interrupt stressor at once** (`--class interrupt --all 1`).
  The old `--sequential` (with no number) most likely made stress-ng exit straight away, leaving
  no load. Even with a number, it would run the stressors one after another, each for the full
  2 minutes, so the measurement would only cover the first one.
- **2026-10-02: the summary reports p50, p99 and max latency, in microseconds.** Real-time is
  judged by the worst case, so max and p99 matter most. p50 shows the typical case. The same
  three numbers exist in both modes, so they compare directly. hwlatdetect and histogram
  overflow counts are left out of the summary on purpose.
- **2026-10-02: cyclictest runs with `-q -H400` on every test.** The histogram is needed to work
  out p50 and p99 (cyclictest itself only reports min, average and max), and `-q` stops the log
  from filling with live updates. Samples of 400 us or more are counted in the total, so p99
  isn't flattered. If p99 falls there, the summary shows `>=400 us`. The parsing assumes 2 or
  more CPUs, because only then does cyclictest add the all-CPUs column.
- **2026-10-02: keep things simple.** The summary code was first written as a separate step
  with helpers for cases this repo won't hit. It was rewritten so `run_test()` adds each row
  directly. `CLAUDE.md` now makes simplicity a top-priority rule.

## Open questions / known issues
- **The log can lose data.** `log_ring` keeps only the latest value, so if the log thread falls
  behind, ticks get skipped and the statistics are incomplete. This is why an SPSC queue
  (single-producer, single-consumer) is next.
- **Possible torn read.** If the writer publishes twice while the reader is still copying a slot,
  can it overwrite that slot mid-copy?
- **Type and ordering mismatch.** `head` and `tail` are `size_t` but get loaded into `int`.
  `read()` uses the default (strongest) memory ordering. Is acquire enough?
- `<atomic>` isn't included directly. The code only compiles because another header pulls it in.
- The log thread busy-waits, which burns a whole CPU core.

## What's next
1. Design and build an SPSC queue for `log_ring`, so no samples are lost.
2. On Linux, re-run `./rt_bench.sh` for a fresh cyclictest baseline (test 08 changed), then run
   `./rt_bench.sh --thread`. Check that the first run's `summary.log` has real numbers rather
   than `n/a`, which confirms the parser matches real cyclictest output. Then run
   `./summarize.sh <baseline folder> <thread folder>` and check every row says "RT ok".

## Change log
### 2026-10-02: summary.log and summarize.sh
Each test in `rt_bench.sh` now adds a row to `summary.log` (p50, p99, max latency) as it
finishes, and `summarize.sh` compares two runs side by side. cyclictest runs with `-q -H400` on
every test to provide the histogram. The soak test goes through `run_test` with the same
stress-ng arguments as before. Added the "Keep it simple" rule to `CLAUDE.md`.

### 2026-10-02: Fixed the test 08 load in rt_bench.sh
Replaced `--sequential` with `--all 1`, so test 08 actually loads the machine with every
interrupt-class stressor for its 2 minutes. Earlier cyclictest baselines aren't comparable for
test 08 and should be re-run.

### 2026-10-02: Explained rt_bench.sh for beginners
Added comments on the edge cases throughout `rt_bench.sh`, plus a plain-English walkthrough at
the bottom. Each walkthrough step is numbered and matches a `[STEP N]` marker in the code.
No behaviour changed. `CLAUDE.md` now describes this as the standard way to add pseudocode
to a file.

### September 2026 (condensed)
- 2026-09-30: `rt_bench.sh --thread` runs the battery with this program instead of cyclictest.
  The build now uses `-O2`, the compiled binary is no longer tracked in git, and `CLAUDE.md` and
  this file were added. `mlockall` was added to `--rt` mode, and `rt_bench.sh` was added
  (commit fcc93f6).
- 2026-09-26: first working pipeline: vision, control, and log threads with ring buffers, a 1 ms
  control loop, optional `SCHED_FIFO`, and a latency report (commit 646ac73).
