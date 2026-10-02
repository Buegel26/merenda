## Synchronized terminal sessions for UI access and readiness-driven parsing.
## No borrowed screen storage crosses the lock. Rendering uses an owned viewport
## snapshot; input and resize remain synchronous and serialize with parser work.

import std/[atomics, locks, math, monotimes, times]
import threading/smartptrs
import terminex/[compactscrollback, termscreen, termsessions]

export compactscrollback, termscreen, termsessions

type
  TerminalSessionStorage = object
    lock: Lock
    lockReady: bool
    uiWaiters: Atomic[int]
    session: CompactTerminalSession[TerminexCell]
    workerAllowed: bool
    workerToken, readSerial: uint64
    notificationPending: bool
    outputClosed: bool
    pending: TerminexPollResult

  TerminalSessionHandle* = SharedPtr[TerminalSessionStorage]
    ## Internal worker handle. Access its session only through this module.

  TerminalViewSession* = ref object
    storage: TerminalSessionHandle
    identity: pointer

  TerminalViewportSnapshot* = object
    info*: TerminexScreenInfo
    start*: int
    scrollPosition*: float32
    lines*: seq[TerminexLine]
    workerToken*, readSerial*: uint64

proc `=destroy`(storage: TerminalSessionStorage) =
  let owned = addr storage
  if owned.lockReady:
    deinitLock(owned.lock)
  {.cast(raises: []).}:
    `=destroy`(owned.session)

proc `=copy`(
  target: var TerminalSessionStorage, source: TerminalSessionStorage
) {.error.}

proc `=dup`(source: TerminalSessionStorage): TerminalSessionStorage {.error.}

proc wrapSession(
    session: CompactTerminalSession[TerminexCell], workerAllowed: bool
): TerminalViewSession =
  if session.isNil:
    return
  result = TerminalViewSession(identity: cast[pointer](session))
  result.storage = newSharedPtr(TerminalSessionStorage)
  initLock(result.storage[].lock)
  result.storage[].lockReady = true
  result.storage[].session = session
  result.storage[].workerAllowed = workerAllowed

converter toTerminalViewSession*(
    session: CompactTerminalSession[TerminexCell]
): TerminalViewSession =
  ## Borrow an externally owned Terminex session on the UI thread. Its aliases
  ## cannot be synchronized here, so these sessions retain cooperative polling.
  wrapSession(session, workerAllowed = false)

proc newTerminalViewSession*(
    columns = 80, rows = 24, maxScrollback = 10_000
): TerminalViewSession =
  ## Own a session whose parsing may run on the terminal worker.
  wrapSession(
    newCompactTerminalSession(columns, rows, maxScrollback), workerAllowed = true
  )

func `==`*(left, right: TerminalViewSession): bool =
  if left.isNil or right.isNil:
    left.isNil and right.isNil
  else:
    left.identity == right.identity

template withSessionLock(handle: TerminalSessionHandle, body: untyped): untyped =
  # pthread mutexes do not promise fair reacquisition. Announce UI access before
  # waiting so a continuously readable PTY cannot starve a viewport snapshot.
  discard handle[].uiWaiters.fetchAdd(1, moAcquireRelease)
  try:
    withLock handle[].lock:
      body
  finally:
    discard handle[].uiWaiters.fetchSub(1, moAcquireRelease)

template locked(session: TerminalViewSession, body: untyped): untyped =
  withSessionLock(session.storage):
    body

func screenInfo*(session: TerminalViewSession): TerminexScreenInfo =
  {.cast(noSideEffect).}:
    locked(session):
      result = session.storage[].session.screenInfo()

func screen*(session: TerminalViewSession): CompactTerminalScreen[TerminexCell] =
  ## Return an owned copy. Prefer screenInfo/lineAtAbsolute for small queries.
  {.cast(noSideEffect).}:
    locked(session):
      result = session.storage[].session.screen()

func lineAtAbsolute*(session: TerminalViewSession, row: int): TerminexLine =
  {.cast(noSideEffect).}:
    locked(session):
      result = session.storage[].session.lineAtAbsolute(row)

func state*(session: TerminalViewSession): TerminexSessionState =
  {.cast(noSideEffect).}:
    locked(session):
      result = session.storage[].session.state()

func running*(session: TerminalViewSession): bool =
  session.state() == tssRunning

func exitCode*(session: TerminalViewSession): int =
  {.cast(noSideEffect).}:
    locked(session):
      result = session.storage[].session.exitCode()

func lastError*(session: TerminalViewSession): string =
  {.cast(noSideEffect).}:
    locked(session):
      result = session.storage[].session.lastError()

func pendingWriteBytes*(session: TerminalViewSession): int =
  {.cast(noSideEffect).}:
    locked(session):
      result = session.storage[].session.pendingWriteBytes()

func readLimit*(session: TerminalViewSession): int =
  {.cast(noSideEffect).}:
    locked(session):
      result = session.storage[].session.readLimit()

proc `readLimit=`*(session: TerminalViewSession, value: int) =
  locked(session):
    session.storage[].session.readLimit = value

func writeLimit*(session: TerminalViewSession): int =
  {.cast(noSideEffect).}:
    locked(session):
      result = session.storage[].session.writeLimit()

proc `writeLimit=`*(session: TerminalViewSession, value: int) =
  locked(session):
    session.storage[].session.writeLimit = value

proc processOutput*(session: TerminalViewSession, data: string) =
  locked(session):
    session.storage[].session.processOutput(data)

proc write*(session: TerminalViewSession, data: string) =
  locked(session):
    session.storage[].session.write(data)

proc resize*(session: TerminalViewSession, columns, rows: int) =
  locked(session):
    session.storage[].session.resize(columns, rows)

proc clearScrollback*(session: TerminalViewSession) =
  locked(session):
    session.storage[].session.clearScrollback()

proc takeClipboardRequest*(session: TerminalViewSession): string =
  locked(session):
    result = session.storage[].session.takeClipboardRequest()

proc sendSignal*(session: TerminalViewSession, signal: cint): bool =
  locked(session):
    result = session.storage[].session.sendSignal(signal)

proc interrupt*(session: TerminalViewSession): bool =
  locked(session):
    result = session.storage[].session.interrupt()

proc terminate*(session: TerminalViewSession): bool =
  locked(session):
    result = session.storage[].session.terminate()

proc close*(session: TerminalViewSession) =
  if not session.isNil:
    locked(session):
      session.storage[].workerToken = 0
      session.storage[].pending = default(TerminexPollResult)
      session.storage[].notificationPending = false
      session.storage[].session.close()

proc start*(session: TerminalViewSession, options = initTerminalSpawnOptions()) =
  locked(session):
    session.storage[].workerToken = 0
    session.storage[].pending = default(TerminexPollResult)
    session.storage[].notificationPending = false
    session.storage[].outputClosed = false
    session.storage[].session.start(options)

proc viewportSnapshot*(
    session: TerminalViewSession,
    scrollPosition: float32,
    previousLinesAdded, previousResetCount: uint64,
): TerminalViewportSnapshot =
  locked(session):
    result.info = session.storage[].session.screenInfo()
    result.workerToken = session.storage[].workerToken
    result.readSerial = session.storage[].readSerial
    let info = result.info
    if info.scrollbackResetCount == previousResetCount:
      result.scrollPosition = scrollPosition
      if scrollPosition > 0:
        result.scrollPosition += (info.scrollbackLinesAdded - previousLinesAdded).float32
      result.scrollPosition =
        clamp(result.scrollPosition, 0.0'f32, info.scrollbackCount.float32)
    result.start =
      max(info.totalLineCount - info.rows - int(ceil(result.scrollPosition)), 0)
    result.lines = newSeqOfCap[TerminexLine](info.rows)
    for row in 0 ..< info.rows:
      result.lines.add session.storage[].session.lineAtAbsolute(result.start + row)

proc workerHandle*(session: TerminalViewSession): TerminalSessionHandle =
  if not session.isNil and session.storage[].workerAllowed:
    result = session.storage

proc prepareWorker*(handle: TerminalSessionHandle, token: uint64): bool =
  if not handle.isNil:
    withSessionLock(handle):
      if handle[].session.running() and handle[].workerToken == 0:
        handle[].workerToken = token
        handle[].notificationPending = false
        handle[].pending = default(TerminexPollResult)
        handle[].outputClosed = false
        result = true

proc beginWorker*(handle: TerminalSessionHandle, token: uint64): bool =
  if not handle.isNil:
    withSessionLock(handle):
      result = handle[].workerToken == token and handle[].session.running()

proc endWorker*(handle: TerminalSessionHandle, token: uint64) =
  if not handle.isNil:
    withSessionLock(handle):
      if handle[].workerToken == token:
        handle[].workerToken = 0
        handle[].notificationPending = false

proc pollWorker*(
    handle: TerminalSessionHandle, token: uint64
): tuple[
  polled: TerminexPollResult, notify, active, yieldToUi: bool, readSerial: uint64
] =
  if handle.isNil:
    return
  if handle[].uiWaiters.load(moAcquire) > 0 or not tryAcquire(handle[].lock):
    result.active = true
    result.yieldToUi = true
    return
  defer:
    release(handle[].lock)
  if handle[].workerToken == token and handle[].session.running():
    result.active = true
    result.polled = handle[].session.poll(timeBudget = initDuration(milliseconds = 2))
    if result.polled.bytesRead > 0:
      inc handle[].readSerial
    result.readSerial = handle[].readSerial
    handle[].outputClosed = result.polled.outputClosed
    handle[].pending.bytesRead += result.polled.bytesRead
    handle[].pending.screenChanged =
      handle[].pending.screenChanged or result.polled.screenChanged
    handle[].pending.processExited =
      handle[].pending.processExited or result.polled.processExited
    handle[].pending.outputClosed =
      handle[].pending.outputClosed or result.polled.outputClosed
    if not handle[].notificationPending and (
      result.polled.bytesRead > 0 or result.polled.screenChanged or
      result.polled.outputClosed or result.polled.processExited
    ):
      handle[].notificationPending = true
      result.notify = true

proc poll*(
    session: TerminalViewSession, timeBudget = initDuration()
): TerminexPollResult =
  locked(session):
    if session.storage[].workerToken == 0:
      result = session.storage[].session.poll(timeBudget)
    else:
      result = session.storage[].pending
      session.storage[].pending = default(TerminexPollResult)
      session.storage[].notificationPending = false
      if session.storage[].session.pendingWriteBytes() > 0:
        discard session.storage[].session.flushInput()
      # After hangup the watcher is disarmed. Maintenance may collect a child
      # which closed its output before it exited, and retry backpressured input.
      if session.storage[].outputClosed and not result.processExited:
        let finalPoll = session.storage[].session.poll(timeBudget)
        result.processExited = finalPoll.processExited
        result.outputClosed = true

when defined(posix):
  proc masterDescriptor*(session: TerminalViewSession): cint =
    result = -1
    locked(session):
      if session.storage[].session.running():
        for name, value in fieldPairs(session.storage[].session[]):
          when name == "xMasterFd":
            result = value
