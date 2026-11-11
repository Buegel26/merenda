## Reviewing unsaved editors before Kosmo quits.
import std/[monotimes, os, strutils, tempfiles, unittest]

import merenda/nimkit
import merenda/kosmo/kosmo

proc buttonWithTitle(view: View, title: string): Button =
  if view of Button and Button(view).title == title:
    return Button(view)
  for child in view.subviews():
    result = child.buttonWithTitle(title)
    if not result.isNil:
      return

func rectCenter(rect: Rect): Point =
  initPoint(
    rect.origin.x + rect.size.width / 2.0'f32,
    rect.origin.y + rect.size.height / 2.0'f32,
  )

proc clickModalButton(window: Window, title: string): bool =
  let button = window.contentView().buttonWithTitle(title)
  if button.isNil:
    return
  window.clickAt(button.pointToWindow(button.bounds().rectCenter()))

proc presentFrontend(frontend: KosmoApplication) =
  frontend.application.addWindow(frontend.window)
  frontend.window.setContentView(frontend.contentView)
  frontend.contentView.layoutSubtreeIfNeeded()

proc menuItemForAction(menu: Menu, action: string): MenuItem =
  for item in menu.items():
    if item.action().name == actionSelector(action).name:
      return item
    if not item.submenu().isNil:
      let found = item.submenu().menuItemForAction(action)
      if not found.isNil:
        return found

proc typeIntoActiveEditor(frontend: KosmoApplication, text: string) =
  require frontend.window.makeFirstResponder(frontend.editorView)
  require frontend.editorView.editor.handleKey("A")
  require frontend.editorView.editor.handleTextInput(text)
  require frontend.editorView.editor.handleKey("Esc")

proc preservedCopyCount(directory: string): int =
  for kind, entry in walkDir(directory):
    case kind
    of pcFile:
      inc result
    of pcDir:
      result += entry.preservedCopyCount()
    else:
      discard

suite "Kosmo quit":
  test "quitting without unsaved editors terminates immediately":
    let
      app = newApplication("Kosmo Quit Clean")
      manager = newKosmoWindowManager(app)
      frontend = newKosmoApplication(manager, monitorsGitStatus = false)
    defer:
      manager.close()
    frontend.presentFrontend()
    manager.requestQuit()
    check app.modalSession().isNil
    check app.isTerminating()

  test "quitting asks about unsaved editors and cancelling keeps them open":
    let
      root = createTempDir("kosmo-quit-cancel-", "")
      path = root / "modified.txt"
      app = newApplication("Kosmo Quit Cancel Test")
      manager = newKosmoWindowManager(app)
      frontend = newKosmoApplication(manager, root, monitorsGitStatus = false)
    defer:
      removeDir(root)
    defer:
      manager.close()
    writeFile(path, "original")
    frontend.presentFrontend()
    require frontend.openPath(path)
    frontend.typeIntoActiveEditor("!")
    require frontend.editorView.editor.tabs()[0].modified

    manager.requestQuit()
    let session = app.modalSession()
    require not session.isNil
    check session.window.title == "Unsaved Changes"
    check session.parentWindow == frontend.window
    check session.mode == msmWindowModal
    check session.window.clickModalButton("Cancel")
    check app.modalSession().isNil
    check not app.isTerminating()
    check frontend.editorView.editor.tabs()[0].modified
    check readFile(path) == "original"

  test "quitting through Save writes every dirty editor to its file":
    let
      root = createTempDir("kosmo-quit-save-", "")
      firstPath = root / "first.txt"
      secondPath = root / "second.txt"
      app = newApplication("Kosmo Quit Save Test")
      manager = newKosmoWindowManager(app)
      frontend = newKosmoApplication(manager, root, monitorsGitStatus = false)
    defer:
      removeDir(root)
    defer:
      manager.close()
    writeFile(firstPath, "first")
    writeFile(secondPath, "second")
    frontend.presentFrontend()
    let editor = frontend.editorView.editor
    require frontend.openPath(firstPath)
    require frontend.openPath(secondPath)
    require editor.tabs().len == 2

    # Dirty both etabs, ending with the first one selected.
    require frontend.documentTabs.selectDocumentTabAtIndex(1)
    frontend.typeIntoActiveEditor(" edited")
    require frontend.documentTabs.selectDocumentTabAtIndex(0)
    frontend.typeIntoActiveEditor(" edited")
    check editor.tabs()[0].modified
    check editor.tabs()[1].modified

    manager.requestQuit()
    require not app.modalSession().isNil
    check app.modalSession().window.clickModalButton("Save")
    check app.modalSession().isNil
    check app.isTerminating()
    check readFile(firstPath).strip() == "first edited"
    check readFile(secondPath).strip() == "second edited"
    check not editor.tabs()[0].modified
    check not editor.tabs()[1].modified

  test "quitting through Save covers every window of the session":
    let
      root = createTempDir("kosmo-quit-save-windows-", "")
      firstPath = root / "first.txt"
      secondPath = root / "second.txt"
      app = newApplication("Kosmo Quit Save Windows Test")
      manager = newKosmoWindowManager(app)
      first = newKosmoApplication(manager, root, monitorsGitStatus = false)
      second = newKosmoApplication(manager, root, monitorsGitStatus = false)
    defer:
      removeDir(root)
    defer:
      manager.close()
    writeFile(firstPath, "first")
    writeFile(secondPath, "second")
    first.presentFrontend()
    second.presentFrontend()
    require first.openPath(firstPath)
    first.typeIntoActiveEditor(" edited")
    require second.openPath(secondPath)
    second.typeIntoActiveEditor(" edited")
    check first.editorView.editor.tabs()[0].modified
    check second.editorView.editor.tabs()[0].modified

    manager.requestQuit()
    require not app.modalSession().isNil
    check app.modalSession().window.clickModalButton("Save")
    check app.isTerminating()
    check readFile(firstPath).strip() == "first edited"
    check readFile(secondPath).strip() == "second edited"

  test "quitting through Discard All leaves the files and no preserved work":
    let
      root = createTempDir("kosmo-quit-discard-", "")
      path = root / "modified.txt"
      recoveryDirectory = root / "recovery"
      app = newApplication("Kosmo Quit Discard Test")
      manager = newKosmoWindowManager(app)
      frontend = newKosmoApplication(manager, root, monitorsGitStatus = false)
    defer:
      removeDir(root)
    defer:
      manager.close()
    writeFile(path, "original")
    frontend.presentFrontend()
    let editor = frontend.editorView.editor
    editor.configureRecovery(recoveryDirectory)
    require frontend.openPath(path)
    frontend.typeIntoActiveEditor("dirty work")
    require editor.tabs()[0].modified

    # Advance the editor until the periodic recovery checkpoint preserved the
    # unsaved buffer, so quitting has a trace it must not leave behind.
    let deadline = getMonoTime() + initDuration(seconds = 15)
    while getMonoTime() < deadline:
      discard editor.pollFrontendWork()
      if recoveryDirectory.preservedCopyCount() > 0:
        break
      sleep(100)
    require recoveryDirectory.preservedCopyCount() > 0

    manager.requestQuit()
    require not app.modalSession().isNil
    check app.modalSession().window.clickModalButton("Discard All")
    check app.modalSession().isNil
    check app.isTerminating()
    check readFile(path) == "original"
    # The application closes the session after the event loop stops; closing
    # it here runs the same teardown the loop exit performs.
    manager.close()
    check recoveryDirectory.preservedCopyCount() == 0

  test "quitting saves an untitled editor through a Save As panel":
    let
      root = createTempDir("kosmo-quit-save-untitled-", "")
      path = root / "saved.txt"
      app = newApplication("Kosmo Quit Save Untitled Test")
      manager = newKosmoWindowManager(app)
      frontend = newKosmoApplication(manager, root, monitorsGitStatus = false)
      panel = newSavePanel()
    defer:
      removeDir(root)
    defer:
      manager.close()
      panel.window.close()
    frontend.presentFrontend()
    frontend.typeIntoActiveEditor("saved from the quit review")
    require frontend.editorView.editor.tabs()[0].modified
    check frontend.editorView.editor.tabs()[0].filePath.isNone
    panel.nameFieldStringValue = "saved.txt"

    manager.requestQuit(panel)
    require not app.modalSession().isNil
    check app.modalSession().window.clickModalButton("Save")
    check app.modalSession().isNil
    check app.isTerminating()
    check fileExists(path)
    check readFile(path).strip() == "saved from the quit review"
    check frontend.editorView.editor.tabs()[0].filePath.get == absolutePath(path)
    check not frontend.editorView.editor.tabs()[0].modified

  test "an unanswered untitled save cancels quitting":
    let
      root = createTempDir("kosmo-quit-untitled-cancel-", "")
      app = newApplication("Kosmo Quit Untitled Cancel Test")
      manager = newKosmoWindowManager(app)
      frontend = newKosmoApplication(manager, root, monitorsGitStatus = false)
      panel = newSavePanel()
    defer:
      removeDir(root)
    defer:
      manager.close()
      panel.window.close()
    frontend.presentFrontend()
    frontend.typeIntoActiveEditor("still unsaved")
    require frontend.editorView.editor.tabs()[0].modified
    # The panel offers no valid destination, as when the user leaves the Save
    # As panel without choosing one.
    panel.nameFieldStringValue = "saved.txt"
    panel.allowedFileTypes = @["md"]

    manager.requestQuit(panel)
    require not app.modalSession().isNil
    check app.modalSession().window.clickModalButton("Save")
    check app.modalSession().isNil
    check not app.isTerminating()
    check frontend.editorView.editor.tabs()[0].modified
    check frontend.editorView.editor.bufferText(frontend.editorView.editor.tabs()[0].id) ==
      some("still unsaved")

  test "the Quit menu item routes through the review":
    let
      root = createTempDir("kosmo-quit-menu-", "")
      path = root / "modified.txt"
      app = newApplication("Kosmo Quit Menu Test")
      manager = newKosmoWindowManager(app)
      frontend = newKosmoApplication(manager, root, monitorsGitStatus = false)
    defer:
      removeDir(root)
    defer:
      manager.close()
    writeFile(path, "original")
    frontend.presentFrontend()
    require frontend.openPath(path)
    frontend.typeIntoActiveEditor("!")
    require frontend.editorView.editor.tabs()[0].modified

    let quitItem = app.mainMenu().menuItemForAction(KosmoQuitAction)
    require not quitItem.isNil
    check quitItem.action().name == actionSelector(KosmoQuitAction).name
    require quitItem.perform(frontend.window)
    let session = app.modalSession()
    require not session.isNil
    check session.parentWindow == frontend.window
    check session.window.clickModalButton("Cancel")
    check app.modalSession().isNil
    check not app.isTerminating()
    check frontend.editorView.editor.tabs()[0].modified

  test "the primary quit shortcut routes through the review":
    let
      root = createTempDir("kosmo-quit-shortcut-", "")
      path = root / "modified.txt"
      app = newApplication("Kosmo Quit Shortcut Test")
      manager = newKosmoWindowManager(app)
      frontend = newKosmoApplication(manager, root, monitorsGitStatus = false)
    defer:
      removeDir(root)
    defer:
      manager.close()
    writeFile(path, "original")
    frontend.presentFrontend()
    require frontend.openPath(path)
    frontend.typeIntoActiveEditor("!")
    require frontend.editorView.editor.tabs()[0].modified

    check frontend.window.dispatchKeyDown(
      KeyEvent(key: keyQ, keyCode: keyQ.ord, modifiers: shortcutModifiers())
    )
    let session = app.modalSession()
    require not session.isNil
    check session.window.title == "Unsaved Changes"
    check session.window.clickModalButton("Cancel")
    check app.modalSession().isNil
    check not app.isTerminating()
    check frontend.editorView.editor.tabs()[0].modified
