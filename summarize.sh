#!/usr/bin/env bash
# summarize.sh
# Compare two rt_bench.sh runs side by side, using the summary.log in each results folder.
#
# Usage:
#   ./summarize.sh <baseline folder> <thread folder>
#   e.g. ./summarize.sh results/2026-10-02_101500_cyclictest results/2026-10-02_120000_thread
#   add "> compare.log" to save the output.
#
# A plain-English walkthrough is at the bottom. Its [STEP N] numbers match the code.

# ----- [STEP 1] check the arguments -----
set -uo pipefail
if [ "$#" -ne 2 ] || [ ! -f "$1/summary.log" ] || [ ! -f "$2/summary.log" ]; then
  echo "usage: $0 <baseline folder> <thread folder>   (each must contain summary.log)" >&2
  exit 1
fi

# ----- [STEP 2] read both summaries and print them side by side -----
# NR == FNR is only true while awk reads the first file, so that's file A
awk '
  NR == FNR { f = 1 } NR != FNR { f = 2 }
  # the header lines worth showing; the rest of the run info stays in summary.log
  /^(rt_bench summary|mode|options|git commit|build flags|rt cpu):/ { head[f] = head[f] "     " $0 "\n" }
  # table rows start with a test number like "01_". Each value is followed by its unit:
  #   01_idle   4 us   9 us   15 us   45 us   RT ok
  #   $1        $2     $4     $6      $8      $10...
  # (the hwlatdetect line under the table does not start with a number, so it is skipped)
  /^[0-9][0-9]_/ {
    avg[f, $1] = $2; p99[f, $1] = $4; p999[f, $1] = $6; mx[f, $1] = $8
    note = ""; for (i = 10; i <= NF; i++) note = note (note == "" ? "" : " ") $i
    notes[f, $1] = (note == "" ? "-" : note)        # cyclictest rows have no notes
    # every test from both files, A first. A --quick run has no 06, so 06 must
    # still show up when only the other run has it.
    if (!($1 in seen)) { seen[$1] = 1; order[++count] = $1 }
  }
  # "A / B us", with n/a for a test that one of the runs does not have
  function pair(a, b) { return (a == "" ? "n/a" : a) " / " (b == "" ? "n/a" : b) " us" }
  # B minus A, e.g. "+85 us". "-" when either side is "n/a" or ">=400" (no exact value)
  function diff(a, b) {
    if (a !~ /^[0-9]+$/ || b !~ /^[0-9]+$/) return "-"
    return (b - a > 0 ? "+" : "") (b - a) " us"
  }
  END {
    printf "A:\n%sB:\n%s", head[1], head[2]
    print "latency = how late the 1 ms wake-up was, in microseconds (us). diff = B - A"
    print ""
    fmt = "%-18s %14s %14s %15s %10s %15s %10s  %s\n"
    printf fmt, "test", "avg A / B", "p99 A / B", "p99.9 A / B", "p99.9 diff", "max A / B", "max diff", "notes A | B"
    for (i = 1; i <= count; i++) {
      t = order[i]
      na = notes[1, t]; if (na == "") na = "n/a"
      nb = notes[2, t]; if (nb == "") nb = "n/a"
      printf fmt, t, pair(avg[1, t], avg[2, t]), pair(p99[1, t], p99[2, t]),
             pair(p999[1, t], p999[2, t]), diff(p999[1, t], p999[2, t]),
             pair(mx[1, t], mx[2, t]), diff(mx[1, t], mx[2, t]), na " | " nb
    }
  }' "$1/summary.log" "$2/summary.log"

# =============================================================================
# PLAIN-ENGLISH WALKTHROUGH (pseudocode, not run)
# =============================================================================
# [STEP 1] CHECK THE ARGUMENTS
#      need exactly two folders, and each must contain a summary.log
#      otherwise -> print usage, quit
#
# [STEP 2] READ BOTH SUMMARIES, PRINT THEM SIDE BY SIDE
#      for each file (A = baseline, B = thread):
#          keep its key header lines (folder, mode, options, commit, build, rt cpu)
#          for each test row: remember avg, p99, p99.9, max and the notes
#      print both headers, then one line per test, every test from both files (A's first):
#          avg, p99, p99.9 and max as A / B, plus p99.9 diff and max diff
#          notes as A | B, so "RT ok", "RT off" or "RT FAILED" shows for both runs
#          a test only one run has (e.g. the soak, missing from a --quick run) -> n/a
#          (the hwlatdetect line isn't compared: it measures the machine, not the loop)
#          diff = B - A, only when both are exact numbers ("n/a" or ">=400" -> "-")
#      all numbers are microseconds
# =============================================================================
