# Terminal latency diagnostics

Build the optional timing probe from the repository root:

```sh
nim c -d:nimkitTerminalTrace tests/benchmark_terminal_native.nim
tests/benchmark_terminal_native cmatrix terminal /tmp/terminal-cmatrix.jsonl
tests/benchmark_terminal_native ps terminal /tmp/terminal-ps.jsonl
tests/benchmark_terminal_native cmatrix kosmo /tmp/kosmo-cmatrix.jsonl
tests/benchmark_terminal_native ps kosmo /tmp/kosmo-ps.jsonl
tests/benchmark_terminal_native burst kosmo /tmp/kosmo-burst.jsonl
python3 tests/benchmarks/terminal_trace_summary.py /tmp/kosmo-cmatrix.jsonl /tmp/kosmo-ps.jsonl
```

`cmatrix` must be installed. Run the probes sequentially, with no concurrent
builds or GUI tests, to avoid contention. Each probe opens a real window, waits
for a PTY handshake, measures one second of idle process CPU, then observes
three seconds of output through `Application.run()` and its blocking native
event loop. The terminal has no keyboard focus, excluding cursor blinking from
the idle sample. The `ps` workload runs twelve commands separated by 150 ms; those
intentional gaps must not be interpreted as presentation stalls. The `burst`
workload emits 10,000 lines and a final marker without intentional gaps. The
probe reports both idle and active process CPU as a percentage of one core.

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

## Row batching and worker measurements

The rendering/frame-pacing changes are isolated in `6b891cca`. On the same
machine and Kosmo `cmatrix` workload, row batching reduced p95 frame
construction/submission from 8.90 ms to about 2 ms. This is the main measured
improvement for continuous animation.

Comparing that commit with the separate PTY worker change:

- `cmatrix` readiness-to-presentation p95 was 5.92 ms in a successful committed
  baseline sample and 5.89 ms with the worker. The worker sample used 53.65% of
  one CPU core during animation; idle samples remained around 2%.
- A paired `ps` sample measured p95 11.51 ms versus 12.43 ms. Moving these small
  reads to a worker does not demonstrate a latency improvement.
- Draining a 10,000-line burst took 117.12 ms versus 120.02 ms. The worker's
  read-to-presentation maximum was 18.72 ms and its viewport-update maximum was
  2.19 ms. Worker parsing can continue without UI read jobs; this sample shows
  comparable throughput, not a throughput gain.

The first worker implementation exposed unfair lock reacquisition during floods,
delaying a viewport update by 78.31 ms. Giving waiting UI access priority reduced
that maximum to 2.19 ms in the final burst sample. Each contended continuation
waits 1 ms; idle samples contained no PTY reads, grid updates, or continuations.

These are short three-second observations. An additional committed-baseline
`cmatrix` run hit a 997.97 ms renderer stall, consistent with the intermittent
presentation issue described below. Its absence in the worker sample does not
establish that the worker fixes that issue. Presentation timings measure native
submission, not scanout; burst CPU averages include the quiet remainder of the
three-second observation.

## Earlier native measurements

Measured on an Apple M3 Pro, macOS 15.7.9, Nim 2.2.12, using the automatic Metal
renderer. The baseline is Merenda `2e3c2cb7` with tracing added and Terminex
`176ff0e`; the comparison used UI-thread read budgets and coalesced output frames. Both use the same
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

View-owned sessions read and parse output on a dedicated readiness dispatcher,
with a 2 ms budget between Terminex read chunks. A chunk can exceed that budget;
it is a cooperative bound, not a hard deadline. The worker rearms readiness
without waiting for the UI, and coalesces notifications until the UI consumes the
pending update. Timers use a separate dispatcher, so terminal floods do not
occupy the timer thread. Healthy idle sessions perform no reads.

Input, resize and lifecycle operations serialize with parsing through the
session lock. Pending UI access has priority over another worker read. If the
lock is occupied or a UI caller is waiting, the worker schedules a one-shot
1 ms continuation instead of repeatedly reacquiring the lock or spinning. This
continuation is used only during contention and is cancelled with the watch.
The UI copies a consistent viewport under that lock and releases it before
constructing a frame. It does not copy the scrollback on every frame.
`worker-poll-start` to `worker-poll-end` measures worker read/parse work;
`poll-start` to `poll-end` now measures consumption of the pending result for
these sessions. Cumulative worker read serials are recorded with each viewport
snapshot, so readiness-to-presentation latency includes reads incorporated into
a frame before their coalesced notification is consumed. The serials contain no
terminal text.

Passing an externally owned raw `CompactTerminalSession` to a view retains
cooperative UI reads, because external aliases cannot participate in the lock.
The existing 2 ms UI read budget still applies to that path.

Reading and presentation are independent. The first grid update after idle is
scheduled immediately, with at least 8 ms between grid updates during a burst
(or the window's configured animation interval if it is shorter).
Further output keeps the same pending deadline instead of postponing
it. Final output is synchronized before publishing process exit. Closing,
detaching or replacing a session invalidates pending work and cancels its frame.

A healthy idle terminal does not poll its PTY or run a fast frame timer. The
500 ms heartbeat handles blinking and retries pending input or process exit
after a hangup. Systems without a working readiness watch retain the existing
animation-driven polling fallback, with the same bounded read work.

## Frame construction and row drawing

A changed row groups nonadjacent glyphs with matching color, weight and italic
style into the same text operation, preserving each cell's horizontal position.
Blank and hidden cells still paint backgrounds and decorations but allocate no
glyph arrangement. Unchanged rows retain their existing render slots.

Native windows defer construction of another frame while a dedicated renderer
submission is outstanding. Dirty views and native damage remain pending;
renderer completion wakes the application to build the newest state. An older
completion cannot mark a newer submission complete. This gate avoids building
frames merely to replace them in the renderer's latest-frame queue, without a
new periodic idle timer.

## Session API and ownership

`TerminalViewSession` is now a synchronized handle, rather than a type alias for
Terminex's raw session. `newTerminalView()` and `newTerminalView(options)` create
worker-capable sessions. Use `newTerminalViewSession()` when constructing a
session separately; start it through `session.start(options)`. Existing raw
compact sessions convert to a view session and keep their UI-owned behavior.

Read-only `screenInfo()` and `lineAtAbsolute()` return owned values. `screen()`
returns an owned full-screen/history snapshot, so prefer the smaller queries for
frequent inspection. The view's internal viewport snapshot captures metadata and
visible rows together. Synchronous `write`, `resize`, `poll`, `close`, and signal
operations remain available through `view.session()`.

Detach, replacement and close invalidate the worker token before queued startup
or readiness callbacks can resume reads. Final output remains in the session
and is synchronized before process-exit notification. After hangup, the existing
maintenance heartbeat collects a child whose exit was not yet observable.

## Dependency change

This work also prepares Terminex 0.3.3 in the Atlas-managed `deps/terminex`
checkout: `poll` accepts
`timeBudget` and returns `readPaused` and `outputClosed`. Its exit check now waits
until output is drained, and queued input cannot prevent exit collection after
the PTY closes. Merenda pins the Terminex implementation commit while its
0.3.3 change is under review, so clean Atlas installations can use this branch.
After Terminex 0.3.3 is released, the pin can become a version requirement.
An unmodified Terminex 0.3.2 does not provide the new API.

## Worker validation

- The normal full suite passed all four shared runners; the example bundle
  compiled with `atlas-run tests --compile-only examples/all_compile.nim`.
- After adding lock fairness and cumulative trace correlation, the terminal
  output-watch, parser, session, view, and worker-shutdown suites passed all 76
  checks with ORC and AddressSanitizer/UBSan enabled.
- The final normal `atlas-run tests integrations` rerun also passed.
- The full ORC sanitizer integration run found a workspace-watcher timer
  use-after-free in Sigils reference collection during Kosmo teardown. The same
  allocation/free stacks reproduce on `6b891cca` without the PTY worker. This is
  an unresolved teardown defect; the full ORC sanitizer suite is not clean.

Worker coverage includes a 10,000-line flood parsed without UI read jobs,
coalesced notifications, immutable prior snapshots, cancellation before startup
acknowledgement, detach/reattach, direct session close, final output/exit status,
and shutdown of both readiness and timer dispatchers.

## Earlier validation

- Merenda's full `atlas-run tests` suite: 4/4 runners passed.
- Terminex's full suite: 5/5 runners passed.
- Final integration/session regression run: 2/2 runners passed.
- `atlas-run tests --compile-only examples/all_compile.nim`: compiled.

Coverage includes yielding before parsing, fixed presentation deadlines, no
idle read scheduling, draining final output across multiple budgets, pending
input at exit, and cancellation when closing, detaching, or replacing sessions.
An initial full run failed the existing Bash Ctrl-C interaction check; subsequent
focused and full runs passed. The new scheduling regressions passed throughout.
