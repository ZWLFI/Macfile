import AppKit
import MacfileCore

extension UITestRunner {
  func addWorkspaceReliabilityTests(_ w: WorkspaceController) {
    func makeWorkspace() -> WorkspaceController {
      app.openWindow(
        workspace: Workspace(
          name: "工作区交互回归",
          paths: [
            root.appendingPathComponent("资料").path, root.appendingPathComponent("交付").path,
          ]))
    }
    steps.append(
      (
        "layout-undo-keeps-live-browsing",
        { [self] in
          let owner = makeWorkspace()
          defer {
            owner.close()
            w.window?.makeKeyAndOrderFront(nil)
          }
          let originalID = owner.workspace.panes[0].id
          owner.addPane(path: root.appendingPathComponent("资料/归档").path)
          let pane = owner.panes[originalID]!
          pane.navigate(root.appendingPathComponent("资料/归档"))
          pane.addTab(path: root.appendingPathComponent("资料/设计稿").path)
          pane.setMode(.icons)
          pane.searchField.stringValue = "保留搜索"
          owner.activate(originalID)
          let liveState = pane.state
          owner.undoLayout()
          try require(owner.workspace.panes.count == 2, "撤销未恢复分栏数量")
          try require(owner.panes[originalID]?.state == liveState, "撤销布局回退了目录、标签或显示模式")
          try require(
            owner.activePane?.id == originalID && pane.searchField.stringValue == "保留搜索",
            "撤销布局丢失当前分栏或搜索上下文")
        }
      ))
    steps.append(
      (
        "pane-drag-validates-window-and-lock",
        { [self] in
          let owner = makeWorkspace()
          let other = app.openWindow(workspace: owner.workspace)
          defer {
            other.close()
            owner.close()
            w.window?.makeKeyAndOrderFront(nil)
          }
          let source = owner.panes[owner.workspace.panes[0].id]!
          let targetID = owner.workspace.panes[1].id
          let externalTarget = other.panes[targetID]!
          let cross = TestDraggingInfo(urls: [], mask: .move, window: other.window)
          cross.source = source.header
          cross.draggingPasteboard.setString(source.id.uuidString, forType: .macfilePane)
          let before = other.workspace
          try require(
            externalTarget.surface.draggingUpdated(cross).isEmpty,
            "不同主窗口即使包含相同分栏ID也不应接受拖入")
          try require(
            !externalTarget.surface.performDragOperation(cross) && other.workspace == before,
            "跨窗口拖分栏未被明确拒绝")

          let target = owner.panes[targetID]!
          let same = TestDraggingInfo(urls: [], mask: .move, window: owner.window)
          same.source = source.header
          same.draggingPasteboard.setString(source.id.uuidString, forType: .macfilePane)
          same.draggingLocation = target.surface.convert(
            NSPoint(x: target.surface.bounds.midX, y: target.surface.bounds.midY), to: nil)
          try require(target.surface.draggingUpdated(same) == .move, "同窗口分栏拖放被误拒绝")
          try require(
            target.surface.performDragOperation(same)
              && owner.workspace.panes[0].id == targetID, "同窗口中央拖放未交换分栏")
          owner.workspace.locked = true
          try require(
            target.surface.draggingUpdated(same).isEmpty
              && !target.surface.performDragOperation(same), "锁定布局仍接受分栏拖放")
        }
      ))
    steps.append(
      (
        "last-tab-closes-only-its-main-window",
        { [self] in
          let owner = app.openWindow(workspace: Workspace(name: "关闭回归", paths: [root.path]))
          defer {
            if app.controllers.contains(where: { $0 === owner }) { owner.close() }
            w.window?.makeKeyAndOrderFront(nil)
          }
          try focusTestWindow(owner.window!)
          owner.activePane?.addTab(path: root.appendingPathComponent("资料").path)
          owner.command("closeTab")
          try require(
            owner.window?.isVisible == true && owner.activePane?.state.tabs.count == 1,
            "关闭多标签中的一个标签误关主窗口")
          owner.addPane(path: root.appendingPathComponent("交付").path)
          owner.command("closeTab")
          try require(
            owner.window?.isVisible == true && owner.workspace.panes.count == 1,
            "关闭多个分栏中的一个分栏误关主窗口")
          let close = NSMenuItem()
          close.representedObject = "closeTab"
          try focusTestWindow(owner.window!)
          try require(app.validateMenuItem(close) && close.title == "关闭窗口", "最后标签的关闭菜单含义错误")
          app.route(close)
          try require(
            owner.window?.isVisible == false && !app.controllers.contains(where: { $0 === owner }),
            "最后一个标签未关闭所属主窗口")
          try require(w.window?.isVisible == true, "关闭测试窗口影响了其他主窗口")
        }
      ))
    steps.append(
      (
        "volume-notifications-refresh-sidebar",
        { [self] in
          let owner = makeWorkspace()
          defer {
            if app.controllers.contains(where: { $0 === owner }) { owner.close() }
            w.window?.makeKeyAndOrderFront(nil)
          }
          let notifications = NSWorkspace.shared.notificationCenter
          for name in [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
          ] {
            let staleRow = NSView()
            owner.sidebar.addArrangedSubview(staleRow)
            notifications.post(name: name, object: NSWorkspace.shared)
            try require(staleRow.superview == nil, "卷变化通知未刷新侧栏：" + name.rawValue)
            let volumes =
              FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes])
              ?? []
            try require(
              volumes.allSatisfy { url in owner.sidebarItems.contains { $0.1 == url.path } },
              "刷新后设备列表与系统挂载卷不一致")
          }
          owner.close()
          let marker = NSView()
          owner.sidebar.addArrangedSubview(marker)
          notifications.post(name: NSWorkspace.didMountNotification, object: NSWorkspace.shared)
          try require(marker.superview === owner.sidebar, "关闭窗口后仍持有卷通知观察者")
        }
      ))
    steps.append(
      (
        "task-feedback-shows-running-before-queued",
        { [self] in
          let owner = makeWorkspace()
          let saved = app.tasks.records
          defer {
            app.tasks.records = saved
            owner.close()
            w.window?.makeKeyAndOrderFront(nil)
          }
          var running = TaskRecord(title: "任务A", total: 10)
          running.status = .running
          running.current = "正在复制第3项"
          var queued = TaskRecord(title: "任务B", total: 2)
          queued.status = .queued
          app.tasks.records = [queued, running]
          owner.tasksChanged()
          let item = owner.window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "tasks" }
          let button = item?.view as? NSButton
          try require(owner.status.stringValue == "任务A · 正在复制第3项", "新排队任务遮盖实际运行任务进度")
          try require(
            button?.title == "任务 2" && item?.menuFormRepresentation?.title == "任务中心（2）",
            "工具栏及溢出菜单未实际显示进行中任务数")
          running.status = .paused
          running.current = "等待继续"
          app.tasks.records = [queued, running]
          owner.tasksChanged()
          try require(owner.status.stringValue == "任务A · 等待继续", "暂停任务被等待队列遮盖")
          running.status = .completed
          queued.status = .completed
          app.tasks.records = [queued, running]
          owner.tasksChanged()
          try require(button?.title == "任务", "任务结束后数量标记未清除")
        }
      ))
  }
}
