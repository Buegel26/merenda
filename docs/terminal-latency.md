# Terminal latency diagnostics

Build the optional timing probe from the repository root:

```sh
nim c -d:nimkitTerminalTrace tests/benchmark_terminal_native.nim
tests/benchmark_terminal_native cmatrix terminal /tmp/terminal-cmatrix.jsonl
tests/benchmark_terminal_native ps terminal /tmp/terminal-ps.jsonl
tests/benchmark_terminal_native cmatrix kosmo /tmp/kosmo-cmatrix.jsonl
tests/benchmark_terminal_native ps kosmo /tmp/kosmo-ps.jsonl
python3 tests/benchmarks/terminal_trace_summary.py /tmp/kosmo-cmatrix.jsonl /tmp/kosmo-ps.jsonl
```

`cmatrix` must be installed. Run the probes sequentially, with no concurrent
builds or GUI tests, to avoid contention. Each probe opens a real window, waits
for a PTY handshake, measures one second of idle process CPU, then observes
three seconds of output through `Application.run()` and its blocking native
event loop. The terminal has no keyboard focus, excluding cursor blinking from
the idle sample. The `ps` workload runs twelve commands separated by 150 ms; those
intentional gaps must not be interpreted as presentation stalls.

The trace records monotonic timestamps, thread IDs, object identities and byte
counts. It never records terminal contents. Instrumentation compiles out unless
`nimkitTerminalTrace` is defined. Its bounded buffer reports overflow rather
than silently producing an incomplete measurement.

Stages include PTY readiness, delivery to the UI queue, read/parse work, grid
synchronization, frame construction/submission, renderer work, and native
presentation submission. `poll-start` to `poll-end` includes the nonblocking
read, parsing, input/reply flushing and child-exit check. `present` is recorded
after `endFrame()` returns; it measures submission, **not display scanout or
GPU completion**. The summary correlates cumulative render IDs so skipped
submissions are included in the next frame that presents their output. Its
end-to-end correlation assumes one terminal and one native window, using the
dedicated renderer's render IDs. A fallback renderer still exposes individual
stage timings.

## Native measurements

Measured on an Apple M3 Pro, macOS 15.7.9, Nim 2.2.12, using the automatic Metal
renderer. The baseline is Merenda `2e3c2cb7` with tracing added and Terminex
`176ff0e`; the comparison uses the scheduling changes below. Both use the same
probe and window sizes. Each row is one three-second sample, not a statistical
performance guarantee. Latency is per readiness notification that produced
output, through its first grid synchronization and presentation submission.

| Window / workload | Before p95 | After p95 | Before / after presentations |
| --- | ---: | ---: | ---: |
| Kosmo / `ps` | 30.81 ms | 11.59 ms | 46 / 28 |
| Standalone / `ps` | 26.17 ms | 10.81 ms | 54 / 24 |
| Kosmo / `cmatrix -u 1` | 16.92 ms | 17.49 ms | 237 / 236 |
| Standalone / `cmatrix -u 1` | 20.24 ms | 22.19 ms | 236 / 233 |

In these paired samples, coalescing reduced redundant `ps` frames and its latency
tail. Continuous
`cmatrix` throughput stays approximately unchanged; this change does not remove
its rendering cost. In the Kosmo baseline, p95 readiness-to-UI delivery was
0.15 ms, read/parse was 0.09 ms and grid synchronization was 0.31 ms, versus
8.74 ms for frame construction/submission and 6.34 ms for renderer work. These
stages overlap across frames, so their percentiles should not be added.
The sampled path does not show a systematic 500 ms native-wakeup stall.

A later validation run caught a **693.96 ms renderer stall** in Kosmo `ps`:
that run's end-to-end p95 was 706.01 ms. Meanwhile, read/parse never exceeded
0.14 ms, grid synchronization 0.39 ms, or an application frame 14.01 ms. Output
continued to be read, synchronized, and submitted while the renderer stalled.
Option 1 therefore does not eliminate every visible pause. This outlier points
to the renderer/presentation path, rather than terminal parsing or UI wakeup.
The trace now also separates resource preparation, backend frame setup,
scene rendering, and the final backend presentation hook. FigDraw's Metal
scene-rendering path includes GPU completion waits and drawable acquisition;
those are follow-up investigation targets, not established causes of the stall.

Two further paired Kosmo `ps` runs measured p95 22.40 → 11.78 ms and
24.65 → 11.98 ms. The long renderer stall did not recur in those runs. With the
finer instrumentation, resource preparation stayed below 0.40 ms and scene
rendering below 4.57 ms. The intermittent presentation issue remains open.

The updated idle traces contain zero PTY polls and no terminal grid updates.
Kosmo still wakes for its other work (23 application frames in the measured
idle second, both before and after). Short process-CPU samples varied with
native window activity, so they do not establish an absolute idle-CPU saving.
The scheduling guarantee is that terminal output adds no periodic fast timer.

If continuous animation still feels chunky, the next measured target is frame
construction and renderer work. Moving parsing to a worker is more relevant to
large output floods than to the ordinary `cmatrix` batches measured here.

## Scheduling

PTY readiness queues one cooperative read job. Each application-frame drain
gives it a 2 ms parsing budget, checked between Terminex read chunks. A chunk
can exceed that budget; it is a cooperative bound, not a hard deadline.
Continuations yield to native input, animations and window rendering.

Reading and presentation are independent. The first grid update is scheduled
2 ms after output arrives, with at least 8 ms between grid updates during a
burst. Output within 50 ms of the previous grid update skips the initial
batching delay, so ongoing animation is paced without a delay on every read.
Further output keeps the same pending deadline instead of postponing
it. Final output is synchronized before publishing process exit. Closing,
detaching or replacing a session invalidates pending work and cancels its frame.

A healthy idle terminal does not poll its PTY or run a fast frame timer. The
500 ms heartbeat handles blinking and retries pending input or process exit
after a hangup. Systems without a working readiness watch retain the existing
animation-driven polling fallback, with the same bounded read work.

## Dependency change

This work also prepares Terminex 0.3.3 in the Atlas-managed `deps/terminex`
checkout: `poll` accepts
`timeBudget` and returns `readPaused` and `outputClosed`. Its exit check now waits
until output is drained, and queued input cannot prevent exit collection after
the PTY closes. Merenda pins the Terminex implementation commit while its
0.3.3 change is under review, so clean Atlas installations can use this branch.
After Terminex 0.3.3 is released, the pin can become a version requirement.
An unmodified Terminex 0.3.2 does not provide the new API.

## Validation

- Merenda's full `atlas-run tests` suite: 4/4 runners passed.
- Terminex's full suite: 5/5 runners passed.
- Final integration/session regression run: 2/2 runners passed.
- `atlas-run tests --compile-only examples/all_compile.nim`: compiled.

Coverage includes yielding before parsing, fixed presentation deadlines, no
idle read scheduling, draining final output across multiple budgets, pending
input at exit, and cancellation when closing, detaching, or replacing sessions.
An initial full run failed the existing Bash Ctrl-C interaction check; subsequent
focused and full runs passed. The new scheduling regressions passed throughout.
