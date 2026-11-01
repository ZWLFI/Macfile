import AppKit
import MacfileCore

extension UITestRunner {
  func addFileInteractionTests(_ w: WorkspaceController) {
    steps.append(("icon-filenames-appearance-and-double-click", { [self] in
      let folder = root.appendingPathComponent("多目录文件管理器交互设计与验收记录")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let pane = PaneController(owner: w, state: PaneState(path: root.path))
      pane.stop()
      pane.setMode(.icons)
      pane.items = [try FileItem(url: folder)]
      pane.selection = [folder]
      pane.reloadViews()
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = pane.view
      defer {
        pane.stop()
        window.close()
      }
      window.appearance = NSAppearance(named: .aqua)
      try focusTestWindow(window)
      pane.view.layoutSubtreeIfNeeded()
      pane.collection.layoutSubtreeIfNeeded()
      guard let tile = pane.collection.item(at: IndexPath(item: 0, section: 0)) as? FileTile else {
        try require(false, "图标测试未创建文件项目")
        return
      }
      tile.view.layoutSubtreeIfNeeded()
      // Count rendered text rows so a single truncated line cannot pass as a two-line label.
      tile.name.drawsBackground = true
      tile.name.backgroundColor = .white
      tile.name.textColor = .black
      guard let bitmap = tile.name.bitmapImageRepForCachingDisplay(in: tile.name.bounds) else {
        try require(false, "无法采集文件名渲染")
        return
      }
      tile.name.cacheDisplay(in: tile.name.bounds, to: bitmap)
      var bands = 0
      var firstInkRow: Int?
      var lastInkRow = 0
      var previousRowHasInk = false
      for y in 0..<bitmap.pixelsHigh {
        let hasInk = (0..<bitmap.pixelsWide).filter { x in
          guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
          return c.alphaComponent > 0.5 && c.redComponent < 0.6 && c.greenComponent < 0.6
        }.count > 2
        if hasInk {
          if firstInkRow == nil { firstInkRow = y }
          lastInkRow = y
        }
        if hasInk && !previousRowHasInk { bands += 1 }
        previousRowHasInk = hasInk
      }
      let inkHeight = CGFloat(lastInkRow - (firstInkRow ?? lastInkRow))
        * tile.name.bounds.height / CGFloat(bitmap.pixelsHigh)
      try require(bands >= 2 && inkHeight > 20, "长文件名仍只显示一行")
      tile.name.drawsBackground = false
      tile.name.textColor = .controlAccentColor
      capture("ui-file-tiles-light", window: window)
      window.appearance = NSAppearance(named: .darkAqua)
      capture("ui-file-tiles-dark", window: window)
      let original = pane.currentURL
      pane.collection.openDoubleClickedItem(at: NSPoint(x: -20, y: -20))
      try require(pane.currentURL == original, "双击空白打开了残留选择")
      guard let attributes = pane.collection.collectionViewLayout?.layoutAttributesForItem(
        at: IndexPath(item: 0, section: 0)) else {
        try require(false, "图标测试未生成项目位置")
        return
      }
      pane.collection.openDoubleClickedItem(
        at: NSPoint(x: attributes.frame.midX, y: attributes.frame.midY))
      try require(pane.currentURL.standardizedFileURL.path == folder.standardizedFileURL.path,
        "双击文件夹未打开命中的项目")
    }))
  }
}
