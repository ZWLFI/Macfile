import AppKit
import MacfileCore

extension UITestRunner {
  func addDialogInteractionTests(_ w: WorkspaceController) {
    steps.append(("bookmark-dialog-single-and-multiple-selection", { [self] in
      let saved = app.state.bookmarks
      app.state.bookmarks = [
        Bookmark(name: "资料", path: root.appendingPathComponent("资料").path),
        Bookmark(name: "交付", path: root.appendingPathComponent("交付").path),
      ]
      w.showBookmarks()
      let manager = w.utilityControllers.last as! ManagerController
      defer {
        manager.close()
        app.state.bookmarks = saved
        app.refreshShared()
      }
      let rename = manager.actionMenu.items.first { $0.title == "重命名" }!
      let relocate = manager.actionMenu.items.first { $0.title == "重新定位" }!
      let remove = manager.actionMenu.items.first { $0.title == "删除书签" }!
      var opened = 0
      var changed: [(String, Int)] = []
      manager.chosen = { opened += $0.count }
      manager.change = { changed.append(($1, $0.count)) }
      manager.table.selectRowIndexes(IndexSet(integersIn: 0..<2), byExtendingSelection: false)
      try require(!manager.primaryButton.isEnabled && !rename.isEnabled && !relocate.isEnabled,
        "多选书签时单项操作仍可执行")
      try require(remove.isEnabled, "多选书签时批量删除被禁用")
      manager.openSelected()
      manager.performAction(rename)
      try require(opened == 0 && changed.isEmpty, "禁用的单项操作仍触发回调")
      manager.performAction(remove)
      try require(changed.count == 1 && changed[0].0 == "删除书签" && changed[0].1 == 2,
        "批量操作未包含全部选中书签")
      manager.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
      try require(manager.primaryButton.isEnabled && rename.isEnabled && relocate.isEnabled,
        "恢复单选后操作未启用")
      manager.openSelected()
      try require(opened == 1, "单选打开未执行")
    }))
    steps.append(("bookmark-edit-follows-stable-id", { [self] in
      let saved = app.state.bookmarks
      defer {
        app.state.bookmarks = saved
        app.refreshShared()
      }
      let first = Bookmark(name: "首项", path: "/first")
      let edited = Bookmark(name: "编辑对象", path: "/edited")
      let other = Bookmark(name: "其他书签", path: "/other")
      app.state.bookmarks = [first, edited, other]
      app.state.bookmarks.removeFirst()
      try w.updateBookmark(edited.id) { $0.name = "新名称" }
      try require(app.state.bookmarks.first(where: { $0.id == edited.id })?.name == "新名称"
        && app.state.bookmarks.first(where: { $0.id == other.id })?.name == other.name,
        "删除前面的书签后编辑了错误对象")
      app.state.bookmarks.reverse()
      try w.updateBookmark(edited.id) { $0.path = "/new-location" }
      try require(app.state.bookmarks.first(where: { $0.id == edited.id })?.path == "/new-location"
        && app.state.bookmarks.first(where: { $0.id == other.id })?.path == other.path,
        "重新排序后重新定位了错误书签")
      app.state.bookmarks.removeAll { $0.id == edited.id }
      var rejected = false
      do {
        try w.updateBookmark(edited.id) { $0.name = "不能写入" }
      } catch {
        rejected = error.localizedDescription.contains("已被移除")
      }
      try require(rejected && app.state.bookmarks == [other],
        "已被另一窗口删除的书签未被拒绝或影响了其他书签")
    }))
    steps.append(("rename-invalid-preview-clears-and-recovers", { [self] in
      let urls = ["资料/产品说明.md", "资料/需求清单.txt"].map { root.appendingPathComponent($0) }
      let rename = RenameController(workspaceOwner: w, urls: urls)
      w.presentUtility(rename)
      defer { rename.close() }
      rename.prefix.stringValue = "新-"
      rename.updatePreview()
      try require(rename.names.count == urls.count && rename.apply.isEnabled, "有效重命名未生成预览")
      rename.regex.state = .on
      rename.find.stringValue = "["
      rename.updatePreview()
      let after = rename.table.tableColumns.first { $0.identifier.rawValue == "after" }
      try require(rename.names.isEmpty && !rename.apply.isEnabled && !rename.errorText.stringValue.isEmpty,
        "非法正则后仍保留旧预览或可执行")
      try require(rename.tableView(rename.table, objectValueFor: after, row: 0) as? String == "—",
        "失效的新名称未显示占位符")
      rename.find.stringValue = ""
      rename.updatePreview()
      try require(rename.names == urls.map { "新-" + $0.lastPathComponent }
        && rename.apply.isEnabled && rename.errorText.stringValue.isEmpty && rename.errorText.toolTip == nil,
        "修复规则后预览或错误状态未恢复")
    }))
  }
}
