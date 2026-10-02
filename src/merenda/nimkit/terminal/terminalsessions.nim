## UI-owned terminal facade. Managed sessions move once into their worker;
## subsequent access uses commands and owned snapshots, never a parser mutex.

import std/math
import sigils/[core, rchannels, threadProxies, threads]
import ./[terminalsessiondata, terminalsessionworker]

export terminalsessiondata

type
  TerminalViewSession* = ref object of Agent
    cache: TerminalScreenSnapshot
    snapshots: RChan[TerminalSessionSnapshot]
    token, epoch, receivedSerial, readSerial, bytesRead: uint64
    commandSerial, appliedCommand, clipboardSerial: uint64
    submittedWriteBytes, processedWriteBytes: uint64
    cachedState: TerminexSessionState
    cachedExitCode, cachedPendingWrite, xReadLimit, xWriteLimit: int
    cachedError, clipboard: string
    pending: TerminexPollResult
    notificationPending, outputClosed: bool
    desiredColumns, desiredRows: int
    worker: AgentProxy[TerminalSessionWorker]

  TerminalViewportSnapshot* = object
    info*: TerminexScreenInfo
    start*: int
    scrollPosition*: float32
    lines*: seq[TerminexLine]
    workerToken*, readSerial*: uint64

proc sessionOutputAvailable*(session: TerminalViewSession) {.signal.}
func workerIdentity*(session: TerminalViewSession): uint64 =
  session.token
func pendingCommands*(session: TerminalViewSession): uint64 =
  session.commandSerial - session.appliedCommand

proc submit(session: TerminalViewSession, command: sink TerminalCommand) =
  var command = ensureMove command
  inc session.commandSerial
  command.serial = session.commandSerial
  command.epoch = session.epoch
  emit session.worker.commandRequested(ensureMove command)

proc collectSnapshots(session: TerminalViewSession) =
  var update: TerminalSessionSnapshot
  while session.snapshots.tryRecv(update):
    let acknowledgement = TerminalCommand(
      kind: tcAcknowledge,
      epoch: update.epoch,
      snapshotSerial: update.serial,
      historyAdded: update.info.scrollbackLinesAdded,
      historyReset: update.info.scrollbackResetCount,
      clipboardSerial: update.clipboardSerial,
    )
    if update.epoch == session.epoch and update.serial > session.receivedSerial:
      session.pending.bytesRead += int(update.bytesRead - session.bytesRead)
      session.pending.screenChanged =
        session.pending.screenChanged or update.info != session.cache.info or
        update.state != session.cachedState or update.lastError != session.cachedError
      session.pending.processExited =
        session.pending.processExited or update.state == tssExited
      session.pending.outputClosed = update.outputClosed
      session.outputClosed = update.outputClosed
      session.receivedSerial = update.serial
      session.readSerial = update.readSerial
      session.bytesRead = update.bytesRead
      session.appliedCommand = update.appliedCommand
      session.cachedState = update.state
      session.cachedExitCode = update.exitCode
      session.cachedPendingWrite = update.pendingWriteBytes
      session.processedWriteBytes = update.processedWriteBytes
      session.cachedError = update.lastError
      var clipboardPending = session.cache.info.clipboardRequestPending
      if update.clipboardSerial > session.clipboardSerial:
        session.clipboardSerial = update.clipboardSerial
        session.clipboard = move(update.clipboard)
        clipboardPending = true
      update.info.clipboardRequestPending = clipboardPending
      session.cache.applySnapshot(move(update))
    # ACK releases publication credit, never PTY read/parse progress.
    emit session.worker.commandRequested(acknowledgement)
  if not session.notificationPending and (
    session.pending.bytesRead > 0 or session.pending.screenChanged or
    session.pending.processExited or session.pending.outputClosed
  ):
    session.notificationPending = true
    emit session.sessionOutputAvailable()

proc snapshotArrived(session: TerminalViewSession, token: uint64) {.slot.} =
  if token == session.token:
    session.collectSnapshots()

proc newTerminalViewSession*(
    columns = 80, rows = 24, maxScrollback = 10_000
): TerminalViewSession =
  ## All mutations run on the terminal dispatcher, including offline parsing.
  ## Queries return the latest received snapshot. Pump the owning event loop
  ## or call poll() to receive updates; pendingCommands() tracks completion.
  var initial = newCompactTerminalSession(columns, rows, maxScrollback)
  result = TerminalViewSession(
    cache: initial.copyScreen(),
    snapshots: newRChan[TerminalSessionSnapshot](1),
    token: nextTerminalIdentity(),
    epoch: 1,
    cachedState: tssIdle,
    cachedExitCode: -1,
    xReadLimit: initial.readLimit(),
    xWriteLimit: initial.writeLimit(),
    desiredColumns: max(columns, 1),
    desiredRows: max(rows, 1),
  )
  result.worker = newTerminalSessionWorker(
    ensureMove initial, result.snapshots, result.token, result.epoch
  )
  connectThreaded(
    result.worker, snapshotAvailable, result, TerminalViewSession.snapshotArrived()
  )
  emit result.worker.beginRequested()

func screenInfo*(session: TerminalViewSession): TerminexScreenInfo =
  session.cache.info
func screen*(session: TerminalViewSession): TerminalScreenSnapshot =
  ## An owned copy of the last received screen/history, without a worker wait.
  session.cache
func lineAtAbsolute*(session: TerminalViewSession, row: int): TerminexLine =
  session.cache.lineAtAbsolute(row)
func state*(session: TerminalViewSession): TerminexSessionState =
  session.cachedState
func running*(session: TerminalViewSession): bool =
  session.state() == tssRunning
func exitCode*(session: TerminalViewSession): int =
  session.cachedExitCode
func lastError*(session: TerminalViewSession): string =
  session.cachedError
func pendingWriteBytes*(session: TerminalViewSession): int =
  session.cachedPendingWrite +
    int(session.submittedWriteBytes - session.processedWriteBytes)
func readLimit*(session: TerminalViewSession): int =
  session.xReadLimit
func writeLimit*(session: TerminalViewSession): int =
  session.xWriteLimit

proc `readLimit=`*(session: TerminalViewSession, value: int) =
  session.xReadLimit = max(value, 1)
  session.submit(TerminalCommand(kind: tcReadLimit, value: value))

proc `writeLimit=`*(session: TerminalViewSession, value: int) =
  session.xWriteLimit = max(value, 1)
  session.submit(TerminalCommand(kind: tcWriteLimit, value: value))

proc processOutput*(session: TerminalViewSession, data: string) =
  session.submit(TerminalCommand(kind: tcProcessOutput, text: data))

proc write*(session: TerminalViewSession, data: string) =
  if not session.running():
    raise newException(TerminexSessionError, "terminal session is not running")
  if data.len == 0:
    return
  if session.pendingWriteBytes() + data.len > session.xWriteLimit:
    raise newException(TerminexSessionError, "terminal input buffer is full")
  session.submittedWriteBytes += uint64(data.len)
  session.submit(TerminalCommand(kind: tcWrite, text: data))

proc resize*(session: TerminalViewSession, columns, rows: int) =
  if session.desiredColumns != max(columns, 1) or session.desiredRows != max(rows, 1):
    session.desiredColumns = max(columns, 1)
    session.desiredRows = max(rows, 1)
    session.submit(TerminalCommand(kind: tcResize, columns: columns, rows: rows))

proc clearScrollback*(session: TerminalViewSession) =
  session.submit(TerminalCommand(kind: tcClearScrollback))

proc takeClipboardRequest*(session: TerminalViewSession): string =
  result = move(session.clipboard)
  session.cache.info.clipboardRequestPending = false

proc sendSignal*(session: TerminalViewSession, signal: int): bool =
  ## True means queued for delivery, not OS success.
  if session.running():
    session.submit(TerminalCommand(kind: tcSignal, value: signal))
    result = true

proc interrupt*(session: TerminalViewSession): bool =
  if session.running():
    session.submit(TerminalCommand(kind: tcInterrupt))
    result = true

proc terminate*(session: TerminalViewSession): bool =
  if session.running():
    session.submit(TerminalCommand(kind: tcTerminate))
    result = true

proc close*(session: TerminalViewSession) =
  ## Immediately marks the facade closed; the worker then terminates and reaps
  ## the process. pendingCommands() reaches zero after that work is acknowledged.
  if not session.isNil and session.cachedState != tssClosed:
    inc session.epoch
    session.pending = default(TerminexPollResult)
    session.notificationPending = false
    session.outputClosed = false
    session.cachedState = tssClosed
    session.submit(TerminalCommand(kind: tcClose))

proc start*(session: TerminalViewSession, options = initTerminalSpawnOptions()) =
  ## Queue process startup. Failures arrive through state() and lastError().
  session.collectSnapshots()
  if session.running():
    raise newException(TerminexSessionError, "terminal session is already running")
  inc session.epoch
  session.pending = default(TerminexPollResult)
  session.notificationPending = false
  session.outputClosed = false
  session.cachedState = tssRunning
  session.cachedError.setLen(0)
  session.submit(TerminalCommand(kind: tcStart, options: options))

proc spawnTerminalViewSession*(
    options = initTerminalSpawnOptions(),
    columns = 80,
    rows = 24,
    maxScrollback = 10_000,
): TerminalViewSession =
  result = newTerminalViewSession(columns, rows, maxScrollback)
  result.start(options)

proc viewportSnapshot*(
    session: TerminalViewSession,
    scrollPosition: float32,
    previousLinesAdded, previousResetCount: uint64,
): TerminalViewportSnapshot =
  result.info = session.screenInfo()
  result.workerToken = session.token
  result.readSerial = session.readSerial
  let info = result.info
  if info.scrollbackResetCount == previousResetCount:
    result.scrollPosition = scrollPosition
    if scrollPosition > 0:
      result.scrollPosition += (info.scrollbackLinesAdded - previousLinesAdded).float32
    result.scrollPosition =
      clamp(result.scrollPosition, 0.0'f32, info.scrollbackCount.float32)
  result.start =
    max(info.totalLineCount - info.rows - int(ceil(result.scrollPosition)), 0)
  for row in 0 ..< info.rows:
    result.lines.add session.lineAtAbsolute(result.start + row)

proc poll*(session: TerminalViewSession): TerminexPollResult =
  ## Consume available snapshots without waiting for commands or PTY reads.
  session.collectSnapshots()
  result = session.pending
  # Lifecycle state remains observable after another view/caller consumed the
  # one-shot byte count, matching Terminex's exited-session polling contract.
  result.processExited = session.cachedState == tssExited
  result.outputClosed = session.outputClosed
  session.pending = default(TerminexPollResult)
  session.notificationPending = false
