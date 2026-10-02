import std/unittest
import merenda/nimkit/terminal/terminalsessiondata

proc snapshot(
    session: CompactTerminalSession[TerminexCell], acknowledged: TerminexScreenInfo
): TerminalSessionSnapshot =
  result.info = session.screenInfo()
  result.maxScrollback = session.screen().maxScrollback
  let oldest = result.info.scrollbackLinesAdded - uint64(result.info.scrollbackCount)
  result.historyStart =
    if acknowledged.scrollbackResetCount == result.info.scrollbackResetCount:
      max(oldest, acknowledged.scrollbackLinesAdded)
    else:
      oldest
  for row in int(result.historyStart - oldest) ..< result.info.scrollbackCount:
    result.history.add session.lineAtAbsolute(row)
  for row in 0 ..< result.info.rows:
    result.lines.add session.lineAtAbsolute(result.info.scrollbackCount + row)

suite "Owned terminal snapshots":
  test "skipped snapshots retain all history that fits the terminal capacity":
    let session = newCompactTerminalSession(columns = 12, rows = 2, maxScrollback = 3)
    var screen = session.copyScreen()
    let acknowledged = screen.info
    session.processOutput("one\r\ntwo\r\nthree\r\n")
    let skipped = session.snapshot(acknowledged)
    session.processOutput("four\r\nfive\r\nsix\r\nseven")
    screen.applySnapshot(session.snapshot(acknowledged))
    check skipped.info.scrollbackLinesAdded < screen.info.scrollbackLinesAdded
    check screen.plainText() == session.screen().plainText()
    check screen.scrollbackCount() == 3
    check screen.info == session.screenInfo()

  test "overlapping cumulative updates neither duplicate nor lose history":
    let session = newCompactTerminalSession(columns = 12, rows = 2, maxScrollback = 10)
    var screen = session.copyScreen()
    let acknowledged = screen.info
    session.processOutput("one\r\ntwo\r\nthree")
    screen.applySnapshot(session.snapshot(acknowledged))
    let original = screen
    session.processOutput("\r\nfour\r\nfive")
    screen.applySnapshot(session.snapshot(acknowledged))
    check screen.plainText() == session.screen().plainText()
    check original.plainText() == "one\ntwo\nthree"
    check screen.scrollbackCount() == session.screenInfo().scrollbackCount

  test "history reset and resize preserve coherent owned screen data":
    let session = newCompactTerminalSession(columns = 12, rows = 2, maxScrollback = 10)
    session.processOutput("old\r\none\r\ntwo")
    var screen = session.copyScreen()
    let acknowledged = screen.info
    session.clearScrollback()
    session.resize(15, 3)
    session.processOutput("\r\nwide: 界e\u0301")
    screen.applySnapshot(session.snapshot(acknowledged))
    check screen.info == session.screenInfo()
    check screen.plainText() == session.screen().plainText()
    for row in 0 ..< screen.totalLineCount():
      check screen.lineAtAbsolute(row) == session.lineAtAbsolute(row)

  test "unchanged history is excluded after acknowledgement":
    let session = newCompactTerminalSession(columns = 12, rows = 2, maxScrollback = 10)
    session.processOutput("one\r\ntwo\r\nthree")
    var screen = session.copyScreen()
    session.processOutput("\rupdated")
    let update = session.snapshot(screen.info)
    check update.history.len == 0
    screen.applySnapshot(update)
    check screen.plainText() == session.screen().plainText()

  test "alternate screen output keeps primary history without displaying it":
    let session = newCompactTerminalSession(columns = 12, rows = 2, maxScrollback = 10)
    session.processOutput("one\r\ntwo\r\nthree")
    var screen = session.copyScreen()
    let primary = screen.plainText()
    session.processOutput("\x1b[?1049h")
    screen.applySnapshot(session.snapshot(screen.info))
    check screen.alternateScreen
    check screen.plainText() == ""
    session.processOutput("alternate")
    screen.applySnapshot(session.snapshot(screen.info))
    check screen.plainText() == "alternate"
    session.processOutput("\x1b[?1049l")
    screen.applySnapshot(session.snapshot(screen.info))
    check screen.plainText() == primary
