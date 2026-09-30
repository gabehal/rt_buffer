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
set -uo pipefail

MODE="cyclictest"
case "${1:-}" in
  "")       ;;
  --thread) MODE="thread" ;;
  *)        echo "usage: $0 [--thread]" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_FLAGS="-std=c++17 -O2 -pthread"
THREAD_BIN="$SCRIPT_DIR/thread"

# build with fixed flags, so the numbers are always from a known build
if [ "$MODE" = "thread" ]; then
  echo "Building: g++ $BUILD_FLAGS thread.cpp"
  # shellcheck disable=SC2086  # BUILD_FLAGS is meant to split into separate flags
  g++ $BUILD_FLAGS "$SCRIPT_DIR/thread.cpp" -o "$THREAD_BIN" || { echo "build failed" >&2; exit 1; }
fi

RESULTS_DIR="results/$(date +%Y-%m-%d_%H%M%S)_$MODE"
mkdir -p "$RESULTS_DIR"

# --- metadata: always capture this next to the numbers, or they're meaningless later ---
{
  echo "mode: $MODE"
  echo "date: $(date -Iseconds)"
  echo "kernel: $(uname -a)"
  echo "cpu governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
  echo "on AC power: $(cat /sys/class/power_supply/AC*/online 2>/dev/null || echo unknown)"
  if command -v git >/dev/null 2>&1 && git rev-parse HEAD >/dev/null 2>&1; then
    echo "git commit: $(git rev-parse HEAD)"
  fi
  if [ "$MODE" = "thread" ]; then
    echo "build flags: $BUILD_FLAGS"
    echo "compiler: $(g++ --version | head -1)"
  fi
} > "$RESULTS_DIR/metadata.txt"

echo "Logging to $RESULTS_DIR"

# on battery, the governor throttles for power savings, not accuracy
if grep -q 0 /sys/class/power_supply/AC*/online 2>/dev/null; then
  echo "WARNING: running on battery. Plug in before benchmarking, the power-saving governor will skew every number."
fi

# prompt for the password once now, then silently refresh it every minute
# for the rest of the run, sudo's own cache expires long before a 45min
# soak test finishes otherwise, and the final hwlatdetect step will fail
sudo -v
( while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done ) &
SUDO_KEEPALIVE_PID=$!
trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT

# the only place the two modes differ. Extra args go to cyclictest only.
# thread mode: SIGINT at the deadline triggers the program's normal shutdown,
# so its stats land in the log. 2>&1 keeps the mlockall/SCHED_FIFO lines,
# which show whether RT mode actually took effect.
measure () {
  local name="$1" duration="$2"
  shift 2
  if [ "$MODE" = "thread" ]; then
    sudo timeout -s INT "$duration" "$THREAD_BIN" --rt > "$RESULTS_DIR/$name.log" 2>&1
  else
    sudo cyclictest -m -Sp99 -i1000 -d0 "$@" -D "$duration" > "$RESULTS_DIR/$name.log"
  fi
}

run_test () {
  local name="$1" duration="$2"
  shift 2
  local pid=""
  echo ">>> $name"
  if [ "$#" -gt 0 ]; then
    stress-ng -t "$duration" "$@" &
    pid=$!
  fi
  measure "$name" "$duration"
  [ -n "$pid" ] && wait "$pid" 2>/dev/null
}

# ===== Priority 1: always run these =====
run_test "01_idle_baseline"      "2m"
run_test "02_combined_realistic" "2m" --cpu 4 --io 2 --vm 1 --vm-bytes 256M
run_test "03_combined_oversub"   "2m" --cpu 16 --io 2 --vm 1 --vm-bytes 256M

# ===== Priority 2: isolate each subsystem, run when you need to know which one dominates =====
run_test "04_cpu_only"       "2m" --cpu 4
run_test "05_io_only"        "2m" --io 2
run_test "06_vm_only"        "2m" --vm 1 --vm-bytes 256M
run_test "07_switch_only"    "2m" --switch 4
run_test "08_interrupt_only" "2m" --class interrupt --sequential

# ===== Priority 1: soak, with a histogram for plotting and the SMI/MCE flag on =====
echo ">>> 09_soak_45min"
stress-ng -t 45m --cpu 4 --io 2 --vm 1 --vm-bytes 256M --interrupts &
SOAK_PID=$!
measure "09_soak_45min" "45m" -h400
wait "$SOAK_PID" 2>/dev/null

# ===== hwlatdetect: hardware/firmware latency, independent of any load, run it alone =====
echo ">>> 10_hwlatdetect"
sudo /usr/sbin/hwlatdetect --duration=5m > "$RESULTS_DIR/10_hwlatdetect.log"

echo "Done. Results in $RESULTS_DIR"
