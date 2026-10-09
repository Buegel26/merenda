import std/[os, tempfiles, unittest]

import merenda/nimkit
import merenda/kosmo/kosmo

suite "Kosmo editor pane tab navigation":
  test "<tab> cycles etabs on the strip without entering the editor":
    let
      root = createTempDir("merenda-kosmo-tabnav-", "")
      firstPath = root / "first.txt"
      secondPath = root / "second.txt"
    writeFile(firstPath, "first")
    writeFile(secondPath, "second")
    defer:
      removeFile(firstPath)
      removeFile(secondPath)
      removeDir(root)

    let frontend = newKosmoApplication(newApplication("Kosmo Tab Navigation Test"))
    defer:
      frontend.close()
    frontend.window.setContentView(frontend.contentView)
    frontend.contentView.frame = rect(0, 0, 640, 480)
    frontend.contentView.layoutSubtreeIfNeeded()
    check frontend.openPath(firstPath)
    check frontend.openPath(secondPath)

    let models = frontend.documentTabs.documentTabModels()
    require models.len == 2

    # <tab> from the first etab selects the next etab and keeps focus on the
    # strip instead of entering the editor.
    check frontend.documentTabs.selectDocumentTabWithIdentifier(models[0].identifier)
    check frontend.window.makeFirstResponder(frontend.documentTabs)
    discard frontend.window.dispatchKeyDown(
      KeyEvent(key: keyTab, keyCode: keyTab.ord, text: "")
    )
    check frontend.window.firstResponder() == Responder(frontend.documentTabs)
    check frontend.documentTabs.selectedDocumentTabIdentifier == models[1].identifier

    # <tab> from the last etab leaves the strip but must not enter the editor.
    discard frontend.window.dispatchKeyDown(
      KeyEvent(key: keyTab, keyCode: keyTab.ord, text: "")
    )
    check frontend.window.firstResponder() != Responder(frontend.editorView)
    check frontend.documentTabs.selectedDocumentTabIdentifier == models[1].identifier

    # <shift><tab> from the first etab moves to the previous element and never
    # into the editor.
    check frontend.documentTabs.selectDocumentTabWithIdentifier(models[0].identifier)
    check frontend.window.makeFirstResponder(frontend.documentTabs)
    discard frontend.window.dispatchKeyDown(
      KeyEvent(key: keyTab, keyCode: keyTab.ord, text: "", modifiers: {kmShift})
    )
    check frontend.window.firstResponder() != Responder(frontend.editorView)

  test "<shift><tab> cycles etabs back on the strip":
    let
      root = createTempDir("merenda-kosmo-tabnav-", "")
      firstPath = root / "first.txt"
      secondPath = root / "second.txt"
    writeFile(firstPath, "first")
    writeFile(secondPath, "second")
    defer:
      removeFile(firstPath)
      removeFile(secondPath)
      removeDir(root)

    let frontend = newKosmoApplication(newApplication("Kosmo Tab Navigation Test"))
    defer:
      frontend.close()
    frontend.window.setContentView(frontend.contentView)
    frontend.contentView.frame = rect(0, 0, 640, 480)
    frontend.contentView.layoutSubtreeIfNeeded()
    check frontend.openPath(firstPath)
    check frontend.openPath(secondPath)

    let models = frontend.documentTabs.documentTabModels()
    require models.len == 2

    # <shift><tab> from the second etab selects the previous etab and keeps
    # focus on the strip.
    check frontend.window.makeFirstResponder(frontend.documentTabs)
    discard frontend.window.dispatchKeyDown(
      KeyEvent(key: keyTab, keyCode: keyTab.ord, text: "", modifiers: {kmShift})
    )
    check frontend.window.firstResponder() == Responder(frontend.documentTabs)
    check frontend.documentTabs.selectedDocumentTabIdentifier == models[0].identifier

    # <tab> cycles forward again from the first etab.
    discard frontend.window.dispatchKeyDown(
      KeyEvent(key: keyTab, keyCode: keyTab.ord, text: "")
    )
    check frontend.window.firstResponder() == Responder(frontend.documentTabs)
    check frontend.documentTabs.selectedDocumentTabIdentifier == models[1].identifier

  test "<return> on an etab enters the editor":
    let
      root = createTempDir("merenda-kosmo-tabnav-", "")
      filePath = root / "first.txt"
    writeFile(filePath, "first")
    defer:
      removeFile(filePath)
      removeDir(root)

    let frontend = newKosmoApplication(newApplication("Kosmo Tab Navigation Test"))
    defer:
      frontend.close()
    frontend.window.setContentView(frontend.contentView)
    frontend.contentView.frame = rect(0, 0, 640, 480)
    frontend.contentView.layoutSubtreeIfNeeded()
    check frontend.openPath(filePath)

    check frontend.window.makeFirstResponder(frontend.documentTabs)
    discard frontend.window.dispatchKeyDown(
      KeyEvent(key: keyEnter, keyCode: keyEnter.ord, text: "\r")
    )
    check frontend.window.firstResponder() == Responder(frontend.editorView)

  test "editor normal mode <tab> leaves the editor and <shift><tab> returns to the strip":
    let
      root = createTempDir("merenda-kosmo-tabnav-", "")
      filePath = root / "first.txt"
    writeFile(filePath, "first")
    defer:
      removeFile(filePath)
      removeDir(root)

    let frontend = newKosmoApplication(newApplication("Kosmo Tab Navigation Test"))
    defer:
      frontend.close()
    frontend.window.setContentView(frontend.contentView)
    frontend.contentView.frame = rect(0, 0, 640, 480)
    frontend.contentView.layoutSubtreeIfNeeded()
    check frontend.openPath(filePath)
    require frontend.editorView.editor.mode() == KosmoEditorMode.Normal

    # <tab> in normal mode cycles out of the editor to the next element.
    check frontend.window.makeFirstResponder(frontend.editorView)
    discard frontend.window.dispatchKeyDown(
      KeyEvent(key: keyTab, keyCode: keyTab.ord, text: "")
    )
    check frontend.window.firstResponder() != Responder(frontend.editorView)

    # <shift><tab> in normal mode returns to the pane's etab strip.
    check frontend.window.makeFirstResponder(frontend.editorView)
    discard frontend.window.dispatchKeyDown(
      KeyEvent(key: keyTab, keyCode: keyTab.ord, text: "", modifiers: {kmShift})
    )
    check frontend.window.firstResponder() == Responder(frontend.documentTabs)

  test "focus outside the pane unhighlights the selected etab":
    let
      root = createTempDir("merenda-kosmo-tabnav-", "")
      filePath = root / "first.txt"
    writeFile(filePath, "first")
    defer:
      removeFile(filePath)
      removeDir(root)

    let frontend = newKosmoApplication(newApplication("Kosmo Tab Navigation Test"))
    defer:
      frontend.close()
    frontend.window.setContentView(frontend.contentView)
    frontend.contentView.frame = rect(0, 0, 640, 480)
    frontend.contentView.layoutSubtreeIfNeeded()
    check frontend.openPath(filePath)

    # Focusing the editor pane keeps its selected etab highlighted: the strip
    # carries no kosmo-inactive-pane style class.
    check frontend.window.makeFirstResponder(frontend.editorView)
    check not frontend.documentTabs.hasStyleClass(KosmoInactivePaneStyleClass)

    # Cycling out of the strip at the last etab moves focus to the next ui
    # element (the menubar) and unhighlights the selected etab.
    check frontend.window.makeFirstResponder(frontend.documentTabs)
    discard frontend.window.dispatchKeyDown(
      KeyEvent(key: keyTab, keyCode: keyTab.ord, text: "")
    )
    check frontend.window.firstResponder() != Responder(frontend.editorView)
    check frontend.window.firstResponder() != Responder(frontend.documentTabs)
    check frontend.documentTabs.hasStyleClass(KosmoInactivePaneStyleClass)

    # Focusing the pane again re-highlights the selected etab.
    check frontend.window.makeFirstResponder(frontend.editorView)
    check not frontend.documentTabs.hasStyleClass(KosmoInactivePaneStyleClass)
