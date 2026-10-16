# Project Context

Last updated: 2026-10-16

## What this project is
A hands-on way to learn real-time C++: a 1 ms control loop with as little timing error
(jitter) as possible, measured on Linux against what the kernel alone can do (cyclictest).

## How the program works (`thread.cpp`)
    vision thread  -->  vision_ring  -->  control thread  -->  log_ring  -->  log thread
- **Vision** simulates a camera: sleeps 10 to 60 ms, publishes a random x/y position.
- **Control** wakes every 1 ms against a fixed deadline, so delays don't add up, and reads
  the newest vision sample.
- **Log** collects timing data. On Ctrl-C it prints stats for `sample_delay` (age of the
  vision sample), `tick_duration` (control's own work), and `jitter` (how late control woke up).
- The ring buffers hold 3 slots and keep only the latest value.
- `--rt`: locks memory (`mlockall`) and runs control at `SCHED_FIFO` priority 80.
  `--cpu N`: pins control to core N (Linux only; skipped with a message on the Mac).
- The first 100 ticks aren't recorded, because they can run before pinning and priority apply.
- `thread.cpp` includes `sim_robot.h` but doesn't use it yet.

## Simulated robot (`sim_robot.h`)
One joint (a wheel on an axle) for the control loop to drive later. Physics only, no clocks
or threads. Inertia J = 0.01 and friction b = 0.05 are fixed. State is `angle` and `speed`;
inputs are `torque_cmd` (the controller's last command) and `torque_ext` (an outside push).
- `step(dt)` advances the physics by `dt` seconds (explicit Euler: acceleration, then speed,
  then angle).
- `catch_up(now)` advances from `last_time` to `now` in 50 µs slices plus one shorter
  remainder, so the physics stays accurate however late the caller is.
- The constructor takes the start time, so `last_time` can't be left uninitialised.

## Simulated sensors (`sensors.h`)
**`Encoder`** turns the joint angle into whole encoder counts, the way a real encoder would.
An encoder is a sensor that reports rotation as a whole number of ticks; this one has 4096
counts per revolution, so one count is about 1.5 mrad.
- `angle_to_counts(angle)` rounds down (`floor`), so negative angles land in the right count.
- `counts_to_angle(counts)` returns the middle of that count, so the error is at most half a
  count either way.

**`Gyro`** reports the joint's speed the way a real gyroscope would: wrong in two ways.
- A **bias** (a constant offset) starts at 0.02 rad/s and drifts as a random walk: each
  reading adds `drift * sqrt(elapsed) * N(0,1)`, so after t seconds it has wandered about
  `drift * sqrt(t)` (drift = 0.005). The sqrt makes the wander the same whether it's read
  often or rarely.
- **Hiss** (white noise, std 0.002 rad/s) is added fresh to every reading.
- `read_speed(now, true_speed)` returns true speed + bias + hiss. The constructor takes the
  start time and a random seed, so a run can be repeated exactly.

## Estimators (`estimators.h`)
**`DiffEstimator`** estimates speed from encoder counts: (change in counts × size of one
count) ÷ time since the last update. The constructor takes the start time and start count.
If no time has passed, `update` returns 0.0. Nothing tests it yet.

## Files
- `thread.cpp`: the program.
- `rt_bench.sh`: Linux benchmark. Measures only the isolated core 6; all load runs on cores
  0-5,7. Each run writes `results/<time>_<mode>[_quick][_nort]/` with two files:
  - `summary.log`: run info, then one row per test (avg, p99, p99.9, max in µs, plus "RT ok",
    "RT off" or "RT FAILED" in thread mode), and the hwlatdetect result under the table.
  - `raw.log`: every tool's raw output, only for debugging.
- `summarize.sh`: compares any two runs' `summary.log` side by side.
- `sim_robot.h`: the simulated joint (see above).
- `sensors.h`: the simulated encoder and gyro (see above).
- `estimators.h`: speed estimators built on the sensors (see above).
- `sim_check.cpp`: checks `sim_robot.h` against the exact formulas for constant torque from
  rest (speed within 0.1%, angle within 2%), and that angle → counts → angle in `sensors.h`
  lands within half a count. For the gyro: with randomness off, a reading is exactly truth +
  0.02; over 500 seeds, the bias spread after 1 s is within 15% of drift * sqrt(1 s).
  Exits non-zero (assert) on failure.
- `.gitignore`: keeps the `thread` and `sim_check` binaries and `results/` out of git.

## How to build and run
    g++ -std=c++17 -O2 -pthread thread.cpp -o thread   # Mac and Linux
    g++ -std=c++17 sim_check.cpp -o sim_check && ./sim_check   # silent = pass
    sudo ./thread --rt --cpu 6       # Ctrl-C stops it and prints the stats
    ./rt_bench.sh                    # Linux: kernel baseline with cyclictest
    ./rt_bench.sh --thread           # Linux: same tests with this program
    ./rt_bench.sh --thread --no-rt   # the program without --rt/--cpu
    ./rt_bench.sh --quick            # any mode: skip the soak and hwlatdetect
    ./summarize.sh results/<A> results/<B>

**One-time Linux setup: isolate core 6.** Add the following to the kernel boot command line
(`GRUB_CMDLINE_LINUX` in `/etc/default/grub`), then run `update-grub` and reboot:
`isolcpus=6 nohz_full=6 rcu_nocbs=6 irqaffinity=0-5,7`. Then check
`/sys/devices/system/cpu/cpu6/topology/thread_siblings_list`. If it lists another CPU besides
6, that's a hyperthread twin sharing core 6's hardware. Isolate it too, or turn SMT off.

## The tests (load on cores 0-5,7; only core 6 measured)
| # | Test | stress-ng load | Time | Stresses |
|---|---|---|---|---|
| 01 | idle | none | 2 min | nothing, the best case |
| 02 | kernel_work | `--switch 4 --pipe 2` | 2 min | scheduler, cross-core interrupts |
| 03 | disk_io | `--hdd 2` | 2 min | block layer, disk interrupts |
| 04 | memory | `--stream 7` | 2 min | shared L3 cache, memory bus |
| 05 | combined_robot | `--cpu 2 --hdd 1 --switch 2 --vm 1 --vm-bytes 25%` | 2 min | a typical robot computer |
| 06 | soak_45min | `--cpu 7 --hdd 1 --switch 2 --vm 1 --vm-bytes 25%` | 45 min | all load cores busy, rare spikes |
| 07 | hwlatdetect | none | 5 min | hardware/firmware stalls (not compared) |

## Where things stand
Everything builds and runs on the Mac. Nothing has run on Linux yet since the 2026-10-03
redesign, so there's no baseline. The cyclictest parsing matches cyclictest's source code, but
hasn't been checked against real output.

cyclictest's latency and the program's `jitter` measure the same thing. Both run one thread
on core 6 at priority 80. Their raw output differs, but the `summary.log` rows are identical
in meaning, and those are all that gets compared.

## What depends on what
The only places where one file relies on another's exact output. Change one side, change the
other, or tell Claude.
1. `thread.cpp` → `rt_bench.sh`: the lines `SCHED_FIFO priority 80 applied`,
   `control thread pinned to CPU 6`, and `jitter: … avg= p99= p99.9= max= …` (keys in any order).
2. cyclictest → `rt_bench.sh`: the `-h` histogram and its `# Avg/Max Latencies` and
   `# Histogram Overflows` lines.
3. hwlatdetect → `rt_bench.sh`: the `Max Latency:` line.
4. `summary.log` → `summarize.sh`: the row format (`name  value us … notes`) and the header keys
   `mode:`, `options:`, `git commit:`, `build flags:`, `rt cpu:`.

## Decisions and why
- **Latest-value ring for vision:** control only wants the newest sample.
- **Absolute deadlines (`sleep_until`):** a late tick doesn't push later ticks back.
- **`-O2`, built by the script:** flags are fixed and recorded, so no stale or debug builds.
- **The benchmark stops the program with SIGINT** (`timeout -s INT`), so it shuts down
  normally and prints its stats.
- **Only isolated core 6 is measured:** the RT loop runs alone there, so it's the only
  latency that matters.
- **Priority 80 for both tools:** a fair comparison, above PREEMPT_RT's IRQ threads (50) and
  below the kernel's 99.
- **avg / p99 / p99.9 / max:** RT is judged by the tail. p99 and p99.9 for cyclictest come
  from its `-h400` histogram, with samples ≥400 µs still counted, so the tail isn't flattered.
- **`--stream 7` memory test:** shared cache and memory bandwidth are the main ways other
  cores reach an isolated core. A huge `--vm-bytes` would just measure swapping.
- **Skip 100 warm-up ticks:** simpler than setting up the thread before its loop.
- **Two files per run, `--quick`, `--no-rt`:** the summary is what matters. The raw output is
  kept in one file for debugging.
- **Keep it simple** (see `CLAUDE.md`).

## Open questions / known issues
- **The log can lose data:** `log_ring` keeps only the latest value. Under heavy load the log
  thread falls behind and ticks are lost, possibly including the worst one. Fix: SPSC queue.
- **Possible torn read:** can the writer overwrite a slot while the reader is copying it?
- `head`/`tail` are `size_t` but loaded into `int`. `read()` uses a seq_cst load where
  acquire may be enough.
- The log thread busy-waits (on the load cores, not core 6).

## What's next
1. Isolate core 6 on the Linux machine and check for an SMT twin.
2. `./rt_bench.sh --quick`: check the cyclictest rows have real numbers, not `n/a`. Then
   `./rt_bench.sh --thread --quick` and `summarize.sh`: every row should say "RT ok". Then the
   full runs.
3. Build an SPSC queue for `log_ring`.
4. Drive `SimRobot` from the control loop.

## Change log
- **2026-10-16:** added `estimators.h` with `DiffEstimator` (speed from encoder count
  differences); `sim_check.cpp` includes it but doesn't test it yet.
- **2026-10-14:** `Sensors` renamed to `Encoder`; added `Gyro` (drifting bias plus noise) to
  `sensors.h` and two checks for it in `sim_check.cpp`.
- **2026-10-14:** added `sensors.h` (simulated 4096-count encoder) and a round-trip check for
  it in `sim_check.cpp`.
- **2026-10-14:** added `sim_robot.h` (simulated joint) and `sim_check.cpp` (its accuracy
  check); `thread.cpp` includes the header. `<atomic>` is now included in `thread.cpp`, and
  `results/` is ignored by git.
- **2026-10-04:** trimmed this file.
- **2026-10-03:** two files per run, `--quick`, `--no-rt`. Measure only isolated core 6 at
  priority 80, with a new test list and avg/p99/p99.9/max. `thread.cpp` gained `--cpu`
  pinning, priority 80, the warm-up skip, and avg/p99.9.
- **2026-10-02:** added `summary.log` and `summarize.sh`, fixed test 08's stress-ng arguments,
  added the beginner walkthrough with `[STEP N]` markers, and the pseudocode and "Keep it
  simple" rules in `CLAUDE.md`.
- **2026-09-30:** `--thread` mode, `-O2` builds, binary untracked, `mlockall`, `rt_bench.sh`
  and the docs added (fcc93f6).
- **2026-09-26:** first working pipeline (646ac73).
