import AppKit
import MacfileCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
  var controllers: [WorkspaceController] = []
  let support: URL
  let store: StateStore
  var state: AppState
  let tasks: TaskCenter
  var persistenceError: Error?
  var testRunner: UITestRunner?
  weak var lastActiveWorkspace: WorkspaceController?
  var active: WorkspaceController? {
    if var window = NSApp.keyWindow {
      while let parent = window.sheetParent { window = parent }
      if let owner = controllers.first(where: {
        $0.window === window || $0.tasksController?.window === window
          || $0.utilityControllers.contains { $0.window === window }
      }) {
        return owner
      }
    }
    if let lastActiveWorkspace, controllers.contains(where: { $0 === lastActiveWorkspace }) {
      return lastActiveWorkspace
    }
    return controllers.last
  }
  var commandWorkspace: WorkspaceController? {
    guard let window = NSApp.keyWindow, window.attachedSheet == nil else { return nil }
    return controllers.first { $0.window === window }
  }
  var commandTextEditor: NSTextView? {
    (NSApp.keyWindow?.attachedSheet ?? NSApp.keyWindow)?.firstResponder as? NSTextView
  }
  func canPerformTextCommand(_ command: String) -> Bool {
    guard let editor = commandTextEditor else { return false }
    switch command {
    case "copy", "selectAll": return true
    case "paste", "undoLayout": return editor.isEditable
    default: return false
    }
  }
  func performTextCommand(_ command: String) -> Bool {
    guard canPerformTextCommand(command), let editor = commandTextEditor else { return false }
    switch command {
    case "copy": editor.copy(nil)
    case "paste": editor.paste(nil)
    case "selectAll": editor.selectAll(nil)
    case "undoLayout": editor.undoManager?.undo()
    default: return false
    }
    return true
  }
  static var stateDirectory: URL {
    if let override = ProcessInfo.processInfo.environment["MACFILE_STATE_DIR"] {
      return URL(fileURLWithPath: override)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Macfile")
  }
  override init() {
    support = Self.stateDirectory
    store = StateStore(url: support.appendingPathComponent("state.json"))
    do { state = try store.load() } catch {
      state = AppState()
      if FileManager.default.fileExists(atPath: store.url.path) { persistenceError = error }
    }
    tasks = TaskCenter(folder: support)
    super.init()
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    makeMenus()
    tasks.onChange = { [weak self] in self?.controllers.forEach { $0.tasksChanged() } }
    if CommandLine.arguments.contains("--ui-test"),
      ProcessInfo.processInfo.environment["MACFILE_STATE_DIR"] != nil
    {
      state = AppState(home: support.appendingPathComponent("fixture"))
    }
    if let sessions = state.sessions, !sessions.isEmpty {
      for session in sessions { openWindow(workspace: session) }
    } else {
      openWindow(workspace: state.session)
    }
    NSApp.activate(ignoringOtherApps: true)
    if CommandLine.arguments.contains("--ui-test"),
      ProcessInfo.processInfo.environment["MACFILE_STATE_DIR"] != nil
    {
      testRunner = UITestRunner(app: self, root: support.appendingPathComponent("fixture"))
      testRunner?.start()
    }
    if let error = persistenceError {
      let backup = store.url.deletingPathExtension().appendingPathExtension(
        "unreadable-\(Int(Date().timeIntervalSince1970)).json")
      try? FileManager.default.copyItem(at: store.url, to: backup)
      showError(
        NSError(
          domain: "Macfile", code: 1,
          userInfo: [NSLocalizedDescriptionKey: "上次工作区无法读取，原文件已保留。\n\(error.localizedDescription)"]),
        window: active?.window)
    }
  }
  @discardableResult func openWindow(workspace: Workspace? = nil) -> WorkspaceController {
    let wc = WorkspaceController(
      app: self,
      workspace: workspace
        ?? Workspace(name: "新工作台", paths: [FileManager.default.homeDirectoryForCurrentUser.path]))
    controllers.append(wc)
    wc.showWindow(nil)
    wc.window?.contentView?.layoutSubtreeIfNeeded()
    wc.layoutWorkbench()
    return wc
  }
  func save() {
    if let active { state.session = active.workspace }
    state.sessions = controllers.map(\.workspace)
    do { try store.save(state) } catch {
      active?.setStatus("工作区保存失败：" + error.localizedDescription)
    }
  }
  func refreshShared() {
    save()
    controllers.forEach { $0.reloadSidebar() }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag { openWindow(workspace: state.session) }
    return true
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    save()
    if tasks.hasActive {
      let alert = NSAlert()
      alert.messageText = "文件操作仍在进行"
      alert.informativeText = "建议等待任务完成。立即退出可能留下待核对的临时文件；下次启动会保留操作记录。"
      alert.addButton(withTitle: "继续等待")
      alert.addButton(withTitle: "退出 Macfile")
      return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
    return .terminateNow
  }
  func application(_ sender: NSApplication, openFiles filenames: [String]) {
    let wc = active ?? openWindow()
    for path in filenames { wc.openPath(URL(fileURLWithPath: path), newPane: true) }
    sender.reply(toOpenOrPrint: .success)
  }
  @objc func route(_ sender: NSMenuItem) {
    let command = sender.representedObject as? String ?? ""
    if command == "newWindow" {
      openWindow()
      return
    }
    if command == "about" {
      NSApp.orderFrontStandardAboutPanel(options: [
        .applicationName: "Macfile",
        .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
          as? String ?? "1.0.4",
        .credits: NSAttributedString(string: "为多目录工作而设计。\n本地文件 · 自由工作台 · macOS 原生体验"),
      ])
      return
    }
    if performTextCommand(command) { return }
    if command == "closeTab", let window = NSApp.keyWindow,
      commandWorkspace == nil, window.sheetParent == nil, window.attachedSheet == nil
    {
      window.performClose(sender)
      return
    }
    commandWorkspace?.command(command)
  }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    guard let command = item.representedObject as? String else { return true }
    if ["about", "newWindow"].contains(command) { return true }
    if canPerformTextCommand(command) { return true }
    if command == "closeTab" {
      item.title = commandWorkspace == nil ? "关闭窗口" : "关闭标签"
      if commandWorkspace == nil {
        guard let window = NSApp.keyWindow else { return false }
        return window.sheetParent == nil && window.attachedSheet == nil
          && window.styleMask.contains(.closable)
      }
    }
    guard let owner = commandWorkspace else { return false }
    return owner.validateMenuItem(item)
  }
  func makeMenus() {
    let main = NSMenu()
    func menu(_ title: String, _ entries: [(String, String, String, NSEvent.ModifierFlags)]) {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let sub = NSMenu(title: title)
      for (name, cmd, key, mods) in entries {
        if name == "-" {
          sub.addItem(.separator())
          continue
        }
        let m = NSMenuItem(title: name, action: #selector(route(_:)), keyEquivalent: key)
        m.keyEquivalentModifierMask = mods
        m.target = self
        m.representedObject = cmd
        sub.addItem(m)
      }
      item.submenu = sub
      main.addItem(item)
    }
    menu(
      "Macfile",
      [("关于 Macfile", "about", "", []), ("-", "", "", []), ("退出 Macfile", "quit", "q", .command)])
    main.items[0].submenu?.items.last?.action = #selector(NSApplication.terminate(_:))
    main.items[0].submenu?.items.last?.target = NSApp
    menu(
      "文件",
      [
        ("新建主窗口", "newWindow", "n", .command), ("添加目录窗口", "addPane", "n", [.command, .option]),
        ("新建标签", "newTab", "t", .command), ("关闭标签", "closeTab", "w", .command),
        ("恢复关闭的目录窗口", "restorePane", "t", [.command, .shift]), ("-", "", "", []),
        ("新建文件夹…", "newFolder", "n", [.command, .shift]), ("重命名…", "rename", "", []),
        ("批量重命名…", "batchRename", "r", [.command, .shift]), ("移入废纸篓", "trash", "\u{8}", .command),
        ("-", "", "", []), ("保存工作区…", "saveWorkspace", "s", .command),
        ("打开位置…", "go", "g", [.command, .shift]),
        ("编辑当前路径", "editPath", "l", .command),
      ])
    menu(
      "编辑",
      [
        ("撤销布局变化", "undoLayout", "z", .command),
        ("撤销上次文件操作", "undoFiles", "z", [.command, .option]), ("-", "", "", []),
        ("复制文件", "copy", "c", .command), ("粘贴文件", "paste", "v", .command),
        ("移动已复制文件到此处", "movePaste", "v", [.command, .option]), ("全选", "selectAll", "a", .command),
        ("复制路径", "copyPath", "c", [.command, .option]), ("-", "", "", []),
        ("复制到…", "copyTo", "", []), ("移动到…", "moveTo", "", []),
      ])
    menu(
      "显示",
      [
        ("列表", "view-list", "1", .command), ("图标", "view-icons", "2", .command),
        ("缩略图", "view-thumbnails", "3", .command), ("分栏", "view-columns", "4", .command),
        ("画廊", "view-gallery", "5", .command), ("-", "", "", []),
        ("显示／隐藏隐藏文件", "hidden", ".", [.command, .shift]), ("快速预览", "preview", "", []),
        ("切换检查器", "inspector", "i", [.command, .option]), ("刷新", "refresh", "r", .command),
        ("搜索当前目录", "search", "f", .command), ("保存当前搜索…", "saveSearch", "f", [.command, .shift]),
      ])
    menu(
      "布局",
      [
        ("布局库…", "layouts", "l", [.command, .option]), ("自动平铺", "tile", "", []),
        ("自由摆放", "free", "", []), ("左右分割", "splitH", "d", .command),
        ("上下分割", "splitV", "d", [.command, .shift]),
        ("放大／还原当前目录", "focus", "\r", [.command, .shift]), ("锁定／解锁布局", "lock", "", []),
        ("窗口总览…", "overview", "o", [.command, .option]), ("收藏当前布局…", "favoriteLayout", "", []),
      ])
    menu(
      "工具",
      [
        ("加入书签…", "bookmark", "d", [.command, .option]), ("管理书签…", "bookmarks", "", []),
        ("加入收集篮", "basketAdd", "b", [.command, .shift]),
        ("收集篮…", "basket", "b", [.command, .option]), ("任务中心…", "tasks", "j", .command),
        ("快捷操作…", "commands", "p", [.command, .shift]), ("在终端中打开", "terminal", "", []),
        ("在 Finder 中显示", "finder", "", []),
      ])
    let windowItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
    let windowMenu = NSMenu(title: "窗口")
    windowMenu.addItem(
      withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(
      withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    windowMenu.addItem(.separator())
    for (title, command, modifiers) in [
      ("选择下一个标签", "nextTab", NSEvent.ModifierFlags.control),
      ("选择上一个标签", "previousTab", NSEvent.ModifierFlags([.control, .shift])),
    ] {
      let item = NSMenuItem(title: title, action: #selector(route(_:)), keyEquivalent: "\t")
      item.target = self
      item.representedObject = command
      item.keyEquivalentModifierMask = modifiers
      windowMenu.addItem(item)
    }
    windowItem.submenu = windowMenu
    main.addItem(windowItem)
    NSApp.windowsMenu = windowMenu
    NSApp.mainMenu = main
  }
}
