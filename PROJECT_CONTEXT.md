# Project Context

Last updated: 2026-10-03

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
- `rt_bench.sh`: a Linux benchmark battery with two modes. It measures only the isolated
  core 6 and runs all load on cores 0-5 and 7. By default it runs `cyclictest` (a standard
  latency tester) to measure the kernel on its own. With `--thread` it builds `thread.cpp` with
  `-O2` and runs it with `--rt --cpu 6` instead. Both modes use the same `stress-ng` loads (see
  "The tests" below). `--quick` skips the soak and hwlatdetect, and `--no-rt` (with `--thread`)
  runs the program without `--rt`/`--cpu`. Each run gets a folder like
  `results/<timestamp>_thread_quick/` holding exactly two files:
  - `summary.log`: the run info (mode, options, commit, build flags, isolation, kernel), then
    one row per test with avg, p99, p99.9 and max latency in microseconds, plus "RT ok",
    "RT off" or "RT FAILED" in thread mode. The hwlatdetect result goes on a line under the
    table. This is the file that matters.
  - `raw.log`: every tool's raw output, one section per test. Only for debugging, for example
    when a row shows `n/a`.

  The bottom of the file has a plain-English walkthrough for readers new to bash.
- `summarize.sh`: takes any two results folders and prints their `summary.log` tables side by
  side, with the difference for p99.9 and max and both runs' notes. Works for cyclictest vs
  thread, thread vs thread (e.g. RT vs no RT), and full vs quick runs (a test only one run
  has shows `n/a`). It only reads summaries and never the raw logs.
- `.gitignore`: keeps the compiled `thread` binary out of git. Rebuild it locally from source.

## How to build and run
    g++ -std=c++17 -O2 -pthread thread.cpp -o thread   # same command on the Mac and on Linux
    ./thread            # press Ctrl-C to stop and print the stats
    sudo ./thread --rt --cpu 6  # real-time mode, control thread pinned to core 6
    ./rt_bench.sh           # Linux only: kernel baseline with cyclictest
    ./rt_bench.sh --thread  # Linux only: same battery, with this program instead
    ./rt_bench.sh --thread --no-rt   # same, but the program runs without RT setup
    ./rt_bench.sh --quick            # any mode: skip the 45 min soak and hwlatdetect
    ./summarize.sh results/<folder A> results/<folder B>   # side-by-side comparison

`--rt` locks all memory in RAM (`mlockall`), so the loop never stalls on a page fault.
It also puts the control thread on `SCHED_FIFO` priority 80. `--cpu N` pins the control thread
to core N. Pinning only exists on Linux, so on the Mac it prints "CPU pinning skipped". All of
these need root on Linux. The first 100 ticks (`warmup_ticks`) aren't recorded, because they
can run before the pinning and priority take effect.

**Isolating core 6 (one-time setup on the Linux machine).** Add these to the kernel boot
command line, e.g. in `GRUB_CMDLINE_LINUX` in `/etc/default/grub`, then run `update-grub` and
reboot:

    isolcpus=6 nohz_full=6 rcu_nocbs=6 irqaffinity=0-5,7

They keep the scheduler, the timer tick, RCU callbacks, and device interrupts off core 6.
Then check `cat /sys/devices/system/cpu/cpu6/topology/thread_siblings_list`. If it lists
another CPU besides 6, that CPU is core 6's hyperthread twin and shares its hardware. Isolate
it too, or turn SMT off. `rt_bench.sh` records both in the `summary.log` header and warns if no core is
isolated.

## The tests
All load runs on cores 0-5 and 7. Only core 6 is measured.

| # | Test | stress-ng load | Time | What it stresses |
|---|---|---|---|---|
| 01 | idle | none | 2 min | nothing, the best case |
| 02 | kernel_work | `--switch 4 --pipe 2` | 2 min | scheduler and cross-core interrupts (IPIs) |
| 03 | disk_io | `--hdd 2` | 2 min | block layer and disk interrupts |
| 04 | memory | `--stream 7` | 2 min | shared L3 cache and memory bandwidth |
| 05 | combined_robot | `--cpu 2 --hdd 1 --switch 2 --vm 1 --vm-bytes 25%` | 2 min | roughly a real robot computer |
| 06 | soak_45min | `--cpu 7 --hdd 1 --switch 2 --vm 1 --vm-bytes 25%` | 45 min | every load core busy, rare spikes |
| 07 | hwlatdetect | none, runs alone | 5 min | stalls from the hardware or firmware (machine only, not compared) |

Disk tests write their temporary files to `~/stress_tmp`.

## Where things stand
The pipeline builds and runs on the Mac and prints its statistics. On 2026-10-03 the test list,
the measured core, the priority, and the metrics all changed, so any earlier cyclictest
baseline is out of date and needs re-running. `rt_bench.sh` and `thread.cpp` are both ready
for the new design. The program's pinning hasn't been run on Linux yet. On the Mac its output
parses into all four summary columns. The cyclictest parsing was tested with hand-made logs in
the format from cyclictest's source code, but hasn't been checked against real cyclictest
output yet.

**Comparing the two runs.** cyclictest's latency is how late it woke up after its 1 ms timer,
which is the same idea as this program's `jitter`. Both are in microseconds. Both run one
thread on core 6 at priority 80, so the comparison is fair. The raw output of the two tools
looks completely different, but that doesn't matter: only the `summary.log` rows are
compared, and those have the same four columns with the same meaning in every mode.

## What depends on what
These are the only places where one file relies on the exact output of another. If you change
one side of a pair, change the other side too, or tell Claude.
1. **`thread.cpp` → `rt_bench.sh`:** `summary_row` reads three lines of the program's output:
   `SCHED_FIFO priority 80 applied …`, `control thread pinned to CPU 6`, and
   `jitter: n=… avg=… p99=… p99.9=… max=… (us)`. On the jitter line, keys can be in any order
   and extra keys are fine.
2. **cyclictest → `rt_bench.sh`:** `summary_row` reads cyclictest's `-h` histogram and its
   `# Avg/Max Latencies` and `# Histogram Overflows` lines.
3. **hwlatdetect → `rt_bench.sh`:** the `Max Latency:` line becomes the line under the table.
4. **`summary.log` → `summarize.sh`:** rows are `name  value us  value us  value us  value us
   notes`, and the header keys `mode:`, `options:`, `git commit:`, `build flags:`, `rt cpu:`
   are shown in the comparison.

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
  recorded with the results, so a stale or debug build can't sneak into a benchmark.
- **2026-09-30: the benchmark stops the program with SIGINT** (`timeout -s INT`). That uses the
  program's normal Ctrl-C shutdown, so it prints its statistics into the log.
- **2026-10-03: only the isolated core 6 is measured, and all load runs on cores 0-5 and 7.**
  The RT loop will run alone on core 6, so that's the only core whose latency matters. The
  numbers show how much the rest of the machine leaks into it.
- **2026-10-03: cyclictest and the control thread both run at priority 80.** Equal priority
  makes the comparison fair. 80 is above PREEMPT_RT's interrupt threads (50) and below the
  kernel's own priority-99 threads.
- **2026-10-03: the summary reports avg, p99, p99.9 and max, in microseconds.** Real-time is
  judged by the tail, so p99.9 and max matter most, and `summarize.sh` shows the differences
  for those two. cyclictest gives avg and max itself. p99 and p99.9 come from its histogram
  (`-h400`, 1 us buckets). Samples of 400 us or more are counted in the total, so the tail
  isn't flattered. If a percentile falls there, the summary shows `>=400 us`.
- **2026-10-03: a dedicated memory test with `--stream 7`.** With an isolated core, shared cache
  and memory bandwidth are the main ways other cores still interfere. STREAM pushes the
  memory bus harder than `--vm`. A huge `--vm-bytes` was ruled out because it would push the
  machine into swapping.
- **2026-10-03: the first 100 control ticks are not recorded.** The control thread starts running
  before `main` pins it and raises its priority, so its first ticks can be slow, and one of
  them could end up as the reported max. Skipping 100 ticks (100 ms) is simpler than having the
  thread set itself up before its loop.
- **2026-10-03: each run folder holds only `summary.log` and `raw.log`.** Only the RT core's
  numbers matter, and `summary.log` holds them along with the run info. The separate
  per-test logs and `metadata.txt` were clutter. The raw output is still kept, in one file, so
  a row showing `n/a` can be debugged.
- **2026-10-03: `--quick` and `--no-rt`.** `--quick` gives a short run without the soak and
  hwlatdetect. `--no-rt` shows what the RT setup buys you, by running the program without
  locking, pinning or priority. `summarize.sh` lists every test from both runs and both runs'
  notes, so any two summaries can be compared.
- **2026-10-03: the soak uses one histogram for the whole 45 minutes**, not latency over time.
  cyclictest can't produce a time series.
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
- The log thread busy-waits, which burns a whole CPU core. With core isolation it runs on the
  load cores, not core 6.

## What's next
1. Set up core isolation on the Linux machine (see "Isolating core 6") and check for an SMT sibling.
2. Run `./rt_bench.sh` for a fresh baseline. Check that its `summary.log` has real numbers rather
   than `n/a`, which confirms the parser matches real cyclictest output. Then run
   `./rt_bench.sh --thread` and `./summarize.sh <baseline folder> <thread folder>`, and check
   every row says "RT ok".
3. Design and build an SPSC queue for `log_ring`, so no samples are lost.

## Change log
### 2026-10-03: Two files per run, --quick and --no-rt
Each results folder now holds only `summary.log` (run info and rows) and `raw.log` (all raw
tool output). `metadata.txt` and the per-test logs are gone. Added `--quick` (no soak, no
hwlatdetect) and `--no-rt` (thread mode without RT setup, rows say "RT off"). `summarize.sh`
now shows every test from both runs, `n/a` where one is missing, and both runs' notes. Added
the "What depends on what" section.

### 2026-10-03: Isolated core 6 (condensed)
`rt_bench.sh` measures only core 6 (one pinned cyclictest thread, or the program with
`--cpu 6`, both at priority 80), with all load pinned to cores 0-5 and 7, a new test list, and
avg/p99/p99.9/max columns. `thread.cpp` gained `--cpu N` pinning (Linux only), priority 80, a
100-tick warm-up skip, and `avg=`/`p99.9=` in its report.

### 2026-10-02 (condensed)
Added `summary.log` (one row per test, written by `run_test`) and `summarize.sh` to compare two
runs. Fixed test 08's stress-ng arguments (`--sequential` had no number). Added a beginner
walkthrough with `[STEP N]` markers to `rt_bench.sh`, and two rules to `CLAUDE.md`: the
pseudocode style and "Keep it simple".

### September 2026 (condensed)
- 2026-09-30: `rt_bench.sh --thread` runs the battery with this program instead of cyclictest.
  The build now uses `-O2`, the compiled binary is no longer tracked in git, and `CLAUDE.md` and
  this file were added. `mlockall` was added to `--rt` mode, and `rt_bench.sh` was added
  (commit fcc93f6).
- 2026-09-26: first working pipeline: vision, control, and log threads with ring buffers, a 1 ms
  control loop, optional `SCHED_FIFO`, and a latency report (commit 646ac73).
