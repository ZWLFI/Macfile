import AppKit
import MacfileCore

extension UITestRunner {
  func addPaneInteractionTests(_ w: WorkspaceController) {
    let folder = root.appendingPathComponent("交互浏览")
    let missing = folder.appendingPathComponent("稍后挂载")
    steps.append(("interaction-search-fixtures", { [self] in
      try FileManager.default.createDirectory(
        at: folder.appendingPathComponent("子目录"), withIntermediateDirectories: true)
      for path in ["目标文件.txt", "其他文件.txt", "子目录/目标记录.txt"] {
        try Data("隔离交互测试".utf8).write(to: folder.appendingPathComponent(path))
      }
      try focusTestWindow(w.window!)
      w.activePane?.navigate(folder)
    }))
    steps.append(("interaction-focus-in-all-views", { [self] in
      let pane = w.activePane!
      for mode in ViewMode.allCases {
        pane.setMode(mode)
        pane.beginPathEditing()
        pane.pathField.stringValue = "/未提交的路径"
        try require(pane.control(pane.pathField, textView: NSTextView(),
          doCommandBy: #selector(NSResponder.cancelOperation(_:))), "路径 Escape 未处理")
        let expected: NSView = mode == .list ? pane.table
          : mode == .columns ? pane.browser : pane.collection
        let responder = w.window?.firstResponder as? NSView
        try require(responder === expected || responder?.isDescendant(of: expected) == true,
          "\(mode.rawValue) 取消路径编辑后焦点没有返回可见文件视图")
        try require(pane.currentURL.standardizedFileURL.path == folder.standardizedFileURL.path,
          "取消编辑改变了目录")
      }
      pane.setMode(.list)
      pane.searchField.stringValue = "无匹配文件"
      pane.filterItems()
      w.syncToolbar()
      try require(!pane.searchScopeRow.isHidden && pane.searchScope.selectedSegment == 0,
        "搜索时未显示范围控制")
      try require(pane.items.isEmpty && !pane.emptyActions.isHidden
        && pane.emptyPrimary.title == "清除搜索", "空搜索缺少恢复操作")
      capture("interaction-empty-search", window: w.window!)
      if let other = w.panes.values.first(where: { $0.id != pane.id }) { w.activate(other.id) }
      pane.clearSearchButton.performClick(nil)
      try require(pane.items.count == 3 && pane.searchField.stringValue.isEmpty
        && pane.searchScopeRow.isHidden && w.searchToolbar.searchField.stringValue.isEmpty
        && w.workspace.active == pane.id,
        "清除搜索未恢复当前目录与共享工具栏")
      pane.searchField.stringValue = "目标"
      pane.filterItems()
      try require(pane.items.count == 1, "当前目录范围不正确")
      pane.searchScope.selectedSegment = 1
      if let other = w.panes.values.first(where: { $0.id != pane.id }) { w.activate(other.id) }
      pane.searchScopeChanged()
      try require(w.workspace.active == pane.id && w.searchToolbar.searchField.stringValue == "目标",
        "其他分栏的范围控件未切换当前分栏或同步工具栏")
    }))
    steps.append(("interaction-search-scope-and-keyboard", { [self] in
      let pane = w.activePane!
      try require(pane.recursive && pane.items.count == 2
        && pane.searchScope.selectedSegment == 1, "包含子目录未返回完整搜索结果")
      capture("interaction-search-scope", window: w.window!)
      w.window?.setContentSize(NSSize(width: 800, height: 520))
      w.window?.contentView?.layoutSubtreeIfNeeded()
      w.layoutWorkbench()
      w.window?.contentView?.layoutSubtreeIfNeeded()
      try require(pane.searchScope.frame.width > 130
        && pane.clearSearchButton.frame.maxX <= pane.searchScopeRow.bounds.maxX,
        "窄窗口搜索范围控件被挤出")
      capture("interaction-search-narrow", window: w.window!)
      w.window?.setContentSize(NSSize(width: 1320, height: 840))
      w.layoutWorkbench()
      try require(w.control(w.searchToolbar.searchField, textView: NSTextView(),
        doCommandBy: #selector(NSResponder.cancelOperation(_:))), "工具栏未处理搜索 Escape")
    }))
    steps.append(("interaction-search-clear-and-gallery-error", { [self] in
      let pane = w.activePane!
      try require(pane.items.count == 3 && pane.searchScopeRow.isHidden
        && w.window?.firstResponder === pane.table, "退出递归搜索后未恢复目录及焦点")
      pane.setSearchScope(false)
      pane.setMode(.gallery)
      pane.navigate(missing)
    }))
    steps.append(("interaction-error-actions-and-retry", { [self] in
      let pane = w.activePane!
      try require(pane.readError != nil && !pane.emptyState.isHidden
        && !pane.emptyActions.isHidden && pane.emptyPrimary.title == "重试"
        && !pane.emptySecondary.isHidden && pane.galleryPlaceholder.isHidden,
        "画廊读取失败没有统一恢复入口")
      try require(pane.emptyDetail.stringValue.contains("移动或删除"), "缺失目录提示不明确")
      capture("interaction-gallery-error", window: w.window!)
      try FileManager.default.createDirectory(at: missing, withIntermediateDirectories: true)
      pane.emptyPrimary.performClick(nil)
    }))
    steps.append(("interaction-recovered-empty-directory", { [self] in
      let pane = w.activePane!
      try require(pane.readError == nil && !pane.isLoading && !pane.emptyActions.isHidden
        && pane.emptyPrimary.title == "新建文件夹…" && pane.emptySecondary.isHidden,
        "重试成功后未切换为空目录操作")
      capture("interaction-gallery-empty", window: w.window!)
      pane.setMode(.list)
      pane.navigate(folder)
    }))
  }
}
