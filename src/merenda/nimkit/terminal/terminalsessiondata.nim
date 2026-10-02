## Owned values crossing the terminal worker boundary; no live session aliases.

import std/strutils
import terminex/[compactscrollback, termscreen, termsessions]

export compactscrollback, termscreen, termsessions

type
  TerminalScreenSnapshot* = object
    ## UI-owned screen and compact history. It never runs a terminal parser.
    info*: TerminexScreenInfo
    maxScrollback*: int
    history: CompactScrollback[TerminexCell, TerminexLine]
    lines: seq[TerminexLine]

  TerminalSessionSnapshot* = object
    ## History is cumulative since the last acknowledged snapshot. Replacing an
    ## unread snapshot therefore cannot lose retained history or final output.
    epoch*, serial*, workerToken*, readSerial*, bytesRead*: uint64
    info*: TerminexScreenInfo
    maxScrollback*: int
    historyStart*: uint64
    history*, lines*: seq[TerminexLine]
    state*: TerminexSessionState
    exitCode*, pendingWriteBytes*, readLimit*, writeLimit*: int
    lastError*: string
    outputClosed*: bool
    clipboardSerial*: uint64
    clipboard*: string
    appliedCommand*, processedWriteBytes*: uint64

  TerminalCommandKind* = enum
    tcWrite
    tcResize
    tcClearScrollback
    tcProcessOutput
    tcSignal
    tcInterrupt
    tcTerminate
    tcStart
    tcClose
    tcReadLimit
    tcWriteLimit
    tcAcknowledge

  TerminalCommand* = object
    kind*: TerminalCommandKind
    epoch*, serial*: uint64
    text*: string
    columns*, rows*, value*: int
    options*: TerminexSpawnOptions
    snapshotSerial*, historyAdded*, historyReset*, clipboardSerial*: uint64

var nextIdentity {.threadvar.}: uint64

proc nextTerminalIdentity*(): uint64 =
  inc nextIdentity
  nextIdentity

func columns*(screen: TerminalScreenSnapshot): int =
  screen.info.columns
func rows*(screen: TerminalScreenSnapshot): int =
  screen.info.rows
func cursor*(screen: TerminalScreenSnapshot): TerminexCursor =
  screen.info.cursor
func modes*(screen: TerminalScreenSnapshot): TerminexModes =
  screen.info.modes
func alternateScreen*(screen: TerminalScreenSnapshot): bool =
  screen.info.alternateScreen
func generation*(screen: TerminalScreenSnapshot): uint64 =
  screen.info.generation
func title*(screen: TerminalScreenSnapshot): string =
  screen.info.title
func currentDirectory*(screen: TerminalScreenSnapshot): string =
  screen.info.currentDirectory
func scrollbackCount*(screen: TerminalScreenSnapshot): int =
  screen.history.len
func totalLineCount*(screen: TerminalScreenSnapshot): int =
  screen.history.len + screen.lines.len

func lineAt*(screen: TerminalScreenSnapshot, row: int): TerminexLine =
  if row in 0 ..< screen.lines.len:
    result = screen.lines[row]

func lineAtAbsolute*(screen: TerminalScreenSnapshot, row: int): TerminexLine =
  if row in 0 ..< screen.history.len:
    result = screen.history[row]
  elif row >= screen.history.len:
    result = screen.lineAt(row - screen.history.len)

func cellAt*(screen: TerminalScreenSnapshot, row, column: int): TerminexCell =
  if row in 0 ..< screen.lines.len and column in 0 ..< screen.lines[row].len:
    result = screen.lines[row][column]

func lineText(line: TerminexLine): string =
  for cell in line:
    if not cell.continuation:
      result.add(if cell.text.len == 0: " " else: cell.text)
  result = result.strip(leading = false, trailing = true, chars = {' '})

func plainText*(screen: TerminalScreenSnapshot, includeScrollback = true): string =
  var lines: seq[string]
  if includeScrollback and not screen.alternateScreen:
    for line in screen.history.items:
      lines.add line.lineText()
  var lastContent = -1
  for line in screen.lines:
    lines.add line.lineText()
    if lines[^1].len > 0:
      lastContent = lines.high
  if lastContent < 0:
    if screen.alternateScreen or not includeScrollback or screen.history.len == 0:
      return
    lastContent = min(screen.history.len - 1, lines.high)
  lines.setLen(lastContent + 1)
  lines.join("\n")

proc applySnapshot*(
    screen: var TerminalScreenSnapshot, update: sink TerminalSessionSnapshot
) =
  let info = update.info
  var added = screen.info.scrollbackLinesAdded
  if screen.maxScrollback != update.maxScrollback or
      screen.info.scrollbackResetCount != info.scrollbackResetCount or
      added < update.historyStart:
    screen.history =
      initCompactScrollback[TerminexCell, TerminexLine](update.maxScrollback)
    added = update.historyStart
  for index in int(added - update.historyStart) ..< update.history.len:
    screen.history.add(move(update.history[index]))
  screen.maxScrollback = update.maxScrollback
  screen.info = info
  screen.lines = ensureMove update.lines

proc copyScreen*(
    session: CompactTerminalSession[TerminexCell]
): TerminalScreenSnapshot =
  ## Copy before transferring exclusive ownership to the worker.
  result.info = session.screenInfo()
  result.maxScrollback = session.screen().maxScrollback
  result.history =
    initCompactScrollback[TerminexCell, TerminexLine](result.maxScrollback)
  for row in 0 ..< result.info.scrollbackCount:
    result.history.add session.lineAtAbsolute(row)
  for row in 0 ..< result.info.rows:
    result.lines.add session.lineAtAbsolute(result.info.scrollbackCount + row)
