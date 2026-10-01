## Readiness delivery, backpressure, and PTY descriptor ownership.
when defined(posix):
  import std/[monotimes, options, os, strutils, times, unittest]
  import sigils/[core, threads]
  import terminex
  import merenda/nimkit/app/[animations, diagnostics, windows]
  import merenda/nimkit/foundation/[backgroundworkers, mainthreadwork, types]
  import merenda/nimkit/terminal/[terminalviews, terminalwatch]
  import merenda/nimkit/text/monotextviews

  type WatchSpy = ref object of Agent
    started, ready, failed, stopped: int
    token: uint64

  type RestartSpy = ref object of Agent
    view: TerminalView
    replacement: CompactTerminalSession[TerminexCell]
    exits: int

  proc replaceOnExit(spy: RestartSpy, code: int) {.slot.} =
    discard code
    inc spy.exits
    spy.view.session = spy.replacement

  proc didStart(spy: WatchSpy, token: uint64) {.slot.} =
    inc spy.started
    spy.token = token

  proc didRead(spy: WatchSpy, token: uint64) {.slot.} =
    inc spy.ready
    spy.token = token

  proc didFail(spy: WatchSpy, token: uint64) {.slot.} =
    inc spy.failed
    spy.token = token

  proc didStop(spy: WatchSpy, token: uint64) {.slot.} =
    inc spy.stopped
    spy.token = token

  proc observe(watch: TerminalOutputWatch, spy: WatchSpy) =
    watch.connect(terminalOutputWatchStarted, spy, didStart)
    watch.connect(terminalOutputReady, spy, didRead)
    watch.connect(terminalOutputWatchFailed, spy, didFail)
    watch.connect(terminalOutputWatchStopped, spy, didStop)

  template waitFor(condition: untyped, owner: Window = nil) =
    block:
      let deadline = getMonoTime() + initDuration(seconds = 5)
      while not (condition) and getMonoTime() < deadline:
        discard getCurrentSigilThread().pollAll(NonBlocking)
        if not owner.isNil:
          discard drainMainThreadWork()
          discard owner.drainAnimations()
        sleep(1)
      require condition

  proc waitForText(session: CompactTerminalSession[TerminexCell], text: string): bool =
    let deadline = getMonoTime() + initDuration(seconds = 5)
    while getMonoTime() < deadline:
      discard getCurrentSigilThread().pollAll(NonBlocking)
      discard session.poll()
      if text in session.screen().plainText():
        return true
      sleep(1)

  proc spawnEchoSession(): CompactTerminalSession[TerminexCell] =
    spawnCompactTerminalSession(
      initTerminalSpawnOptions(
        command =
          "stty -echo; printf 'watch-ready\\n'; while IFS= read -r line; do printf 'received:%s\\n' \"$line\"; done"
      ),
      columns = 60,
      rows = 8,
    )

  suite "Terminal output watches":
    test "readability is one-shot and parsing stays on the caller thread":
      discard nimkitTimerThread()
      let session = spawnEchoSession()
      defer:
        session.close()
      require session.waitForText("watch-ready")
      let watch = newTerminalOutputWatch(session)
      require not watch.isNil
      defer:
        watch.stop()
      let spy = WatchSpy()
      watch.observe(spy)
      watch.start()
      watch.start()
      waitFor(spy.started == 1)
      check spy.failed == 0
      session.write("first\n")
      waitFor(spy.ready == 1)
      check "received:first" notin session.screen().plainText()
      require session.waitForText("received:first")
      session.write("second\n")
      require session.waitForText("received:second")
      check spy.ready == 1
      watch.rearm()
      session.write("third\n")
      waitFor(spy.ready == 2)
      require session.waitForText("received:third")
      watch.stop()
      watch.stop()
      watch.rearm()
      waitFor(spy.stopped == 1)
      check spy.token == watch.token
      check spy.failed == 0
      check session.running()
      session.write("after-stop\n")
      require session.waitForText("received:after-stop")
      check spy.ready == 2

    when defined(macosx) or defined(linux):
      test "stop and abandoned watches release their duplicated descriptors":
        discard nimkitTimerThread()
        let session = spawnEchoSession()
        defer:
          session.close()
        require session.waitForText("watch-ready")
        let baseline = processResourceUsage().fileDescriptors
        require baseline >= 0
        for index in 0 ..< 12:
          var watch = newTerminalOutputWatch(session)
          require not watch.isNil
          let spy = WatchSpy()
          watch.observe(spy)
          if index mod 3 != 0:
            watch.start()
            waitFor(spy.started == 1)
          if index mod 3 == 1:
            # Drop a registered watch without an explicit stop.
            watch = nil
          else:
            watch.stop()
            waitFor(spy.stopped == 1)
            watch = nil
          waitFor(processResourceUsage().fileDescriptors <= baseline)
        check session.running()

    test "views receive scheduled output and replace old watches":
      let
        first = spawnEchoSession()
        second = spawnEchoSession()
        view = newTerminalView(first, frame = rect(0, 0, 640, 180))
        window = newWindow("Terminal readiness", frame = rect(0, 0, 640, 180))
        other = newWindow("Terminal moved", frame = rect(0, 0, 640, 180))
      defer:
        view.close()
        first.close()
        second.close()
      require first.waitForText("watch-ready")
      require second.waitForText("watch-ready")
      first.readLimit = 8
      second.readLimit = 8
      window.setContentView(view)
      let heartbeat = window.animationScheduler().scheduledAnimations()[0]
      waitFor(heartbeat.cadence.kind == ackInterval)
      check heartbeat.cadence.interval == initDuration(milliseconds = 500)
      first.write("first-view\n")
      waitFor("received:first-view" in view.stringValue(), window)
      # Queue output for the old session before replacing it.
      first.write("stale-view\n")
      waitFor(hasPendingMainThreadWork())
      view.session = second
      second.write("second-view\n")
      waitFor("received:second-view" in view.stringValue(), window)
      check "first-view" notin view.stringValue()
      check "stale-view" notin view.stringValue()
      window.setContentView(nil)
      check window.animationScheduler().animationCount() == 0
      other.setContentView(view)
      second.write("moved-view\n")
      waitFor("received:moved-view" in view.stringValue(), other)
      view.close()
      check other.animationScheduler().animationCount() == 0
      check not second.running()

    test "an exit callback can start output for a replacement session":
      let
        first = spawnEchoSession()
        second = spawnEchoSession()
        view = newTerminalView(first, frame = rect(0, 0, 640, 180))
        window = newWindow("Terminal restart", frame = rect(0, 0, 640, 180))
        spy = RestartSpy(view: view, replacement: second)
      defer:
        view.close()
        first.close()
        second.close()
      require first.waitForText("watch-ready")
      require second.waitForText("watch-ready")
      view.connect(terminalProcessDidExit, spy, replaceOnExit)
      window.setContentView(view)
      require first.terminate()
      waitFor(spy.exits == 1, window)
      require view.session == second
      second.write("restarted\n")
      waitFor("received:restarted" in view.stringValue(), window)
      check spy.exits == 1

    test "readiness yields before parsing and closing cancels the pending frame":
      let session = spawnEchoSession()
      defer:
        session.close()
      require session.waitForText("watch-ready")
      let
        view = newTerminalView(session, frame = rect(0, 0, 640, 180))
        window = newWindow("Terminal batching", frame = rect(0, 0, 640, 180))
      defer:
        view.close()
      window.setContentView(view)
      let heartbeat = window.animationScheduler().scheduledAnimations()[0]
      waitFor(heartbeat.cadence.kind == ackInterval)
      session.write("batched\n")
      waitFor(hasPendingMainThreadWork())
      check "received:batched" notin session.screen().plainText()
      waitFor("received:batched" in view.stringValue(), window)
      check window.animationScheduler().animationCount() == 1
      check heartbeat.cadence.interval == initDuration(milliseconds = 500)
      discard window.animationScheduler().tick(initDuration(milliseconds = 500))
      check not hasPendingMainThreadWork()
      check window.animationScheduler().animationCount() == 1

      session.write("cancelled\n")
      waitFor(hasPendingMainThreadWork())
      view.close()
      check window.animationScheduler().animationCount() == 0
      discard window.drainAnimations()
      discard drainMainThreadWork()
      check "received:cancelled" notin view.stringValue()

    test "closing a session directly stops its attached readiness work":
      let session = spawnEchoSession()
      defer:
        session.close()
      require session.waitForText("watch-ready")
      let
        view = newTerminalView(session, frame = rect(0, 0, 640, 180))
        window = newWindow("Terminal closed session", frame = rect(0, 0, 640, 180))
      defer:
        view.close()
      window.setContentView(view)
      let heartbeat = window.animationScheduler().scheduledAnimations()[0]
      waitFor(heartbeat.cadence.kind == ackInterval)
      session.write("closing\n")
      waitFor(hasPendingMainThreadWork())
      session.close()
      discard drainMainThreadWork()
      check not hasPendingMainThreadWork()
      check window.animationScheduler().animationCount() == 0

    test "more output keeps the pending presentation deadline":
      let session = spawnEchoSession()
      defer:
        session.close()
      require session.waitForText("watch-ready")
      let
        view = newTerminalView(session, frame = rect(0, 0, 640, 180))
        window = newWindow("Terminal deadline", frame = rect(0, 0, 640, 180))
      defer:
        view.close()
      window.setContentView(view)
      let scheduler = window.animationScheduler()
      let heartbeat = scheduler.scheduledAnimations()[0]
      waitFor(heartbeat.cadence.kind == ackInterval)
      session.write("first\n")
      waitFor(hasPendingMainThreadWork())
      discard drainMainThreadWork()
      require scheduler.animationCount() == 2
      let firstDeadline = scheduler.nextDeadline()
      require firstDeadline.isSome
      check "received:first" notin view.stringValue()

      session.write("second\n")
      let deadline = getMonoTime() + initDuration(seconds = 5)
      while "received:second" notin session.screen().plainText() and
          getMonoTime() < deadline:
        discard getCurrentSigilThread().pollAll(NonBlocking)
        discard drainMainThreadWork()
        sleep(1)
      require "received:second" in session.screen().plainText()
      check scheduler.nextDeadline() == firstDeadline
      check "received:second" notin view.stringValue()
      waitFor("received:second" in view.stringValue(), window)
      check "received:first" in view.stringValue()

    test "a busy terminal yields between batches and retains its final output":
      const LineCount = 10_000
      let session = spawnCompactTerminalSession(
        initTerminalSpawnOptions(
          shell = "/bin/sh",
          command =
            "stty -echo; printf 'watch-ready\\n'; IFS= read -r start; " &
            "i=0; while [ $i -lt " & $LineCount & " ]; do " &
            "printf 'payload-line\\n'; i=$((i+1)); done; printf 'final-output\\n'; exit 7",
        ),
        columns = 60,
        rows = 8,
      )
      defer:
        session.close()
      require session.waitForText("watch-ready")
      session.readLimit = 16 * 1024
      let
        view = newTerminalView(session, frame = rect(0, 0, 640, 180))
        window = newWindow("Terminal flood", frame = rect(0, 0, 640, 180))
      defer:
        view.close()
      window.setContentView(view)
      let heartbeat = window.animationScheduler().scheduledAnimations()[0]
      waitFor(heartbeat.cadence.kind == ackInterval)
      session.write("start\n")
      var progressFrames = 0
      let deadline = getMonoTime() + initDuration(seconds = 60)
      while session.running() and getMonoTime() < deadline:
        let before = session.screenInfo().generation
        discard getCurrentSigilThread().pollAll(NonBlocking)
        # Processing a readiness notification must not monopolize the UI queue.
        check session.screenInfo().generation == before
        discard drainMainThreadWork()
        discard window.drainAnimations()
        if session.screenInfo().generation != before:
          inc progressFrames
        sleep(1)
      require not session.running()
      check session.exitCode() == 7
      check progressFrames > 1
      check "final-output" in view.stringValue()
      check session.screenInfo().scrollbackLinesAdded ==
        uint64(LineCount + 3 - session.screenInfo().rows)
      check window.animationScheduler().animationCount() == 0
