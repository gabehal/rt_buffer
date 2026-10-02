#!/usr/bin/env bash
# rt_bench.sh
# Reusable real-time benchmark battery for jitter_lab / cpp-realtime-crash-course.
#
# Usage:
#   ./rt_bench.sh            baseline the kernel with cyclictest
#   ./rt_bench.sh --thread   build thread.cpp and run it (--rt) in place of cyclictest
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

# ----- [STEP 3] find our own folder -----
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
mkdir -p "$RESULTS_DIR"

# ----- [STEP 6] write metadata.txt -----
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
} > "$RESULTS_DIR/metadata.txt"

echo "Logging to $RESULTS_DIR"

# ----- [STEP 7] warn if on battery -----
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
# the only place the two modes differ. Extra args go to cyclictest only.
# thread mode: SIGINT at the deadline triggers the program's normal shutdown,
# so its stats land in the log. 2>&1 keeps the mlockall/SCHED_FIFO lines,
# which show whether RT mode actually took effect.
measure () {
  local name="$1" duration="$2"
  # drop name and duration, so "$@" now holds only the extra cyclictest args
  shift 2
  if [ "$MODE" = "thread" ]; then
    # timeout has to run under sudo too: a normal user can't signal a root process.
    # timeout exits with code 124 when time runs out. That's expected here, not an error.
    # timeout only sends SIGINT. If the program ever stops handling SIGINT, this line
    # waits forever. (timeout -k 10s would force-kill it 10s later.)
    sudo timeout -s INT "$duration" "$THREAD_BIN" --rt > "$RESULTS_DIR/$name.log" 2>&1
  else
    # -m lock memory, -S one thread per CPU, -p99 priority 99, -i1000 wake every
    # 1000 us (1 ms, same period as the control loop), -d0 same interval on every thread
    sudo cyclictest -m -Sp99 -i1000 -d0 "$@" -D "$duration" > "$RESULTS_DIR/$name.log"
  fi
}

# ----- [STEP 10] define run_test() -----
run_test () {
  local name="$1" duration="$2"
  shift 2
  local pid=""
  echo ">>> $name"
  # no extra args means "no load" (the idle baseline), so don't start stress-ng at all
  if [ "$#" -gt 0 ]; then
    # & runs the load in the background, so the measurement can run at the same time
    stress-ng -t "$duration" "$@" &
    pid=$!
  fi
  measure "$name" "$duration"
  # wait for the load to exit, so it can't spill into the next test.
  # the -n check skips this for the idle test: there's no load to wait for, and
  # wait "" would print an error. Don't change it to a bare "wait": that waits for
  # every background job, including the sudo keep-alive loop, which never ends.
  [ -n "$pid" ] && wait "$pid" 2>/dev/null
}

# ----- [STEP 11] run the tests, 2 minutes each -----
# ===== Priority 1: always run these =====
run_test "01_idle_baseline"      "2m"
run_test "02_combined_realistic" "2m" --cpu 4 --io 2 --vm 1 --vm-bytes 256M
run_test "03_combined_oversub"   "2m" --cpu 16 --io 2 --vm 1 --vm-bytes 256M

# ===== Priority 2: isolate each subsystem, run when you need to know which one dominates =====
run_test "04_cpu_only"       "2m" --cpu 4
run_test "05_io_only"        "2m" --io 2
run_test "06_vm_only"        "2m" --vm 1 --vm-bytes 256M
run_test "07_switch_only"    "2m" --switch 4
# CHECK: stress-ng's --sequential normally expects a number after it (--sequential N).
# If stress-ng rejects this line, it exits right away and test 08 runs with no load.
# stress-ng runs in the background, so that error is easy to miss. Look for it in the
# terminal output. Don't edit the line without re-running the cyclictest baseline too.
run_test "08_interrupt_only" "2m" --class interrupt --sequential

# ----- [STEP 12] soak test, 45 minutes -----
# ===== Priority 1: soak, with a histogram for plotting and the SMI/MCE flag on =====
# done by hand instead of with run_test, because the measurement needs an
# extra argument (-h400, a histogram for cyclictest) that run_test can't pass
echo ">>> 09_soak_45min"
stress-ng -t 45m --cpu 4 --io 2 --vm 1 --vm-bytes 256M --interrupts &
SOAK_PID=$!
measure "09_soak_45min" "45m" -h400
wait "$SOAK_PID" 2>/dev/null

# ----- [STEP 13] hardware check, 5 minutes, no load -----
# ===== hwlatdetect: hardware/firmware latency, independent of any load, run it alone =====
# full path because /usr/sbin often isn't on a normal user's PATH
echo ">>> 10_hwlatdetect"
sudo /usr/sbin/hwlatdetect --duration=5m > "$RESULTS_DIR/10_hwlatdetect.log"

# ----- [STEP 14] print where the results are, and exit -----
echo "Done. Results in $RESULTS_DIR"

# =============================================================================
# PLAIN-ENGLISH WALKTHROUGH (pseudocode, not run)
# =============================================================================
# Each [STEP N] below matches a "[STEP N]" marker in the code above.
# Search the file for "[STEP 9]" to jump straight to that part of the code.
#
# GOAL
#   Measure how late a 1 ms real-time loop wakes up while the machine is under
#   different kinds of load. Run it once with cyclictest (the kernel on its own)
#   and once with our program (--thread). The difference between the two runs
#   is the cost our code adds.
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
# [STEP 3] FIND OUR OWN FOLDER
#      script_dir = absolute path of the folder this script is in
#      (so thread.cpp is found no matter which directory you run it from)
#
# [STEP 4] BUILD (thread mode only)
#      compile thread.cpp with fixed flags: -std=c++17 -O2 -pthread
#      if the compile fails -> print "build failed", quit
#      (always building here means the results never come from a stale or debug binary)
#
# [STEP 5] MAKE A RESULTS FOLDER
#      folder = results/<date_time>_<mode>
#      (a new folder every run, so nothing is overwritten,
#       and the name tells you which mode produced it)
#
# [STEP 6] WRITE metadata.txt
#      mode, date, kernel version
#      CPU governor        (or "unknown" if this machine doesn't expose it)
#      plugged in or not   (or "unknown")
#      git commit          (only if we're inside a git repo)
#      build flags + compiler version (thread mode only)
#      (numbers without this context can't be compared later)
#
# [STEP 7] WARN IF ON BATTERY
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
# [STEP 9] DEFINE measure(name, duration, extra args)
#      if mode is thread:
#          run ./thread --rt as root
#          after <duration>, send it Ctrl-C (SIGINT)
#          -> it shuts down normally and prints its stats
#          save its normal output AND its error output to <name>.log
#          (the error output says whether real-time mode actually took effect)
#      else:
#          run cyclictest as root: 1 ms period, priority 99, one thread per CPU,
#          memory locked, any extra args (like a histogram), for <duration>
#          save its output to <name>.log
#
# [STEP 10] DEFINE run_test(name, duration, load options...)
#      print the test name
#      if load options were given:
#          start stress-ng with those options in the background, for <duration>
#      measure(name, duration)                  (runs at the same time as the load)
#      if a load was started: wait for it to finish
#          (so it doesn't leak into the next test)
#
# [STEP 11] RUN THE TESTS, 2 minutes each
#      01 idle            no load at all            -> best case
#      02 realistic       CPU + disk + memory load
#      03 oversubscribed  far more CPU load than there are cores -> worst case
#      04-08              one kind of load at a time (CPU, disk, memory,
#                         context switches, interrupts)
#                         -> tells you which kind of load hurts the most
#
# [STEP 12] SOAK TEST, 45 minutes
#      start the realistic load plus interrupt counting, in the background
#      measure for 45 minutes, with a histogram (cyclictest only)
#      wait for the load to finish
#      (rare spikes only show up over long runs. The worst case is what matters.)
#
# [STEP 13] HARDWARE CHECK, 5 minutes, no load
#      run hwlatdetect as root
#      (finds stalls caused by the hardware or firmware itself, e.g. SMIs.
#       If these are big, no software change can fix them.)
#
# [STEP 14] PRINT where the results are, and exit
#      (the exit triggers the cleanup from [STEP 8], which stops the sudo loop)
# =============================================================================
