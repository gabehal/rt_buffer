#!/usr/bin/env bash
# rt_bench.sh
# Reusable real-time benchmark battery for jitter_lab / cpp-realtime-crash-course.
#
# Run this now against cyclictest to baseline the kernel. Once the SPSC
# buffer is built, copy this file and swap the cyclictest line inside
# run_test() for your own program's binary, keep every stress-ng command
# below byte-for-byte identical, that's what makes the before/after
# subtraction (kernel-only vs kernel+your code) valid.
set -uo pipefail

RESULTS_DIR="results/$(date +%Y-%m-%d_%H%M%S)"
mkdir -p "$RESULTS_DIR"

# --- metadata: always capture this next to the numbers, or they're meaningless later ---
{
  echo "date: $(date -Iseconds)"
  echo "kernel: $(uname -a)"
  echo "cpu governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
  echo "on AC power: $(cat /sys/class/power_supply/AC*/online 2>/dev/null || echo unknown)"
  if command -v git >/dev/null 2>&1 && git rev-parse HEAD >/dev/null 2>&1; then
    echo "git commit: $(git rev-parse HEAD)"
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

run_test () {
  local name="$1" duration="$2"
  shift 2
  local pid=""
  echo ">>> $name"
  if [ "$#" -gt 0 ]; then
    stress-ng -t "$duration" "$@" &
    pid=$!
  fi
  sudo cyclictest -m -Sp99 -i1000 -d0 -D "$duration" > "$RESULTS_DIR/$name.log"
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
sudo cyclictest -m -Sp99 -i1000 -d0 -h400 -D 45m > "$RESULTS_DIR/09_soak_45min.log"
wait "$SOAK_PID" 2>/dev/null

# ===== hwlatdetect: hardware/firmware latency, independent of any load, run it alone =====
echo ">>> 10_hwlatdetect"
sudo /usr/sbin/hwlatdetect --duration=5m > "$RESULTS_DIR/10_hwlatdetect.log"

echo "Done. Results in $RESULTS_DIR"
