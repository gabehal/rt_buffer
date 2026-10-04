#!/usr/bin/env bash
# rt_bench.sh
# Reusable real-time benchmark battery for jitter_lab / cpp-realtime-crash-course.
#
# Usage:
#   ./rt_bench.sh            baseline the kernel with cyclictest
#   ./rt_bench.sh --thread   build thread.cpp and run it (--rt) in place of cyclictest
#
# Only one core is measured: RT_CPU (core 6), which should be isolated from the
# kernel's scheduler (see PROJECT_CONTEXT.md). All stress-ng load runs on the other
# cores (HOUSEKEEPING_CPUS), so the numbers show how much the rest of the machine
# leaks into the isolated core.
#
# Every run ends by writing summary.log (avg/p99/p99.9/max per test) into its results
# folder. Compare two runs with: ./summarize.sh <baseline folder> <thread folder>
#
# Keep every stress-ng command below byte-for-byte identical between modes,
# that's what makes the before/after subtraction (kernel-only vs kernel+your
# code) valid.
#
# New to bash? A plain-English walkthrough of the whole file is at the bottom.
# Its [STEP N] numbers match the [STEP N] markers in the code.

# ----- [STEP 1] safety settings -----
# -u: using an unset variable is an error (catches typos like $RESULT_DIR)
# -o pipefail: a pipeline fails if any command in it fails, not just the last one
# no -e on purpose: if one test fails, the rest of the battery should still run
set -uo pipefail

# ----- [STEP 2] read the command line -----
MODE="cyclictest"
# ${1:-} means "the first argument, or empty if there isn't one". Plain $1 would
# crash under set -u when the script is run with no arguments.
case "${1:-}" in
  "")       ;;
  --thread) MODE="thread" ;;
  *)        echo "usage: $0 [--thread]" >&2; exit 1 ;;
esac

# ----- [STEP 3] settings and our own folder -----
# the one place to change which core is measured, which cores get the load,
# and the real-time priority used by both cyclictest and the program
RT_CPU=6
HOUSEKEEPING_CPUS="0-5,7"
RT_PRIO=80
# stress-ng --hdd writes its temporary files here, not into the current directory
STRESS_TMP="$HOME/stress_tmp"

# the folder this script lives in, as an absolute path, so thread.cpp is found
# even when the script is started from another directory (e.g. ../rt_prep/rt_bench.sh)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_FLAGS="-std=c++17 -O2 -pthread"
THREAD_BIN="$SCRIPT_DIR/thread"

# ----- [STEP 4] build (thread mode only) -----
# build with fixed flags, so the numbers are always from a known build
if [ "$MODE" = "thread" ]; then
  echo "Building: g++ $BUILD_FLAGS thread.cpp"
  # $BUILD_FLAGS is deliberately unquoted: it has to split into three separate
  # flags. Quoted, g++ would get one argument "-std=c++17 -O2 -pthread" and fail.
  # shellcheck disable=SC2086  # BUILD_FLAGS is meant to split into separate flags
  g++ $BUILD_FLAGS "$SCRIPT_DIR/thread.cpp" -o "$THREAD_BIN" || { echo "build failed" >&2; exit 1; }
fi

# ----- [STEP 5] make a results folder -----
# results/ is relative to where you run the script from, not the script's folder
# the timestamp makes every run a new folder, so old results are never overwritten
RESULTS_DIR="results/$(date +%Y-%m-%d_%H%M%S)_$MODE"
mkdir -p "$RESULTS_DIR" "$STRESS_TMP"

# ----- [STEP 6] write metadata.txt and start summary.log -----
# --- metadata: always capture this next to the numbers, or they're meaningless later ---
# everything printed inside { ... } goes into the one metadata.txt file
{
  echo "mode: $MODE"
  echo "date: $(date -Iseconds)"
  echo "kernel: $(uname -a)"
  # these /sys files don't exist on every machine (VMs, desktops, some ARM boards).
  # 2>/dev/null hides the error and "|| echo unknown" writes a placeholder instead
  echo "cpu governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
  # AC* because the adapter's name varies by machine (AC, AC0, ACAD, ...)
  echo "on AC power: $(cat /sys/class/power_supply/AC*/online 2>/dev/null || echo unknown)"
  # only record the commit if git is installed AND we're inside a repo,
  # otherwise git would print an error into the metadata
  if command -v git >/dev/null 2>&1 && git rev-parse HEAD >/dev/null 2>&1; then
    echo "git commit: $(git rev-parse HEAD)"
  fi
  if [ "$MODE" = "thread" ]; then
    echo "build flags: $BUILD_FLAGS"
    echo "compiler: $(g++ --version | head -1)"
  fi
  echo "rt cpu: $RT_CPU | priority: $RT_PRIO | load cpus: $HOUSEKEEPING_CPUS"
  # what the kernel actually isolated, and core 6's hyperthread sibling (if one is listed
  # besides RT_CPU, load running on that sibling shares core 6's hardware)
  echo "isolated cpus: $(cat /sys/devices/system/cpu/isolated 2>/dev/null || echo unknown)"
  echo "rt cpu siblings (SMT): $(cat /sys/devices/system/cpu/cpu$RT_CPU/topology/thread_siblings_list 2>/dev/null || echo unknown)"
  echo "kernel cmdline: $(cat /proc/cmdline 2>/dev/null || echo unknown)"
} > "$RESULTS_DIR/metadata.txt"

# summary.log gets its header now. run_test() appends one row per test later.
ROW_FMT="%-20s %10s %10s %10s %10s   %s\n"
{
  echo "rt_bench summary: $RESULTS_DIR"
  if [ "$MODE" = "thread" ]; then
    echo "mode: thread | commit: $(git rev-parse --short HEAD 2>/dev/null) | build: $BUILD_FLAGS"
  else
    echo "mode: cyclictest | commit: $(git rev-parse --short HEAD 2>/dev/null)"
  fi
  echo "measured: cpu $RT_CPU at priority $RT_PRIO | load on cpus $HOUSEKEEPING_CPUS"
  echo "latency = how late the 1 ms wake-up was, in microseconds (us)"
  echo
  # shellcheck disable=SC2059  # ROW_FMT is our own fixed format string
  printf "$ROW_FMT" "test" "avg" "p99" "p99.9" "max" "notes"
} > "$RESULTS_DIR/summary.log"

echo "Logging to $RESULTS_DIR"

# ----- [STEP 7] warn if on battery or no core is isolated -----
# without isolation the kernel can put other work on core 6, so the numbers
# don't mean what this script assumes. Warn, but still run.
if [ -z "$(cat /sys/devices/system/cpu/isolated 2>/dev/null)" ]; then
  echo "WARNING: no isolated cores. Boot with isolcpus=$RT_CPU (see PROJECT_CONTEXT.md)."
fi

# on battery, the governor throttles for power savings, not accuracy
# the "online" file contains 1 when plugged in and 0 on battery. With no AC
# file at all (a desktop), grep fails quietly and no warning is printed.
if grep -q 0 /sys/class/power_supply/AC*/online 2>/dev/null; then
  echo "WARNING: running on battery. Plug in before benchmarking, the power-saving governor will skew every number."
fi

# ----- [STEP 8] sudo, once -----
# prompt for the password once now, then silently refresh it every minute
# for the rest of the run, sudo's own cache expires long before a 45min
# soak test finishes otherwise, and the final hwlatdetect step will fail
sudo -v
# the ( ... ) & loop runs in the background. sudo -n never prompts, it only
# refreshes. $$ is still the main script's PID inside the loop, so kill -0
# checks whether the main script is alive and stops the loop if it isn't.
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
# when the script exits for any reason (finished, error, Ctrl-C), stop the loop
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

# ----- [STEP 9] define measure() -----
# the only place the two modes differ.
# thread mode: SIGINT at the deadline triggers the program's normal shutdown,
# so its stats land in the log. 2>&1 keeps the mlockall/SCHED_FIFO lines,
# which show whether RT mode actually took effect.
measure () {
  local name="$1" duration="$2"
  if [ "$MODE" = "thread" ]; then
    # timeout has to run under sudo too: a normal user can't signal a root process.
    # timeout exits with code 124 when time runs out. That's expected here, not an error.
    # timeout only sends SIGINT. If the program ever stops handling SIGINT, this line
    # waits forever. (timeout -k 10s would force-kill it 10s later.)
    # --cpu tells the program which core to pin its control thread to
    sudo timeout -s INT "$duration" "$THREAD_BIN" --rt --cpu "$RT_CPU" > "$RESULTS_DIR/$name.log" 2>&1
  else
    # -m lock memory, -p priority (same as the program's), -i1000 wake every 1000 us
    # (1 ms, same period as the control loop), -a pin to RT_CPU, -t1 just one thread
    # -q: no live status lines, only the final result (otherwise the log fills with updates)
    # -h400: histogram of 1 us buckets from 0 to 399 us. summary_row() works out p99/p99.9
    #        from it. Anything 400 us or more is only counted on "# Histogram Overflows:".
    sudo cyclictest -m -p"$RT_PRIO" -i1000 -a"$RT_CPU" -t1 -q -h400 -D "$duration" > "$RESULTS_DIR/$name.log"
  fi
}

# ----- [STEP 10] define summary_row() and run_test() -----
# append one row to summary.log for a test that just finished: avg, p99, p99.9, max (us)
summary_row () {
  local name="$1" log="$RESULTS_DIR/$1.log" nums="" note=""
  if [ ! -s "$log" ]; then
    # -s: exists and isn't empty (a crashed test can leave an empty log)
    note="log missing or empty"
  elif [ "$MODE" = "thread" ]; then
    # read from the program's own line, any order of keys:
    #   jitter: n=120000 min=9 avg=12 p50=11 p99=30 p99.9=45 max=80 (us)
    # a key the program doesn't print yet shows up as n/a
    nums="$(awk '
      function get(k) { return (k in v) ? v[k] : "n/a" }
      /^jitter: n=/ { for (i = 2; i <= NF; i++) { split($i, kv, "="); v[kv[1]] = kv[2] }
                      print get("avg"), get("p99"), get("p99.9"), get("max") }' "$log")"
    # RT only counts if the priority AND the pinning to the isolated core both worked
    if grep -q "SCHED_FIFO priority $RT_PRIO applied" "$log" && grep -q "pinned to CPU $RT_CPU" "$log"; then
      note="RT ok"
    else
      note="RT FAILED"
    fi
  else
    # cyclictest reports avg and max itself, p99/p99.9 come from the -h400 histogram:
    #   000003 001200        bucket (us), how many wake-ups were that late
    #   # Avg Latencies: 00004
    #   # Max Latencies: 00045
    #   # Histogram Overflows: 00001
    # one thread (-t1), so each line has a single value and $NF is it.
    # Samples of 400 us or more aren't in any bucket, only in the overflow count. They still
    # go into the total, or the tail would look better than it is.
    nums="$(awk '
      /^[0-9][0-9][0-9][0-9][0-9][0-9] / { n++; count[n] = $NF; total += $NF }
      /^# Histogram Overflows:/ { total += $NF }
      /^# Avg Latencies:/ { avg = $NF + 0 }
      /^# Max Latencies:/ { max = $NF + 0 }
      END {
        p99 = ">=400"; p999 = ">=400"     # stays that way if the point is in the overflow
        for (b = 1; b <= n; b++) {
          cum += count[b]
          if (p99  == ">=400" && cum >= 0.99  * total) p99  = b - 1   # bucket b holds (b-1) us
          if (p999 == ">=400" && cum >= 0.999 * total) p999 = b - 1
        }
        print avg, p99, p999, max
      }' "$log")"
  fi
  # no numbers found (missing log, or the program printed "jitter is empty")
  [ -z "$nums" ] && nums="n/a n/a n/a n/a"
  # shellcheck disable=SC2086  # split "avg p99 p99.9 max" into $1..$4 on purpose
  set -- $nums
  # shellcheck disable=SC2059
  printf "$ROW_FMT" "$name" "$1 us" "$2 us" "$3 us" "$4 us" "$note" >> "$RESULTS_DIR/summary.log"
}

run_test () {
  local name="$1" duration="$2"
  shift 2
  local pid=""
  echo ">>> $name"
  # no extra args means "no load" (the idle baseline), so don't start stress-ng at all
  if [ "$#" -gt 0 ]; then
    # & runs the load in the background, so the measurement can run at the same time.
    # taskset keeps every stress-ng worker off the measured core.
    taskset -c "$HOUSEKEEPING_CPUS" stress-ng -t "$duration" --temp-path "$STRESS_TMP" "$@" &
    pid=$!
  fi
  measure "$name" "$duration"
  # wait for the load to exit, so it can't spill into the next test.
  # the -n check skips this for the idle test: there's no load to wait for, and
  # wait "" would print an error. Don't change it to a bare "wait": that waits for
  # every background job, including the sudo keep-alive loop, which never ends.
  [ -n "$pid" ] && wait "$pid" 2>/dev/null
  summary_row "$name"
}

# ----- [STEP 11] run the tests, 2 minutes each -----
run_test "01_idle"           "2m"
# context switches and pipe syscalls: scheduler and IPI traffic in the kernel
run_test "02_kernel_work"    "2m" --switch 4 --pipe 2
# disk writes: block layer work and disk interrupts
run_test "03_disk_io"        "2m" --hdd 2
# memory bandwidth (STREAM) on all 7 load cores: fights core 6 for the shared
# L3 cache and memory bus, the main way other cores still reach an isolated core
run_test "04_memory"         "2m" --stream 7
# a bit of everything, roughly what the rest of a robot computer does
run_test "05_combined_robot" "2m" --cpu 2 --hdd 1 --switch 2 --vm 1 --vm-bytes 25%

# ----- [STEP 12] soak test, 45 minutes -----
# the combined load with --cpu 7, so every load core is busy: a deliberate worst case.
# Rare spikes only show up over long runs.
run_test "06_soak_45min"     "45m" --cpu 7 --hdd 1 --switch 2 --vm 1 --vm-bytes 25%

# ----- [STEP 13] hardware check, 5 minutes, no load -----
# hwlatdetect: hardware/firmware stalls (e.g. SMIs), independent of any load, run it alone.
# It measures the machine, not the loop, so its result goes under the table, not in it.
# full path because /usr/sbin often isn't on a normal user's PATH
echo ">>> 07_hwlatdetect"
sudo /usr/sbin/hwlatdetect --duration=5m > "$RESULTS_DIR/07_hwlatdetect.log"
# the "Max Latency:" line holds a value like "12us", or "Below threshold"
gap="$(awk -F': ' '/^Max Latency:/ { print $2 }' "$RESULTS_DIR/07_hwlatdetect.log")"
printf "\nhwlatdetect worst gap (machine only, not compared): %s\n" "${gap:-n/a}" >> "$RESULTS_DIR/summary.log"

# ----- [STEP 14] show summary.log, print where the results are, and exit -----
cat "$RESULTS_DIR/summary.log"
echo "Done. Results in $RESULTS_DIR"

# =============================================================================
# PLAIN-ENGLISH WALKTHROUGH (pseudocode, not run)
# =============================================================================
# Each [STEP N] below matches a "[STEP N]" marker in the code above.
# Search the file for "[STEP 9]" to jump straight to that part of the code.
#
# GOAL
#   Measure how late a 1 ms real-time loop on the isolated core 6 wakes up while
#   the other cores are under different kinds of load. Run it once with cyclictest
#   (the kernel on its own) and once with our program (--thread). The difference
#   between the two runs is the cost our code adds.
#
# [STEP 1] SAFETY SETTINGS
#      treat unset variables as errors           (catches typos)
#      treat a failure anywhere in a pipe as a failure
#      do NOT stop on errors                     (one bad test shouldn't kill a 1-hour run)
#
# [STEP 2] READ THE COMMAND LINE
#      if no argument          -> mode = cyclictest
#      if argument is --thread -> mode = thread
#      anything else           -> print usage, quit
#                                 (this happens before any sudo prompt or folder creation)
#
# [STEP 3] SETTINGS AND OUR OWN FOLDER
#      measured core = 6, load cores = 0-5,7, real-time priority = 80
#      stress-ng temp folder = ~/stress_tmp
#      script_dir = absolute path of the folder this script is in
#      (so thread.cpp is found no matter which directory you run it from)
#
# [STEP 4] BUILD (thread mode only)
#      compile thread.cpp with fixed flags: -std=c++17 -O2 -pthread
#      if the compile fails -> print "build failed", quit
#      (always building here means the results never come from a stale or debug binary)
#
# [STEP 5] MAKE A RESULTS FOLDER
#      folder = results/<date_time>_<mode>   (and make sure ~/stress_tmp exists)
#      (a new folder every run, so nothing is overwritten,
#       and the name tells you which mode produced it)
#
# [STEP 6] WRITE metadata.txt, START summary.log
#      mode, date, kernel version
#      CPU governor        (or "unknown" if this machine doesn't expose it)
#      plugged in or not   (or "unknown")
#      git commit          (only if we're inside a git repo)
#      build flags + compiler version (thread mode only)
#      measured core, priority, load cores
#      which cores the kernel isolated, core 6's hyperthread sibling, boot options
#      (numbers without this context can't be compared later)
#      summary.log: header (folder, mode, commit, build, core) and column titles.
#      The rows get added by run_test, one per test.
#
# [STEP 7] WARN IF NO CORE IS ISOLATED, OR ON BATTERY
#      if the kernel isolated no cores -> print a warning, but keep going
#      (without isolation the kernel can schedule other work on core 6)
#      if the power adapter reports 0 -> print a warning, but keep going
#      (battery mode slows the CPU down to save power, which skews timing)
#
# [STEP 8] SUDO, ONCE
#      ask for the password now
#      start a background loop: every 60 s refresh sudo,
#                               stop if the main script has died
#      when the script exits for any reason -> stop that loop
#      (otherwise sudo times out partway through the 45-minute soak,
#       and the later steps that need root fail)
#
# [STEP 9] DEFINE measure(name, duration)
#      if mode is thread:
#          run ./thread --rt --cpu 6 as root   (it pins its control thread to core 6)
#          after <duration>, send it Ctrl-C (SIGINT)
#          -> it shuts down normally and prints its stats
#          save its normal output AND its error output to <name>.log
#          (the error output says whether real-time mode actually took effect)
#      else:
#          run cyclictest as root: 1 ms period, priority 80, ONE thread pinned to
#          core 6, memory locked, quiet, with a histogram up to 400 us, for <duration>
#          save its output to <name>.log
#          (the histogram is what lets summary_row work out p99 and p99.9)
#
# [STEP 10] DEFINE summary_row(name) AND run_test(name, duration, load options...)
#      summary_row: read the test's log, append one row to summary.log
#          log missing or empty -> n/a
#          thread mode     -> avg / p99 / p99.9 / max from the program's "jitter:" line
#                             (any value it doesn't print -> n/a)
#                             note "RT ok" only if priority 80 was applied AND the
#                             control thread was pinned to core 6, else "RT FAILED"
#          cyclictest mode -> avg and max from its own summary lines
#                             p99 / p99.9 from the histogram:
#                             total = all bucket counts + overflows (400 us or more)
#                             walk the buckets from 0 us upward, adding up counts
#                             p99 / p99.9 = first bucket where the sum reaches 99% / 99.9%
#                             never reached -> ">=400" (it's in the overflow)
#      run_test:
#      print the test name
#      if load options were given:
#          start stress-ng with those options in the background, for <duration>,
#          on the load cores only (never core 6)
#      measure(name, duration)                  (runs at the same time as the load)
#      if a load was started: wait for it to finish
#          (so it doesn't leak into the next test)
#      summary_row(name)                        (one row per test, written as it finishes)
#
# [STEP 11] RUN THE TESTS, 2 minutes each
#      01 idle            no load at all                   -> best case
#      02 kernel work     context switches + pipes         -> scheduler / IPI traffic
#      03 disk I/O        disk writes                      -> block layer + disk interrupts
#      04 memory          memory bandwidth on 7 cores      -> shared cache / memory bus
#      05 combined robot  a bit of everything              -> roughly a real robot computer
#
# [STEP 12] SOAK TEST, 45 minutes
#      run_test with the combined load, but every load core busy, for 45 minutes
#      (rare spikes only show up over long runs. The worst case is what matters.)
#
# [STEP 13] HARDWARE CHECK, 5 minutes, no load
#      run hwlatdetect as root
#      (finds stalls caused by the hardware or firmware itself, e.g. SMIs.
#       If these are big, no software change can fix them.)
#      add its worst gap as one line UNDER the summary table
#      (it measures the machine, not the loop, so it isn't compared)
#
# [STEP 14] SHOW summary.log, PRINT where the results are, and exit
#      (the exit triggers the cleanup from [STEP 8], which stops the sudo loop)
# =============================================================================
