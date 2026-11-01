import AppKit
import MacfileCore

extension WorkspaceController: NSToolbarDelegate, NSSearchFieldDelegate {
  func buildToolbar() {
    let toolbar = NSToolbar(identifier: "Macfile.browser")
    toolbar.delegate = self
    toolbar.displayMode = .iconOnly
    toolbar.allowsUserCustomization = false
    toolbar.autosavesConfiguration = false
    window?.toolbar = toolbar
    updateTaskIndicator()
  }
  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [
      "sidebar", "addPane", "layouts", NSToolbarItem.Identifier.flexibleSpace.rawValue,
      "views", "actions", NSToolbarItem.Identifier.space.rawValue, "search", "tasks",
    ]
    .map { NSToolbarItem.Identifier($0) }
  }
  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    toolbarDefaultItemIdentifiers(toolbar)
  }
  func makeMenu(_ entries: [(String, String)]) -> NSMenu {
    let menu = NSMenu()
    for (title, command) in entries {
      if title == "-" {
        menu.addItem(.separator())
        continue
      }
      let item = NSMenuItem(
        title: title, action: #selector(toolbarMenuAction(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = command
      menu.addItem(item)
    }
    return menu
  }
  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    let key = identifier.rawValue
    if key == "search" {
      let field = NSSearchField()
      field.placeholderString = "搜索当前分栏"
      field.setAccessibilityLabel("搜索当前分栏")
      field.delegate = self
      field.sendsSearchStringImmediately = true
      field.searchMenuTemplate = makeMenu([
        ("包含子目录", "recursive"), ("保存当前搜索…", "saveSearch"), ("打开保存的搜索…", "searches"),
      ])
      searchToolbar.searchField = field
      searchToolbar.preferredWidthForSearchField = 220
      searchToolbar.label = "搜索"
      searchToolbar.toolTip = "搜索当前分栏 ⌘F；放大镜菜单可包含子目录"
      searchToolbar.visibilityPriority = .high
      return searchToolbar
    }
    if key == "addPane" {
      let item = NSToolbarItem(itemIdentifier: identifier)
      let button = ActionButton("添加分栏", symbol: "plus", help: "添加目录分栏 ⌥⌘N") { [weak self] in
        self?.command("addPane")
      }
      button.bezelStyle = .texturedRounded
      button.font = .systemFont(ofSize: 13, weight: .medium)
      button.heightAnchor.constraint(equalToConstant: 28).isActive = true
      button.widthAnchor.constraint(equalToConstant: 100).isActive = true
      item.view = button
      item.label = "添加分栏"
      item.visibilityPriority = .high
      let overflow = NSMenuItem(
        title: "添加分栏", action: #selector(toolbarMenuAction(_:)), keyEquivalent: "")
      overflow.target = self
      overflow.representedObject = "addPane"
      item.menuFormRepresentation = overflow
      return item
    }
    if key == "views" {
      let item = NSToolbarItem(itemIdentifier: identifier)
      viewSegments.segmentCount = ViewMode.allCases.count
      viewSegments.trackingMode = .selectOne
      viewSegments.segmentStyle = .rounded
      viewSegments.controlSize = .regular
      let icons = [
        "list.bullet", "square.grid.2x2", "photo", "rectangle.split.3x1",
        "rectangle.bottomthird.inset.filled",
      ]
      for (index, mode) in ViewMode.allCases.enumerated() {
        viewSegments.setImage(symbol(icons[index]), forSegment: index)
        viewSegments.setToolTip(mode.title + " ⌘\(index + 1)", forSegment: index)
        viewSegments.setWidth(30, forSegment: index)
      }
      viewSegments.target = self
      viewSegments.action = #selector(toolbarViewChanged(_:))
      viewSegments.setAccessibilityLabel("当前分栏显示模式")
      item.view = viewSegments
      item.label = "显示模式"
      item.visibilityPriority = .high
      let overflow = NSMenuItem(title: "显示模式", action: nil, keyEquivalent: "")
      overflow.submenu = makeMenu(ViewMode.allCases.map { ($0.title, "view-" + $0.rawValue) })
      item.menuFormRepresentation = overflow
      return item
    }
    if key == "tasks" {
      let item = NSToolbarItem(itemIdentifier: identifier)
      let button = ActionButton("任务", symbol: "arrow.down.circle", help: "任务中心 ⌘J") { [weak self] in
        self?.command("tasks")
      }
      button.bezelStyle = .texturedRounded
      button.font = .systemFont(ofSize: 13)
      button.heightAnchor.constraint(equalToConstant: 28).isActive = true
      button.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
      item.view = button
      item.label = "任务"
      let overflow = NSMenuItem(
        title: "任务中心", action: #selector(toolbarMenuAction(_:)), keyEquivalent: "")
      overflow.target = self
      overflow.representedObject = "tasks"
      item.menuFormRepresentation = overflow
      return item
    }
    if key == "layouts" || key == "actions" {
      let item = NSMenuToolbarItem(itemIdentifier: identifier)
      item.label = key == "layouts" ? "分栏与布局" : "更多操作"
      item.toolTip = item.label
      item.image = symbol(key == "layouts" ? "rectangle.split.2x1" : "ellipsis.circle")
      item.isBordered = true
      item.menu =
        key == "layouts"
        ? makeMenu([
          ("左右分栏", "splitH"), ("上下分栏", "splitV"), ("自动平铺", "tile"), ("自由摆放", "free"),
          ("-", ""), ("布局库…", "layouts"), ("收藏当前布局…", "favoriteLayout"),
          ("撤销布局变化", "undoLayout"), ("放大／还原当前分栏", "focus"), ("锁定／解锁布局", "lock"),
          ("-", ""), ("保存工作区…", "saveWorkspace"), ("打开工作区…", "workspaces"), ("分栏总览…", "overview"),
        ])
        : makeMenu([
          ("新建文件夹…", "newFolder"), ("快速预览", "preview"), ("文件信息", "inspector"),
          ("重命名…", "rename"), ("批量重命名…", "batchRename"), ("-", ""),
          ("复制", "copy"), ("粘贴到当前分栏", "paste"), ("移动已复制文件到此处", "movePaste"),
          ("复制到…", "copyTo"), ("移动到…", "moveTo"), ("-", ""),
          ("加入收集篮", "basketAdd"), ("加入书签…", "bookmark"), ("复制路径", "copyPath"),
          ("在终端中打开", "terminal"), ("在 Finder 中显示", "finder"), ("显示／隐藏隐藏文件", "hidden"),
          ("-", ""), ("移入废纸篓", "trash"), ("撤销上次文件操作", "undoFiles"),
        ])
      return item
    }
    let definitions = [
      "sidebar": ("显示／隐藏侧栏", "sidebar.left")
    ]
    guard let (title, icon) = definitions[key] else { return nil }
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.label = title
    item.toolTip = title
    item.image = symbol(icon)
    item.isBordered = true
    item.visibilityPriority = key == "sidebar" ? .high : .low
    item.target = self
    item.action = #selector(toolbarAction(_:))
    toolbarCommands[identifier] = key
    return item
  }
  func updateTaskIndicator() {
    let count = app.tasks.records.filter { [.running, .queued, .paused].contains($0.status) }.count
    guard let item = window?.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == "tasks" }),
      let button = item.view as? NSButton
    else { return }
    let title = count == 0 ? "任务" : "任务 \(count)"
    button.title = title
    button.toolTip = count == 0 ? "任务中心 ⌘J" : "\(count) 个进行中或等待中的任务 · ⌘J"
    button.setAccessibilityLabel(button.toolTip)
    item.label = title
    item.menuFormRepresentation?.title = count == 0 ? "任务中心" : "任务中心（\(count)）"
    item.visibilityPriority = count == 0 ? .low : .high
  }
  @objc func toolbarAction(_ sender: NSToolbarItem) {
    command(toolbarCommands[sender.itemIdentifier] ?? "")
  }
  @objc func toolbarMenuAction(_ sender: NSMenuItem) {
    let action = sender.representedObject as? String ?? ""
    if action == "recursive", let pane = activePane {
      pane.setSearchScope(!pane.recursive)
    } else {
      command(action)
    }
  }
  @objc func toolbarViewChanged(_ sender: NSSegmentedControl) {
    guard ViewMode.allCases.indices.contains(sender.selectedSegment) else { return }
    activePane?.setMode(ViewMode.allCases[sender.selectedSegment])
  }
  func controlTextDidChange(_ notification: Notification) {
    guard notification.object as? NSSearchField === searchToolbar.searchField, let pane = activePane
    else { return }
    pane.searchField.stringValue = searchToolbar.searchField.stringValue
    pane.controlTextDidChange(
      Notification(name: NSControl.textDidChangeNotification, object: pane.searchField))
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    guard control === searchToolbar.searchField else { return false }
    return activePane?.handleSearchCommand(selector) ?? false
  }
  func syncToolbar() {
    guard let pane = activePane else { return }
    viewSegments.selectedSegment = ViewMode.allCases.firstIndex(of: pane.state.current.mode) ?? 0
    let field = searchToolbar.searchField
    if field.stringValue != pane.searchField.stringValue {
      field.stringValue = pane.searchField.stringValue
    }
    let directory = pane.currentURL.lastPathComponent
    field.placeholderString = "搜索「\(directory.isEmpty ? "/" : directory)」"
    field.searchMenuTemplate?.items.first?.state = pane.recursive ? .on : .off
    for case let item as NSMenuToolbarItem in window?.toolbar?.items ?? [] {
      for entry in item.menu.items {
        entry.isEnabled = validateMenuItem(entry)
      }
    }
    for (button, path) in sidebarItems {
      let selected = path == pane.currentURL.path
      (button as? SidebarLocationButton)?.locationSelected = selected
      button.contentTintColor =
        selected ? .controlAccentColor : .secondaryLabelColor
      button.state = selected ? .on : .off
    }
  }
}
