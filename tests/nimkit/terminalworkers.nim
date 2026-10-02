## The command/snapshot path must also work without a native PTY backend.
import std/[strutils, unittest]
import merenda/nimkit/terminal/terminalsessions
import ../support/terminalhelpers

suite "Terminal worker ownership":
  test "offline parsing and resizing use queued commands on every platform":
    let session = newTerminalViewSession(columns = 12, rows = 2)
    defer:
      session.closeAndWait()
    let original = session.screen()
    session.processOutput("one\r\ntwo\r\nthree")
    session.resize(16, 3)
    check session.pendingCommands() == 2
    check session.screenInfo().columns == 12
    check session.screen().plainText() == ""
    session.waitForCommands()
    check session.screenInfo().columns == 16
    check session.screenInfo().rows == 3
    check "three" in session.screen().plainText()
    check original.plainText() == ""
    check original.columns == 12

  test "independent sessions keep their own history and clipboard requests":
    let first = newTerminalViewSession(columns = 12, rows = 2, maxScrollback = 3)
    let second = newTerminalViewSession(columns = 12, rows = 2, maxScrollback = 5)
    defer:
      first.closeAndWait()
      second.closeAndWait()
    first.processOutput("a\r\nb\r\nc\r\nd\r\ne\r\nf\x1b]52;c;aGVsbG8=\x07")
    second.processOutput("other\r\ntext\r\nhistory")
    first.waitForCommands()
    second.waitForCommands()
    check first.screenInfo().scrollbackCount == 3
    check second.screenInfo().scrollbackCount == 1
    # A later snapshot/ACK must not consume an unread clipboard request.
    first.clearScrollback()
    first.waitForCommands()
    check first.screenInfo().scrollbackCount == 0
    check first.screenInfo().clipboardRequestPending
    check first.takeClipboardRequest() == "hello"
    check not first.screenInfo().clipboardRequestPending
    check not second.screenInfo().clipboardRequestPending
    check second.screen().plainText() == "other\ntext\nhistory"

  when not defined(posix):
    test "unsupported native startup reports its failure through the worker":
      let session = newTerminalViewSession()
      defer:
        session.closeAndWait()
      session.start()
      session.waitForCommands()
      check session.state() == tssFailed
      check session.lastError().len > 0
