import AppKit
import MacfileCore

extension UITestRunner {
  func focusTestWindow(_ window: NSWindow) throws {
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
      if NSApp.isActive && NSApp.keyWindow === window && window.isKeyWindow { return }
      if let event = NSApp.nextEvent(
        matching: .any, until: Date().addingTimeInterval(0.02), inMode: .default, dequeue: true)
      {
        NSApp.sendEvent(event)
      }
    }
    try require(
      false,
      "测试窗口未获得真实焦点：active=\(NSApp.isActive)，key=\(NSApp.keyWindow?.title ?? "nil")，"
        + "main=\(NSApp.mainWindow?.title ?? "nil")，target=\(window.title)，"
        + "visible=\(window.isVisible)，canBecomeKey=\(window.canBecomeKey)")
  }
  func addMenuInteractionTests(_ w: WorkspaceController) {
    func entry(_ command: String) -> NSMenuItem {
      let item = NSMenuItem(title: command, action: nil, keyEquivalent: "")
      item.representedObject = command
      return item
    }
    steps.append(
      (
        "utility-menu-routing",
        { [self] in
          let second = app.openWindow(workspace: w.workspace)
          defer {
            second.close()
            w.window?.makeKeyAndOrderFront(nil)
            w.activePane?.focusFiles()
          }
          try focusTestWindow(w.window!)
          let dialog = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
          dialog.title = "菜单路由测试"
          dialog.isReleasedWhenClosed = false
          let utility = NSWindowController(window: dialog)
          w.presentUtility(utility)
          defer {
            utility.close()
            w.utilityControllers.removeAll { $0 === utility }
          }
          try focusTestWindow(dialog)
          let firstBefore = w.workspace
          let secondBefore = second.workspace
          try require(dialog.isKeyWindow && app.active === w, "工具窗口丢失所属工作台")
          for command in ["newTab", "view-icons", "trash", "undoFiles"] {
            try require(!app.validateMenuItem(entry(command)), "工具窗口中仍启用文件命令：" + command)
            app.route(entry(command))
          }
          try require(
            w.workspace == firstBefore && second.workspace == secondBefore,
            "工具窗口中的菜单误改后台工作台")

          let text = NSTextView(frame: NSRect(x: 16, y: 16, width: 328, height: 148))
          text.string = "工具窗口中的路径与任务明细"
          text.isEditable = false
          text.isSelectable = true
          dialog.contentView?.addSubview(text)
          dialog.makeFirstResponder(text)
          text.setSelectedRange(NSRange(location: 0, length: 0))
          try require(app.validateMenuItem(entry("copy")), "只读任务明细不能复制")
          try require(!app.validateMenuItem(entry("paste")), "只读工具窗口启用了文件粘贴")
          app.route(entry("selectAll"))
          try require(
            text.selectedRange().length == (text.string as NSString).length,
            "全选未作用于前台工具窗口文本")
          let close = entry("closeTab")
          try require(app.validateMenuItem(close) && close.title == "关闭窗口", "工具窗口关闭菜单不正确")
          app.route(close)
          try require(!dialog.isVisible, "⌘W 路由未关闭前台工具窗口")
          try require(
            w.workspace == firstBefore && second.workspace == secondBefore,
            "关闭工具窗口误关后台标签")
        }
      ))
    steps.append(
      (
        "shared-command-menu-state",
        { [self] in
          try focusTestWindow(w.window!)
          guard let pane = w.activePane else { return }
          pane.focusFiles()
          let selection = pane.selection
          let locked = w.workspace.locked
          defer {
            pane.selection = selection
            w.workspace.locked = locked
            w.syncToolbar()
          }
          pane.selection = [
            root.appendingPathComponent("菜单测试一"), root.appendingPathComponent("菜单测试二"),
          ]
          w.workspace.locked = true
          w.syncToolbar()
          let menus = (w.window?.toolbar?.items ?? []).compactMap {
            ($0 as? NSMenuToolbarItem)?.menu
          }
          for command in ["rename", "batchRename", "undoFiles", "lock", "tile", "free"] {
            let main = entry(command)
            let allowed = app.validateMenuItem(main)
            let toolbar = menus.flatMap(\.items).first {
              $0.representedObject as? String == command
            }
            try require(toolbar != nil, "工具栏缺少命令：" + command)
            try require(
              toolbar?.isEnabled == allowed && toolbar?.state == main.state,
              "主菜单和工具栏状态不一致：" + command)
          }
          try require(!app.validateMenuItem(entry("rename")), "多选时仍启用单文件重命名")
          try require(app.validateMenuItem(entry("batchRename")), "多选时未启用批量重命名")
        }
      ))
    steps.append(
      (
        "sheet-blocks-background-file-commands",
        { [self] in
          try focusTestWindow(w.window!)
          let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
            styleMask: [.titled], backing: .buffered, defer: false)
          sheet.isReleasedWhenClosed = false
          w.window?.beginSheet(sheet)
          defer {
            w.window?.endSheet(sheet)
            sheet.orderOut(nil)
            w.window?.makeKeyAndOrderFront(nil)
            w.activePane?.focusFiles()
          }
          let before = w.workspace
          try require(!app.validateMenuItem(entry("newTab")), "附属对话框打开时仍启用后台文件命令")
          app.route(entry("newTab"))
          try require(w.workspace == before, "附属对话框中菜单误改后台工作台")
        }
      ))
  }
}
