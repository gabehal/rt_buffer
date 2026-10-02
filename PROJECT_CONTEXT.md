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
  go to `results/<timestamp>_cyclictest/` or `results/<timestamp>_thread/`. The bottom of the
  file has a plain-English walkthrough for readers new to bash.
- `.gitignore`: keeps the compiled `thread` binary out of git. Rebuild it locally from source.

## How to build and run
    g++ -std=c++17 -O2 -pthread thread.cpp -o thread   # same command on the Mac and on Linux
    ./thread            # press Ctrl-C to stop and print the stats
    sudo ./thread --rt  # locks memory and gives the control thread real-time priority
    ./rt_bench.sh           # Linux only: kernel baseline with cyclictest
    ./rt_bench.sh --thread  # Linux only: same battery, with this program instead

`--rt` locks all memory in RAM (`mlockall`), so the loop never stalls on a page fault.
It also puts the control thread on `SCHED_FIFO` priority 50. Both need root on Linux.

## Where things stand
The pipeline builds and runs on the Mac and prints its statistics. The cyclictest kernel
baseline has been run on Linux. `rt_bench.sh --thread` is ready but hasn't run on Linux yet,
so there are no real numbers for this program so far.

**Comparing the two runs.** cyclictest's latency is how late it woke up after its 1 ms timer,
which is the same idea as this program's `jitter`. Both are in microseconds. The setups aren't
identical: cyclictest runs one thread per CPU at priority 99, while this program runs one
control thread at priority 50 next to the vision and log threads, and the log thread
busy-waits. Both still preempt `stress-ng`, which runs at normal priority.

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
- **Test 08 may run with no load.** In `rt_bench.sh`, `--sequential` normally needs a number
  after it. If stress-ng rejects the line, test 08 measures an idle machine. Check the terminal
  output. Fixing it means re-running the cyclictest baseline too, so both runs use the same load.

## What's next
1. Design and build an SPSC queue for `log_ring`, so no samples are lost.
2. On Linux, run `./rt_bench.sh --thread`. Check each log for "SCHED_FIFO priority 50 applied"
   to confirm RT mode was active, then compare `jitter` against the cyclictest baseline.

## Change log
### 2026-10-02: Explained rt_bench.sh for beginners
Added comments on the edge cases throughout `rt_bench.sh`, plus a plain-English walkthrough at
the bottom. Each walkthrough step is numbered and matches a `[STEP N]` marker in the code.
No behaviour changed. `CLAUDE.md` now describes this as the standard way to add pseudocode
to a file.

### 2026-09-30: Thread mode for the benchmark script
`rt_bench.sh --thread` runs the same battery with this program in place of cyclictest, so the two
can be compared directly. The load commands are unchanged. The mode is now in the results folder
name and the metadata, and the script is executable.

### 2026-09-30: Build command now uses -O2
The documented build now includes `-O2`, so measurements reflect optimized code. Benchmark
metadata should include the build flags.

### 2026-09-30: Stop tracking the compiled binary
Added a `.gitignore` for `thread` and removed it from git, because a build output doesn't
belong in version control. The local copy is kept.

### 2026-09-30: Project docs
Added `CLAUDE.md` (rules for working in the repo) and this file, so project context and history
survive between sessions.

### 2026-09-30: Memory locking in --rt mode and benchmark script (commit fcc93f6)
`--rt` now calls `mlockall` before starting the threads, so memory stays in RAM and the control
loop doesn't hit page faults. Added `rt_bench.sh` to measure the Linux kernel baseline before
testing our own code.

### 2026-09-26: First working pipeline (commit 646ac73)
Vision, control, and log threads connected by 3-slot ring buffers. There's a 1 ms control loop
with an optional `SCHED_FIFO` priority, and a latency report with percentiles and histograms.
