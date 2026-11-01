import AppKit
import MacfileCore

// Runs only when explicitly launched with --ui-test and an isolated state directory.
final class UITestRunner {
  unowned let app: AppDelegate
  let root: URL
  var results: [[String: String]] = []
  var steps: [(String, () throws -> Void)] = []
  var stepIndex = 0
  var waitCount = 0
  var taskReliabilityCenters: [TaskCenter] = []
  init(app: AppDelegate, root: URL) {
    self.app = app
    self.root = root
  }
  func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
      throw NSError(
        domain: "MacfileUITest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
  }
  func start() {
    guard let w = app.active else { return }
    do {
      let fm = FileManager.default
      if fm.fileExists(atPath: root.path), !(try fm.contentsOfDirectory(atPath: root.path)).isEmpty
      {
        finish(error: "测试目录已有内容，请使用新的 MACFILE_STATE_DIR，避免覆盖文件。")
        return
      }
      for path in ["资料", "交付", "资料/设计稿", "资料/归档"] {
        try fm.createDirectory(
          at: root.appendingPathComponent(path), withIntermediateDirectories: true)
      }
      for (name, content) in [
        ("产品说明.md", "# Macfile\n多目录自由工作台"), ("需求清单.txt", "多窗口\n布局库\n拖放与书签"),
        ("发布记录.csv", "version,status\n1.0,testing"), ("归档/历史记录.txt", "历史记录"),
      ] { try Data(content.utf8).write(to: root.appendingPathComponent("资料/" + name)) }
      let image = NSImage(size: NSSize(width: 600, height: 400))
      image.lockFocus()
      NSColor(srgbRed: 0.9, green: 0.94, blue: 1, alpha: 1).setFill()
      NSRect(x: 0, y: 0, width: 600, height: 400).fill()
      NSColor.mfAccent.setFill()
      NSBezierPath(
        roundedRect: NSRect(x: 70, y: 70, width: 210, height: 270), xRadius: 22, yRadius: 22
      ).fill()
      NSColor.systemTeal.setFill()
      NSBezierPath(
        roundedRect: NSRect(x: 310, y: 70, width: 210, height: 120), xRadius: 22, yRadius: 22
      ).fill()
      NSBezierPath(
        roundedRect: NSRect(x: 310, y: 220, width: 210, height: 120), xRadius: 22, yRadius: 22
      ).fill()
      image.unlockFocus()
      if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: .png, properties: [:])
      {
        try data.write(to: root.appendingPathComponent("资料/工作台概念.png"))
      }
    } catch {
      finish(error: error.localizedDescription)
      return
    }
    w.workspace = Workspace(
      name: "Macfile · 产品工作台",
      paths: [root.appendingPathComponent("资料").path, root.appendingPathComponent("交付").path])
    w.rebuild()
    steps.append(
      (
        "initial-directory-and-layout",
        { [self] in
          try require(w.activePane?.items.count == 6, "文件枚举结果不正确")
          try require(
            w.panes.values.allSatisfy { $0.view.frame.width >= 260 && $0.view.frame.height >= 240 },
            "目录窗口尺寸不足")
          try require(w.window?.contentView?.hasAmbiguousLayout == false, "主窗口约束不明确")
          capture("ui-list", window: w.window!)
        }
      ))
    for mode in ViewMode.allCases {
      steps.append(
        (
          "switch-\(mode.rawValue)",
          { [self] in
            w.activePane?.setMode(mode)
            try require(w.activePane?.state.current.mode == mode, "视图未切换")
            w.window?.contentView?.layoutSubtreeIfNeeded()
            capture("ui-view-\(mode.rawValue)", window: w.window!)
          }
        ))
    }
    steps.append(
      (
        "gallery-default-selection-and-image-request",
        { [self] in
          let pane = w.activePane!
          try require(
            pane.selectedURLs.count == 1
              && pane.selectedURLs[0].lastPathComponent == "工作台概念.png"
              && pane.collection.selectionIndexPaths.count == 1,
            "画廊未默认选中可预览文件")
          pane.selection = [root.appendingPathComponent("资料/工作台概念.png")]
          pane.reloadViews()
          pane.selection = [root.appendingPathComponent("资料/归档")]
          pane.reloadViews()
          try require(
            !pane.galleryImageLoading && !pane.galleryPlaceholder.isHidden,
            "快速切到文件夹未取消图片预览")
          pane.selection = [root.appendingPathComponent("资料/工作台概念.png")]
          pane.reloadViews()
          pane.refresh()
          try require(!pane.galleryImageLoading, "刷新未取消旧图片预览请求")
        }
      ))
    steps.append(
      (
        "gallery-image-preview-and-folder-placeholder",
        { [self] in
          let pane = w.activePane!
          w.window?.contentView?.layoutSubtreeIfNeeded()
          try require(
            pane.galleryImageURL?.path == root.appendingPathComponent("资料/工作台概念.png").path
              && !pane.galleryImageLoading && pane.galleryImage.image != nil
              && !pane.galleryImage.isHidden && pane.galleryPreview.isHidden
              && pane.galleryPlaceholder.isHidden
              && pane.galleryHost.frame.height > 100 && pane.fileScroll.frame.height > 100,
            "画廊预览未显示或上下区域塌缩")
          capture("ui-gallery-image", window: w.window!)
          pane.selection = [root.appendingPathComponent("资料/归档")]
          pane.reloadViews()
          try require(
            pane.galleryPreview.isHidden && !pane.galleryPlaceholder.isHidden
              && pane.galleryImage.isHidden && !pane.galleryImageLoading
              && pane.galleryTitle.stringValue == "归档" && !pane.galleryHint.isHidden,
            "选中文件夹后画廊留下空白预览区")
          capture("ui-gallery-folder", window: w.window!)
        }
      ))
    steps.append(
      (
        "shared-toolbar-search",
        { [self] in
          let left = w.panes[w.workspace.panes[0].id]!
          w.activate(left.id)
          w.searchToolbar.searchField.stringValue = "产品"
          w.controlTextDidChange(
            Notification(
              name: NSControl.textDidChangeNotification, object: w.searchToolbar.searchField))
          try require(left.tabStrip.isHidden, "单标签仍占用额外一行")
        }
      ))
    steps.append(
      (
        "shared-toolbar-routing",
        { [self] in
          let left = w.panes[w.workspace.panes[0].id]!
          let right = w.panes[w.workspace.panes[1].id]!
          try require(left.items.count == 1 && left.items[0].name == "产品说明.md", "全局搜索未作用于当前分栏")
          w.activate(right.id)
          try require(w.searchToolbar.searchField.stringValue.isEmpty, "切换分栏未恢复独立搜索")
          w.viewSegments.selectedSegment = 1
          w.toolbarViewChanged(w.viewSegments)
          try require(
            right.state.current.mode == .icons && left.state.current.mode == .gallery, "显示模式误改其他分栏")
          w.activate(left.id)
          try require(w.searchToolbar.searchField.stringValue == "产品", "切回分栏丢失搜索")
          w.searchToolbar.searchField.stringValue = ""
          w.controlTextDidChange(
            Notification(
              name: NSControl.textDidChangeNotification, object: w.searchToolbar.searchField))
          left.setMode(.list)
        }
      ))
    steps.append(
      (
        "path-edit-and-cancel",
        { [self] in
          let pane = w.activePane!
          w.command("editPath")
          try require(!pane.pathField.isHidden && pane.breadcrumbs.isHidden, "路径编辑未显示")
          pane.pathField.stringValue = root.appendingPathComponent("交付").path
          let handled = pane.control(
            pane.pathField, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
          try require(
            handled && pane.pathField.isHidden && pane.currentURL.lastPathComponent == "资料",
            "Escape 未取消路径编辑")
          pane.beginPathEditing()
          pane.pathField.stringValue = root.appendingPathComponent("交付").path
          pane.pathEntered()
          try require(
            pane.currentURL.lastPathComponent == "交付" && pane.pathField.isHidden, "路径确认未导航")
          pane.back()
          try require(pane.currentURL.lastPathComponent == "资料", "路径导航破坏历史")
          try require(
            pane.breadcrumbs.pathItems.count <= 2
              && pane.breadcrumbs.pathItems.last?.url?.standardizedFileURL.path
                == pane.currentURL.standardizedFileURL.path,
            "紧凑路径丢失当前目录")
        }
      ))
    steps.append(
      (
        "tabs-independent",
        { [self] in
          guard let pane = w.activePane else { return }
          pane.addTab(path: root.appendingPathComponent("交付").path)
          try require(pane.state.tabs.count == 2, "未添加标签")
          try require(!pane.tabStrip.isHidden, "多个标签未显示标签栏")
          pane.selectTab(0)
          try require(pane.currentURL.lastPathComponent == "资料", "标签目录丢失")
          pane.setMode(.list)
        }
      ))
    steps.append(
      (
        "navigation-loading-clears-old-files",
        { [self] in
          let pane = w.activePane!
          pane.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
          pane.queue.isSuspended = true
          defer { pane.queue.isSuspended = false }
          pane.navigate(root.appendingPathComponent("交付"))
          try require(pane.items.isEmpty && pane.allItems.isEmpty, "新路径仍显示旧目录内容")
          try require(pane.selectedURLs.isEmpty && pane.table.numberOfRows == 0, "旧文件仍可被选中")
          try require(
            pane.isLoading && !pane.loadingIndicator.isHidden
              && pane.emptyLabel.stringValue == "正在读取…", "加载中未显示明确反馈")
          capture("ui-loading", window: w.window!)
          // Queued results from abandoned locations must not replace the last navigation.
          pane.navigate(root.appendingPathComponent("不存在的位置"))
          pane.navigate(root.appendingPathComponent("资料"))
        }
      ))
    steps.append(
      (
        "navigation-latest-result-and-refresh-selection",
        { [self] in
          let pane = w.activePane!
          try require(pane.items.count == 6 && pane.readError == nil, "过期导航结果覆盖当前目录")
          try require(!pane.isLoading && pane.loadingIndicator.isHidden, "完成读取后仍在加载")
          try checkListCells(pane)
          pane.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
          let selected = pane.selectedURLs
          pane.queue.isSuspended = true
          defer { pane.queue.isSuspended = false }
          pane.refresh()
          try require(pane.items.count == 6 && pane.selectedURLs == selected, "同目录刷新清空内容或选择")
        }
      ))
    steps.append(
      (
        "refresh-preserves-selection-and-error-request",
        { [self] in
          let pane = w.activePane!
          try require(pane.selectedURLs.count == 1, "同目录刷新完成后丢失选择")
          pane.navigate(root.appendingPathComponent("不存在的位置"))
        }
      ))
    steps.append(
      (
        "unavailable-location-feedback",
        { [self] in
          let pane = w.activePane!
          try require(
            pane.readError != nil && !pane.isLoading && pane.loadingIndicator.isHidden,
            "读取失败未结束加载状态")
          try require(
            pane.items.isEmpty && pane.selectedURLs.isEmpty
              && pane.countLabel.stringValue == "位置不可用"
              && pane.emptyLabel.stringValue.contains("无法读取此位置"), "读取失败被误报为空目录")
          pane.filterItems()
          try require(pane.countLabel.stringValue == "位置不可用", "筛选覆盖了读取错误提示")
          capture("ui-unavailable", window: w.window!)
          pane.back()
        }
      ))
    steps.append(
      (
        "tab-navigation-and-search-context",
        { [self] in
          let pane = w.activePane!
          try require(pane.items.count == 6 && pane.readError == nil, "后退未恢复可访问目录")
          pane.navigate(root.appendingPathComponent("资料/归档"))
          pane.back()
          pane.searchField.stringValue = "产品"
          pane.recursive = true
          pane.scopeButton.state = .on
          let previous = pane.history
          let next = pane.forwardHistory
          pane.selectTab(1)
          try require(pane.searchField.stringValue.isEmpty && !pane.recursive, "新标签继承了其他标签搜索")
          pane.navigate(root.appendingPathComponent("资料/设计稿"))
          pane.searchField.stringValue = "独立查询"
          pane.selectTab(0)
          try require(
            pane.history == previous && pane.forwardHistory == next
              && pane.searchField.stringValue == "产品" && pane.recursive,
            "切回标签丢失导航历史或搜索范围")
          let token = pane.generation
          pane.selectTab(0)
          try require(pane.generation == token && pane.history == previous, "点击当前标签重置导航")
          pane.forward()
          try require(pane.currentURL.lastPathComponent == "归档", "标签前进历史不可用")
        }
      ))
    steps.append(
      (
        "reused-list-cells-and-close-tab-context",
        { [self] in
          let pane = w.activePane!
          try require(pane.items.count == 1 && pane.items[0].name == "历史记录.txt", "标签前进后内容错误")
          try checkListCells(pane)
          pane.back()
          pane.recursive = false
          pane.scopeButton.state = .off
          pane.selectTab(1)
          try require(
            pane.searchField.stringValue == "独立查询" && !pane.recursive
              && pane.history.last == root.appendingPathComponent("交付").path,
            "另一个标签的历史或查询被覆盖")
          pane.closeTab()
          try require(
            pane.currentURL.lastPathComponent == "资料" && pane.searchField.stringValue.isEmpty
              && !pane.recursive && pane.state.tabs.count == 1,
            "关闭标签未恢复相邻标签状态")
        }
      ))
    steps.append(
      (
        "create-overflowing-tabs",
        { [self] in
          let pane = w.activePane!
          pane.queue.isSuspended = true
          defer { pane.queue.isSuspended = false }
          for _ in 0..<7 { pane.addTab(path: root.appendingPathComponent("交付").path) }
        }
      ))
    steps.append(
      (
        "closable-tabs-and-selected-tab-visibility",
        { [self] in
          let pane = w.activePane!
          let original = pane.state.tabs[0].id
          pane.queue.isSuspended = true
          defer {
            pane.selectTab(0)
            while pane.state.tabs.count > 1 { pane.closeTab(pane.state.tabs.last!.id) }
            pane.queue.isSuspended = false
          }
          w.window?.contentView?.layoutSubtreeIfNeeded()
          let selected = pane.tabs.arrangedSubviews[pane.state.selectedTab]
          let visible = pane.tabScroll.documentVisibleRect
          capture("ui-overflow-tabs", window: w.window!)
          try require(
            selected.frame.width > 0 && visible.intersects(selected.frame)
              && selected.frame.maxX <= visible.maxX + 1,
            "新标签未滚动到可见区域：tab=\(selected.frame), visible=\(visible), document=\(pane.tabs.frame)")
          let lastTab = pane.state.current.id
          w.command("previousTab")
          try require(pane.state.current.id != lastTab, "上一个标签命令未切换")
          w.command("nextTab")
          try require(pane.state.current.id == lastTab, "下一个标签命令未切回")
          pane.selectTab(0)
          let token = pane.generation
          pane.closeTab(pane.state.tabs[2].id)
          try require(
            pane.state.current.id == original && pane.generation == token,
            "关闭后台标签改变了当前目录或触发重载")
          while pane.state.tabs.count > 1 { pane.closeTab(pane.state.tabs.last!.id) }
          try require(pane.tabStrip.isHidden && pane.state.current.id == original, "关闭标签后栏未收起")
        }
      ))
    steps.append(
      (
        "context-menu-matches-selection",
        { [self] in
          try focusTestWindow(w.window!)
          let pane = w.activePane!
          guard let fileURL = pane.items.first(where: { !$0.isFolder })?.url,
            let folderURL = pane.items.first(where: { $0.isFolder })?.url
          else {
            throw NSError(
              domain: "MacfileUITest", code: 1,
              userInfo: [NSLocalizedDescriptionKey: "菜单测试资料未加载"])
          }
          pane.selection.removeAll()
          let background = Set(
            pane.contextMenu().items.compactMap { $0.representedObject as? String })
          try require(
            background.contains("newFolder") && background.contains("paste")
              && background.isDisjoint(with: ["trash", "rename", "copy", "open", "preview"]),
            "空白区域菜单包含文件选择操作")
          w.window?.makeFirstResponder(pane.table)
          let rename = NSMenuItem()
          rename.representedObject = "rename"
          let trash = NSMenuItem()
          trash.representedObject = "trash"
          try require(
            !app.validateMenuItem(rename) && !app.validateMenuItem(trash),
            "没有选择文件时主菜单仍允许重命名或移入废纸篓")
          let mode = NSMenuItem()
          mode.representedObject = "view-" + pane.state.current.mode.rawValue
          try require(app.validateMenuItem(mode) && mode.state == .on, "主菜单未勾选当前视图")
          pane.selection = [fileURL]
          try require(
            app.validateMenuItem(rename) && app.validateMenuItem(trash),
            "选择单个文件后主菜单操作未启用")
          let file = Set(pane.contextMenu().items.compactMap { $0.representedObject as? String })
          try require(
            file.contains("rename") && file.contains("trash") && !file.contains("openTab"),
            "普通文件菜单允许作为目录标签打开")
          pane.selection = [folderURL]
          let folder = Set(pane.contextMenu().items.compactMap { $0.representedObject as? String })
          try require(folder.contains("openTab") && folder.contains("openPane"), "文件夹菜单缺少打开位置操作")
          pane.selection.removeAll()
          pane.reloadViews()
        }
      ))
    steps.append(
      (
        "empty-column-pane-activation",
        { [self] in
          let left = w.panes[w.workspace.panes[0].id]!
          let right = w.panes[w.workspace.panes[1].id]!
          right.setMode(.columns)
          w.activate(left.id)
          right.browserSelected()
          try require(w.workspace.active == right.id, "空分栏交互未激活目标目录")
          right.setMode(.icons)
          w.activate(left.id)
        }
      ))
    steps.append(
      (
        "search-filter",
        {
          w.activePane?.searchField.stringValue = "产品"
          w.activePane?.filterItems()
        }
      ))
    steps.append(
      (
        "search-result",
        { [self] in
          try require(w.activePane?.items.count == 1, "搜索结果不正确")
          w.activePane?.searchField.stringValue = ""
          w.activePane?.filterItems()
        }
      ))
    steps.append(
      (
        "recursive-search",
        {
          w.activePane?.recursive = true
          w.activePane?.searchField.stringValue = "历史"
          w.activePane?.refresh()
        }
      ))
    steps.append(
      (
        "recursive-result",
        { [self] in
          try require(w.activePane?.items.first?.name == "历史记录.txt", "子目录搜索不正确")
          w.activePane?.recursive = false
          w.activePane?.searchField.stringValue = ""
          w.activePane?.refresh()
        }
      ))
    steps.append(
      (
        "split-and-layout",
        { [self] in
          w.addPane(horizontal: true)
          try require(w.workspace.panes.count == 3, "分割未添加窗口")
          w.applyPreset(LayoutPreset.all.first { $0.count == 4 && $0.id.hasPrefix("lead") }!)
          try require(w.workspace.panes.count == 4, "布局未补齐窗口")
        }
      ))
    steps.append(
      (
        "free-placement-and-undo",
        { [self] in
          w.command("free")
          let id = w.workspace.active
          w.updateFreeFrame(
            id, origin: NSPoint(x: 96, y: 80), size: NSSize(width: 460, height: 340), commit: true)
          try require(w.workspace.frames[id]?.x == 96, "自由位置未保存")
          w.command("undoLayout")
          w.command("tile")
        }
      ))
    steps.append(
      (
        "cross-pane-rearrange",
        { [self] in
          let a = w.workspace.panes[0].id
          let b = w.workspace.panes[1].id
          w.rearrange(a, relativeTo: b, zone: "bottom")
          try require(
            Set(w.workspace.tree?.leaves ?? []) == Set(w.workspace.panes.map(\.id)), "重排丢失窗口")
        }
      ))
    steps.append(
      (
        "layout-dialog",
        { [self] in
          w.showLayouts()
          try require(w.utilityControllers.last?.window?.isVisible == true, "布局库未打开")
          capture("ui-layout-library", window: w.utilityControllers.last!.window!)
          w.utilityControllers.last?.close()
        }
      ))
    steps.append(
      (
        "thirty-two-panes",
        { [self] in
          for _ in w.workspace.panes.count..<32 {
            w.workspace.panes.append(PaneState(path: root.appendingPathComponent("资料").path))
          }
          w.workspace.arrangement = .tile
          w.workspace.tree = nil
          w.workspace.columns = 4
          w.rebuild()
          try require(w.panes.count == 32, "目录窗口数量受限")
        }
      ))
    steps.append(
      (
        "restore-and-bookmarks",
        { [self] in
          w.workspace = Workspace(
            name: "Macfile · 产品工作台",
            paths: [root.appendingPathComponent("资料").path, root.appendingPathComponent("交付").path])
          w.rebuild()
          app.state.bookmarks = [
            Bookmark(name: "项目资料", path: root.appendingPathComponent("资料").path)
          ]
          app.state.basket = [root.appendingPathComponent("资料/产品说明.md").path]
          app.state.searches = [
            SavedSearch(
              name: "历史记录", root: root.appendingPathComponent("资料").path, query: "历史",
              recursive: true)
          ]
          app.refreshShared()
          app.save()
          let restored = try app.store.load()
          try require(restored.session == w.workspace, "会话恢复不一致")
          try require(
            restored.bookmarks.count == 1 && restored.basket.count == 1
              && restored.searches.count == 1, "管理数据未保存")
        }
      ))
    steps.append(
      (
        "real-copy-task",
        { [self] in
          app.tasks.transfer(
            [root.appendingPathComponent("资料/产品说明.md")], to: root.appendingPathComponent("交付"),
            move: false, conflict: .ask)
        }
      ))
    steps.append(
      (
        "copy-verification",
        { [self] in
          try require(app.tasks.records.first?.status == .completed, "复制任务未完成")
          try require(FileOperations.exists(root.appendingPathComponent("交付/产品说明.md")), "目标文件不存在")
          w.showTasks()
          let tasks = w.tasksController!
          tasks.window?.contentView?.layoutSubtreeIfNeeded()
          try require(
            tasks.selected?.id == app.tasks.records.first?.id
              && tasks.detail.frame.width > 100
              && tasks.detail.string.contains(root.appendingPathComponent("交付/产品说明.md").path),
            "任务中心未默认显示最新任务与实际文件位置")
          try require(
            tasks.undoButton.isEnabled == !app.tasks.hasActive
              && !tasks.pauseButton.isEnabled && !tasks.cancelButton.isEnabled,
            "已完成任务的可用操作状态不正确")
          capture("ui-tasks", window: w.tasksController!.window!)
          w.tasksController?.close()
        }
      ))
    steps.append(
      (
        "rename-dialog",
        { [self] in
          let pane = w.activePane!
          pane.selection = [
            root.appendingPathComponent("资料/产品说明.md"), root.appendingPathComponent("资料/需求清单.txt"),
          ]
          w.showRename()
          try require(w.utilityControllers.last?.window?.title == "批量重命名", "重命名对话框未打开")
          capture("ui-rename", window: w.utilityControllers.last!.window!)
          w.utilityControllers.last?.close()
        }
      ))
    steps.append(
      (
        "manager-selection-and-empty-results",
        { [self] in
          let manager = ManagerController(
            title: "管理列表交互验证", subtitle: "选择项目后显示可用操作。",
            rows: [
              ManagerRow(id: "first", title: "项目资料", subtitle: "本地工作目录"),
              ManagerRow(id: "second", title: "交付资料", subtitle: "交付文件夹"),
            ], extras: ["移除引用", "清理失效引用"], actionsWithoutSelection: ["清理失效引用"])
          w.presentUtility(manager)
          defer { manager.close() }
          try require(!manager.primaryButton.isEnabled, "管理列表无选择时主操作仍可执行")
          manager.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
          manager.rows.reverse()
          manager.search.stringValue = "资料"
          manager.filter()
          try require(
            manager.selectedIDs == ["second"] && manager.primaryButton.isEnabled,
            "筛选或重新排序后选择了不同项目")
          capture("ui-manager", window: manager.window!)
          manager.search.stringValue = "无匹配内容"
          manager.filter()
          try require(
            manager.selectedIDs.isEmpty && !manager.emptyLabel.isHidden
              && !manager.primaryButton.isEnabled
              && manager.actionMenu.items.first(where: { $0.title == "移除引用" })?.isEnabled == false
              && manager.actionMenu.items.first(where: { $0.title == "清理失效引用" })?.isEnabled == true,
            "空搜索结果下管理操作启用状态错误")
        }
      ))
    steps.append(
      (
        "final-workbench",
        { [self] in
          w.activePane?.setMode(.list)
          let right = w.workspace.panes[1].id
          w.panes[right]?.navigate(root.appendingPathComponent("资料"))
          w.panes[right]?.setMode(.thumbnails)
          w.showBasket()
          w.utilityControllers.last?.close()
          w.showOverview()
          w.utilityControllers.last?.close()
          w.showSearches()
          w.utilityControllers.last?.close()
          w.showCommands()
          let commands = w.utilityControllers.last as! ManagerController
          commands.search.stringValue = "检查器"
          commands.filter()
          try require(
            commands.selectedIDs == ["inspector"] && commands.primaryButton.isEnabled,
            "快捷操作未选择首个搜索结果")
          let inspectorWasVisible = w.inspectorVisible
          let handled = commands.control(
            commands.search, textView: NSTextView(),
            doCommandBy: #selector(NSResponder.insertNewline(_:)))
          try require(handled && w.inspectorVisible != inspectorWasVisible, "Return 未执行筛选后的快捷操作")
          w.toggleInspector()
        }
      ))
    steps.append(
      (
        "final-capture",
        { [self] in
          capture("ui-final", window: w.window!)
          app.save()
        }
      ))
    steps.append(
      (
        "thumbnail-content-bounds",
        { [self] in
          let right = w.panes[w.workspace.panes[1].id]!
          right.collection.layoutSubtreeIfNeeded()
          for case let tile as FileTile in right.collection.visibleItems() {
            tile.view.layoutSubtreeIfNeeded()
            for child in [tile.icon, tile.name, tile.detail] {
              let bounds = child.convert(child.bounds, to: tile.view)
              try require(
                tile.view.bounds.insetBy(dx: -1, dy: -1).contains(bounds),
                "缩略图内容超出单元格：\(tile.url?.lastPathComponent ?? "") \(bounds) / \(tile.view.bounds)")
            }
          }
        }
      ))
    steps.append(
      (
        "new-window-restoration-size",
        { [self] in
          let second = app.openWindow(workspace: w.workspace)
          try require(second.canvas.frame.width >= second.scroll.contentSize.width - 1, "恢复窗口未铺满")
          try require(
            second.panes.values.allSatisfy { $0.view.frame.height > 500 }, "启动布局使用了未显示的窗口尺寸")
          app.save()
          let persisted = try app.store.load()
          try require(persisted.sessions?.count == 2, "多主窗口未保存")
          second.close()
        }
      ))
    steps.append(
      (
        "drag-pasteboard-and-modifiers",
        { [self] in
          let source = root.appendingPathComponent("资料/需求清单.txt")
          let target = root.appendingPathComponent("交付")
          let info = TestDraggingInfo(urls: [source], mask: [.copy, .move], window: w.window)
          try require(FileDrop.urls(info) == [source], "标准文件 URL 拖放数据无法读取")
          try require(FileDrop.operation(info, to: target, modifiers: []) == .move, "同卷拖放未选择移动")
          try require(
            FileDrop.operation(info, to: target, modifiers: .option) == .copy, "Option 未选择复制")
          info.mask = .copy
          try require(FileDrop.operation(info, to: target, modifiers: []) == .copy, "外部复制限制未保留")
          let pane = w.activePane!
          let index = pane.items.firstIndex { $0.url == source }!
          let board = NSPasteboard.withUniqueName()
          defer { board.releaseGlobally() }
          try require(
            board.writeObjects([pane.tableView(pane.table, pasteboardWriterForRow: index)!]),
            "拖出数据无法写入剪贴板")
          try require(
            (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
              as? [URL]) == [source], "外部应用无法读取文件 URL")
          try require(FileDrop.receive(info, to: target, owner: w), "拖放复制未提交")
        }
      ))
    steps.append(
      (
        "drag-copy-result",
        { [self] in
          try require(FileOperations.exists(root.appendingPathComponent("交付/需求清单.txt")), "拖放目标未创建")
          try require(FileOperations.exists(root.appendingPathComponent("资料/需求清单.txt")), "复制删除了源")
          try require(app.tasks.records.first?.status == .completed, "拖放任务未完成")
        }
      ))
    steps.append(
      (
        "narrow-window",
        { [self] in
          w.window?.setContentSize(NSSize(width: 800, height: 520))
          w.window?.contentView?.layoutSubtreeIfNeeded()
          w.layoutWorkbench()
          try require(
            w.panes.values.allSatisfy { $0.view.frame.width >= 260 && $0.view.frame.height >= 240 },
            "窄窗口的目录尺寸不足")
          capture("ui-narrow", window: w.window!)
          w.window?.setContentSize(NSSize(width: 1320, height: 840))
          w.window?.contentView?.layoutSubtreeIfNeeded()
          w.layoutWorkbench()
        }
      ))
    steps.append(
      (
        "dark-appearance",
        { [self] in
          w.window?.appearance = NSAppearance(named: .darkAqua)
          capture("ui-dark", window: w.window!)
          w.window?.appearance = nil
          app.save()
        }
      ))
    addDialogInteractionTests(w)
    addMenuInteractionTests(w)
    addFileInteractionTests(w)
    addPaneInteractionTests(w)
    addPaneReliabilityTests(w)
    addWorkspaceReliabilityTests(w)
    addTaskReliabilityTests(w)
    if ProcessInfo.processInfo.environment["MACFILE_TEST_DESIGN_ONLY"] == "1" { steps.removeAll() }
    appendDesignChecks(w)
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.advance() }
  }
  func appendDesignChecks(_ w: WorkspaceController) {
    let project = root.appendingPathComponent("Macfile 项目")
    let source = project.appendingPathComponent("项目资料")
    let delivery = project.appendingPathComponent("发布交付")
    let assets = project.appendingPathComponent("界面素材")
    let archive = project.appendingPathComponent("归档")
    steps.append(
      (
        "design-fixtures",
        { [self] in
          NSApp.activate(ignoringOtherApps: true)
          w.window?.makeKeyAndOrderFront(nil)
          let fm = FileManager.default
          for folder in [source, delivery, assets, archive] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
          }
          for folder in ["01 产品定义", "02 交互设计", "03 视觉规范", "04 验收记录"] {
            try fm.createDirectory(
              at: source.appendingPathComponent(folder), withIntermediateDirectories: true)
          }
          let names = [
            "Macfile 产品需求说明", "多目录工作流与使用场景", "界面信息架构", "路径导航与目录切换", "列表与缩略图显示规范", "书签与收藏管理",
            "文件拖放交互约定", "布局预设与自由排列", "跨应用复制与移动", "快捷键设计", "搜索与筛选规则", "批量重命名说明", "任务中心与异常处理",
            "工作区恢复策略", "无障碍与键盘导航", "深色模式色彩规范", "窗口尺寸适配", "发布检查清单",
          ]
          for (index, name) in names.enumerated() {
            let contents =
              "# \(name)\n\n此文件为 Macfile 界面验证的隔离示例资料。\n\n"
              + String(repeating: "- 浏览多个目录，保留各自的路径、选择和显示模式。\n", count: index + 8)
            try Data(contents.utf8).write(to: source.appendingPathComponent(name + ".md"))
            if index < 13 {
              try Data(contents.utf8).write(to: delivery.appendingPathComponent(name + ".md"))
            }
          }
          try Data("检查项,结果\n启动与恢复,通过\n多目录布局,通过\n搜索路由,通过\n".utf8).write(
            to: delivery.appendingPathComponent("验收结果.csv"))
          try Data("# 版本记录\n\n1.0.1：统一工具栏与连续分栏界面。".utf8).write(
            to: archive.appendingPathComponent("版本记录.md"))
          for (index, title) in ["双目录", "主次分栏", "四分栏", "上下分栏", "三列", "自由摆放"].enumerated() {
            let image = NSImage(size: NSSize(width: 480, height: 320))
            image.lockFocus()
            NSColor(srgbRed: 0.93, green: 0.95, blue: 0.98, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 480, height: 320).fill()
            let rects = LayoutPreset.grid(count: index + 2, columns: index % 3 + 2)
            for (i, rect) in rects.enumerated() {
              (i == 0 ? NSColor.mfAccent : NSColor.systemTeal.withAlphaComponent(0.55)).setFill()
              NSBezierPath(
                roundedRect: NSRect(
                  x: 26 + rect.x * 428, y: 26 + rect.y * 268, width: rect.width * 428 - 8,
                  height: rect.height * 268 - 8), xRadius: 5, yRadius: 5
              ).fill()
            }
            image.unlockFocus()
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            try bitmap.representation(using: .png, properties: [:])!.write(
              to: assets.appendingPathComponent(title + ".png"))
          }
          app.state.bookmarks = [
            Bookmark(name: "Macfile 项目", path: project.path),
            Bookmark(name: "项目资料", path: source.path), Bookmark(name: "发布交付", path: delivery.path),
            Bookmark(name: "界面素材", path: assets.path),
          ]
          w.workspace = Workspace(name: "产品整理", paths: [source.path, delivery.path])
          w.rebuild()
          app.refreshShared()
          w.statusTimer?.invalidate()
          w.statusBar.isHidden = true
          w.statusHeight?.constant = 0
          w.window?.setContentSize(NSSize(width: 1320, height: 780))
          w.window?.contentView?.layoutSubtreeIfNeeded()
          w.layoutWorkbench()
        }
      ))
    steps.append(
      (
        "design-dual-list",
        { [self] in
          let left = w.panes[w.workspace.panes[0].id]!
          let right = w.panes[w.workspace.panes[1].id]!
          try require(left.items.count == 22 && right.items.count == 14, "设计样本未完整读取")
          try require(
            w.sideBackground.window != nil && !w.sideBackground.isHidden
              && w.sideBackground.frame.width == 196, "侧栏被布局系统意外收起")
          try require(
            w.scroll.frame.height > 600 && w.scroll.frame.width > 1000, "工作区被布局系统意外收起")
          try require(
            left.view.frame.minX == 0 && right.view.frame.maxX == w.canvas.bounds.maxX,
            "分栏仍保留外层卡片留白")
          left.table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
          w.activate(left.id)
          w.window?.makeFirstResponder(left.table)
          capture("design-dual-list", window: w.window!)
          w.workspace = Workspace(
            name: "四目录整理", paths: [source.path, delivery.path, assets.path, archive.path])
          w.workspace.panes[2].tabs[0].mode = .thumbnails
          w.rebuild()
        }
      ))
    steps.append(
      (
        "design-four-pane",
        { [self] in
          try require(w.panes.count == 4, "四分栏数量不正确")
          capture("design-four-pane", window: w.window!)
          w.activePane?.addTab(path: archive.path)
          w.activePane?.selectTab(0)
        }
      ))
    steps.append(
      (
        "design-tabs",
        { [self] in
          capture("design-tabs", window: w.window!)
          w.workspace = Workspace(name: "产品整理", paths: [source.path, delivery.path])
          w.rebuild()
          w.window?.setContentSize(NSSize(width: 800, height: 520))
          w.window?.contentView?.layoutSubtreeIfNeeded()
          w.layoutWorkbench()
        }
      ))
    steps.append(
      (
        "design-narrow",
        { [self] in
          for pane in w.panes.values {
            try require(pane.breadcrumbs.pathItems.count == 1, "窄窗口路径未折叠")
            try require(
              pane.table.tableColumns[2].isHidden && pane.table.tableColumns[3].isHidden,
              "窄窗口未让出文件名空间")
            try require(pane.table.tableColumns[0].width >= 180, "窄窗口文件名列过窄")
            try require(
              pane.table.rect(ofColumn: 1).maxX <= pane.fileScroll.contentView.bounds.width + 1,
              "大小列被窄窗口裁切：\(pane.table.rect(ofColumn: 1).maxX) / \(pane.fileScroll.contentView.bounds.width)"
            )
          }
          capture("design-narrow", window: w.window!)
        }
      ))
    steps.append(
      (
        "design-dark",
        { [self] in
          w.window?.setContentSize(NSSize(width: 1320, height: 780))
          w.window?.appearance = NSAppearance(named: .darkAqua)
          w.window?.contentView?.layoutSubtreeIfNeeded()
          w.layoutWorkbench()
          try require(
            w.window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
              && (w.window?.contentView?.bounds.width ?? 0) > 1000,
            "深色截图未应用独立的外观与窗口尺寸")
          capture("design-dark", window: w.window!)
          w.window?.appearance = NSAppearance(named: .aqua)
          app.save()
        }
      ))
  }
  func advance() {
    let busy =
      app.tasks.hasActive
      || taskReliabilityCenters.contains { $0.hasActive }
      || app.active?.panes.values.contains(where: {
        (!$0.queue.isSuspended && $0.queue.operationCount > 0) || $0.galleryImageLoading
      }) == true
    if busy && waitCount < 200 {
      waitCount += 1
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.advance() }
      return
    }
    waitCount = 0
    guard stepIndex < steps.count else {
      finish(error: nil)
      return
    }
    let (name, run) = steps[stepIndex]
    do {
      try run()
      results.append(["test": name, "status": "PASS"])
      print("UI PASS \(name)")
    } catch {
      results.append(["test": name, "status": "FAIL", "error": error.localizedDescription])
      print("UI FAIL \(name): \(error.localizedDescription)")
    }
    stepIndex += 1
    fflush(stdout)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.advance() }
  }
  func checkListCells(_ pane: PaneController) throws {
    pane.table.reloadData()
    pane.view.window?.contentView?.layoutSubtreeIfNeeded()
    for index in pane.items.indices {
      let item = pane.items[index]
      let name = pane.table.view(atColumn: 0, row: index, makeIfNecessary: true) as? NSTableCellView
      let size = pane.table.view(atColumn: 1, row: index, makeIfNecessary: true) as? NSTableCellView
      try require(
        name?.identifier?.rawValue == "file-name" && name?.textField?.stringValue == item.name
          && name?.toolTip == item.url.path, "复用名称单元格显示了旧文件")
      try require(
        size?.identifier?.rawValue == "file-size"
          && size?.textField?.stringValue
            == (item.isFolder ? "—" : bytesFormatter.string(fromByteCount: item.size)),
        "复用大小单元格显示了旧数据")
    }
  }
  func capture(_ name: String, window: NSWindow) {
    window.makeKeyAndOrderFront(nil)
    window.contentView?.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    guard let view = window.contentView?.superview ?? window.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return }
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
      view.cacheDisplay(in: view.bounds, to: rep)
    }
    if let png = rep.representation(using: .png, properties: [:]) {
      try? png.write(to: app.support.appendingPathComponent(name + ".png"))
    }
  }
  func finish(error: String?) {
    if let error { results.append(["test": "runner", "status": "FAIL", "error": error]) }
    try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
      .write(to: app.support.appendingPathComponent("ui-report.json"), options: .atomic)
    print(
      "UI TESTS COMPLETE: \(results.count) checks, \(results.filter { $0["status"] == "FAIL" }.count) failures"
    )
    fflush(stdout)
    if ProcessInfo.processInfo.environment["MACFILE_TEST_EXIT"] == "1" {
      app.save()
      exit(results.contains { $0["status"] == "FAIL" } ? 1 : 0)
    }
  }
}

// Exercises drag contracts without synthesizing mouse input or using the user's pasteboard.
final class TestDraggingInfo: NSObject, NSDraggingInfo {
  let draggingPasteboard = NSPasteboard.withUniqueName()
  var mask: NSDragOperation
  let draggingDestinationWindow: NSWindow?
  var draggingSourceOperationMask: NSDragOperation { mask }
  var draggingLocation = NSPoint.zero
  var draggedImageLocation = NSPoint.zero
  var draggedImage: NSImage? { nil }
  var source: Any?
  var draggingSource: Any? { source }
  var draggingSequenceNumber: Int { 1 }
  var draggingFormation: NSDraggingFormation = .default
  var animatesToDestination = false
  var numberOfValidItemsForDrop = 1
  var springLoadingHighlight: NSSpringLoadingHighlight { .none }
  init(urls: [URL], mask: NSDragOperation, window: NSWindow?) {
    self.mask = mask
    draggingDestinationWindow = window
    super.init()
    draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
  }
  deinit { draggingPasteboard.releaseGlobally() }
  func slideDraggedImage(to screenPoint: NSPoint) {}
  override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
  func resetSpringLoading() {}
  func enumerateDraggingItems(
    options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
    searchOptions: [NSPasteboard.ReadingOptionKey: Any],
    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
  ) {}
}
