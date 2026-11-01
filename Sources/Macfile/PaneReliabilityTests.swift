import AppKit
import MacfileCore
import QuickLookUI

extension UITestRunner {
  func addPaneReliabilityTests(_ w: WorkspaceController) {
    let folder = root.appendingPathComponent("分栏可靠性")
    let child = folder.appendingPathComponent("子目录")
    let leaf = child.appendingPathComponent("深层目录")
    let first = leaf.appendingPathComponent("子文件甲.txt")
    let second = leaf.appendingPathComponent("子文件乙.txt")
    let pasteSource = root.appendingPathComponent("深层粘贴来源.txt")
    var columnPreviewURLs: [URL] = []
    func paths(_ urls: [URL]) -> Set<String> {
      Set(urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
    }
    func select(_ name: String, column: Int, in pane: PaneController) throws {
      try require(pane.browser.lastColumn >= column, "目标列尚未展开")
      let parent =
        (pane.browser.parentForItems(inColumn: column) as? BrowserNode)?.item.url
        ?? pane.currentURL
      guard let index = pane.browserCache[parent.path]?.firstIndex(where: { $0.item.name == name })
      else {
        try require(false, "浏览器列中缺少测试项目：" + name)
        return
      }
      pane.browser.selectRow(index, inColumn: column)
      pane.browserSelected()
    }
    steps.append(
      (
        "reliability-column-fixtures",
        { [self] in
          try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
          for url in [
            first, second, pasteSource, folder.appendingPathComponent("根文件甲.txt"),
            folder.appendingPathComponent("根文件乙.txt"),
          ] {
            try Data(url.lastPathComponent.utf8).write(to: url)
          }
          try focusTestWindow(w.window!)
          let pane = w.activePane!
          pane.navigate(folder)
          pane.setMode(.columns)
        }
      ))
    steps.append(
      (
        "reliability-column-first-level",
        { [self] in
          let pane = w.activePane!
          try require(paths([pane.operationDirectoryURL]) == paths([folder]), "列根目录目标错误")
          try select("子目录", column: 0, in: pane)
        }
      ))
    steps.append(
      (
        "reliability-column-second-level",
        { [self] in
          let pane = w.activePane!
          try require(paths([pane.operationDirectoryURL]) == paths([child]), "展开子目录后操作目标仍是根")
          try select("深层目录", column: 1, in: pane)
        }
      ))
    steps.append(
      (
        "reliability-column-select-all-excludes-root",
        { [self] in
          let pane = w.activePane!
          try select("子文件甲.txt", column: 2, in: pane)
          w.command("selectAll")
          try require(paths(pane.selectedURLs) == paths([first, second]), "全选包含根目录或其他列项目")
          try require(
            pane.browser.selectedColumn == 2
              && pane.browser.selectedRowIndexes(inColumn: 2)?.count == 2,
            "全选后视觉选择与操作选择不一致")
          try require(
            paths([pane.operationDirectoryURL]) == paths([leaf])
              && paths([pane.currentURL]) == paths([folder]), "操作目录与浏览根未正确分开")
          let selectedBytes = Int64(
            try Data(contentsOf: first).count + Data(contentsOf: second).count)
          try require(
            pane.countLabel.stringValue
              == "2 项 · 已选 2 项 · \(bytesFormatter.string(fromByteCount: selectedBytes))",
            "分栏状态栏使用了根目录项目数或错误的选中文件大小")
          capture("reliability-column-selection", window: w.window!)
          pane.quickLook()
          columnPreviewURLs = pane.quickLookURLs
          pane.refresh()
          // Hold child reads after the root result arrives to inspect the intermediate restoration state.
          pane.queue.waitUntilAllOperationsAreFinished()
          pane.queue.isSuspended = true
        }
      ))
    steps.append(
      (
        "reliability-column-restoration-keeps-operation-target",
        { [self] in
          let pane = w.activePane!
          defer { pane.queue.isSuspended = false }
          try require(
            pane.countLabel.stringValue == "正在恢复分栏…" && !pane.loadingIndicator.isHidden,
            "恢复中间态仍显示临时祖先目录的项目计数")
          try require(
            QLPreviewPanel.shared().isVisible && pane.quickLookURLs == columnPreviewURLs,
            "异步恢复期间快速预览跳到了临时选中的祖先目录")
          try require(
            pane.browser.lastColumn < 2
              && paths([pane.operationDirectoryURL]) == paths([leaf]) && pane.selectedURLs.isEmpty,
            "恢复中间态将粘贴目录或文件操作选择切换到临时祖先")
          pane.selectAll()
          try require(
            pane.selectedURLs.isEmpty && paths([pane.operationDirectoryURL]) == paths([leaf]),
            "恢复中间态全选了临时祖先列")
        }
      ))
    steps.append(
      (
        "reliability-column-refresh-restores-path-and-selection",
        { [self] in
          let pane = w.activePane!
          try require(
            pane.browser.lastColumn == 2 && pane.browser.selectedColumn == 2,
            "刷新折叠了已展开的列")
          try require(
            paths(pane.selectedURLs) == paths([first, second])
              && pane.browser.selectedRowIndexes(inColumn: 2)?.count == 2
              && paths([pane.operationDirectoryURL]) == paths([leaf]),
            "刷新丢失深层多选或改变操作目标")
          try require(
            QLPreviewPanel.shared().isVisible && pane.quickLookURLs == pane.selectedURLs,
            "深层多选恢复后快速预览未同步")
          pane.quickLook()
          try FileManager.default.removeItem(at: second)
          pane.refresh()
        }
      ))
    steps.append(
      (
        "reliability-column-refresh-drops-only-missing-selection",
        { [self] in
          let pane = w.activePane!
          try require(
            paths(pane.selectedURLs) == paths([first])
              && pane.browser.selectedRowIndexes(inColumn: 2)?.count == 1
              && paths([pane.operationDirectoryURL]) == paths([leaf]),
            "刷新保留已删除文件或丢失仍存在的深层选择")
          capture("reliability-column-refresh", window: w.window!)
          let board = NSPasteboard.withUniqueName()
          defer { board.releaseGlobally() }
          try require(board.writeObjects([pasteSource as NSURL]), "无法设置隔离粘贴数据")
          w.pasteFiles(move: false, from: board)
        }
      ))
    steps.append(
      (
        "reliability-column-paste-writes-only-visible-directory",
        { [self] in
          let pane = w.activePane!
          let pasted = leaf.appendingPathComponent(pasteSource.lastPathComponent)
          try require(
            FileOperations.exists(pasted)
              && !FileOperations.exists(
                folder.appendingPathComponent(pasteSource.lastPathComponent))
              && !FileOperations.exists(
                child.appendingPathComponent(pasteSource.lastPathComponent)),
            "分栏粘贴写入根目录/上级目录，或未写入当前深层目录")
          let sourceData = try Data(contentsOf: pasteSource)
          let targetData = try Data(contentsOf: pasted)
          try require(
            sourceData == targetData && app.tasks.records.first?.status == .completed,
            "深层粘贴内容不一致或复制任务失败")
          try require(paths([pane.operationDirectoryURL]) == paths([leaf]), "粘贴刷新改变了操作目录")
          let originalTab = pane.state.current.id
          pane.addTab()
          try require(paths([pane.currentURL]) == paths([leaf]), "新标签未从当前展开目录打开")
          pane.closeTab()
          try require(pane.state.current.id == originalTab, "关闭新标签没有返回原标签")
        }
      ))
    steps.append(
      (
        "reliability-quicklook-follows-selection",
        { [self] in
          let pane = w.activePane!
          pane.setMode(.list)
          try require(
            paths([pane.operationDirectoryURL]) == paths([folder])
              && pane.selectedURLs.isEmpty, "切回列表仍使用隐藏分栏的目录或选择")
          let firstIndex = pane.items.firstIndex { $0.name == "根文件甲.txt" }!
          pane.table.selectRowIndexes(IndexSet(integer: firstIndex), byExtendingSelection: false)
          pane.quickLook()
          try require(QLPreviewPanel.shared().isVisible, "快速预览未打开")
          let nextIndex = pane.items.firstIndex { $0.name == "根文件乙.txt" }!
          pane.table.selectRowIndexes(IndexSet(integer: nextIndex), byExtendingSelection: false)
          try require(
            pane.quickLookURLs == pane.selectedURLs
              && pane.quickLookURLs.first?.lastPathComponent == "根文件乙.txt"
              && QLPreviewPanel.shared().dataSource === pane, "更换选择后预览仍指向旧项目")
          pane.refresh()
        }
      ))
    steps.append(
      (
        "reliability-quicklook-refresh-and-empty-selection",
        { [self] in
          let pane = w.activePane!
          let panel = QLPreviewPanel.shared()!
          try require(
            panel.isVisible && pane.quickLookURLs == pane.selectedURLs
              && pane.quickLookURLs.first?.lastPathComponent == "根文件乙.txt",
            "同目录刷新时预览被临时空选择关闭或重置")
          pane.table.deselectAll(nil)
          try require(pane.table.selectedRowIndexes.isEmpty, "表格未清空选中行")
          try require(pane.selectedURLs.isEmpty, "取消表格选择后操作选择未同步")
          try require(pane.quickLookURLs.isEmpty, "取消选择后快速预览的数据源未清空")
        }
      ))
    steps.append(
      (
        "reliability-quicklook-closes-after-deselect",
        { [self] in
          try require(!QLPreviewPanel.shared().isVisible, "清空选择后快速预览窗口未关闭")
          try focusTestWindow(w.window!)
        }
      ))
  }
}
