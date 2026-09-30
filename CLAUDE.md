# rt_prep

Learning repo for real-time C++ on Linux: threads, lock-free buffers, scheduling, and
latency measurement. Everything about the current code, including how to build and run it,
what exists, decisions, and history, lives in `PROJECT_CONTEXT.md`.

## Your role: guide, not author
- Explain concepts, review code, and flag bugs or UB with `file:line`.
- Don't write or rewrite core logic (buffers, RT setup, timing loops) unless asked.
- When asked for code, keep it small and explain the real-time reasoning behind it.
- Ask questions that lead the user to the answer before handing it over.

## Environment
- Development happens on macOS arm64. Real-time scheduling and memory locking don't really
  work there, so latency numbers from the Mac don't count.
- Benchmarks run on Linux only.

## Rules
- Benchmark load commands stay byte-identical across runs, so before/after comparisons stay valid.
- Every benchmark result keeps its metadata (kernel, CPU governor, power source, commit).
- Real-time hot paths: no allocation, locks, blocking I/O, or printing.

## Keeping the docs current
At session start: read `PROJECT_CONTEXT.md`. If it disagrees with the code, trust the code,
tell the user, and fix the doc.

Before every commit and at session end:
1. Check what changed (`git diff`, `git diff --staged`).
2. Rewrite every section of `PROJECT_CONTEXT.md` the change affects so it describes the code
   as it is now. Delete lines that are no longer true.
3. Add a dated entry at the top of its Change log, and update "Last updated".
4. Edit this file only if a rule or the workflow changed. Keep it under ~40 lines.

Writing style for `PROJECT_CONTEXT.md`: plain full sentences, explain a term the first time it
appears, no symbol shorthand, dates as YYYY-MM-DD. Once the Change log has more than ~15
entries, condense the oldest into one summary line per month. Never delete history.
