import AppKit
import MacfileCore

struct ManagerRow {
  var id: String
  var title: String
  var subtitle: String
  var icon: String = "folder"
}
final class ManagerController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate
{
  var rows: [ManagerRow]
  var filtered: [ManagerRow] = []
  let table = NSTableView()
  let search = NSSearchField()
  let primaryButton = ActionButton(action: {})
  let actionMenu = NSMenu()
  let actions = NSPopUpButton(frame: .zero, pullsDown: true)
  let emptyLabel = label("暂无项目", size: 13, color: .secondaryLabelColor)
  let countLabel = label("", size: 11, color: .secondaryLabelColor)
  let selectsFirstResult: Bool
  let actionsWithoutSelection: Set<String>
  let singleSelectionActions: Set<String>
  var chosen: (([String]) -> Void)?
  var change: (([String], String) -> Void)?
  var selectedIDs: [String] {
    table.selectedRowIndexes.compactMap { $0 < filtered.count ? filtered[$0].id : nil }
  }
  init(
    title: String, subtitle: String, rows: [ManagerRow], primary: String = "打开",
    extras: [String] = [], selectsFirstResult: Bool = false,
    actionsWithoutSelection: Set<String> = [], singleSelectionActions: Set<String> = []
  ) {
    self.rows = rows
    self.selectsFirstResult = selectsFirstResult
    self.actionsWithoutSelection = actionsWithoutSelection
    self.singleSelectionActions = singleSelectionActions
    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 670, height: 510),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    win.title = title
    win.minSize = NSSize(width: 460, height: 340)
    win.isReleasedWhenClosed = false
    win.titlebarSeparatorStyle = .none
    super.init(window: win)
    let root = win.contentView!
    let sub = label(subtitle, size: 12, color: .secondaryLabelColor)
    sub.alignment = .left
    sub.maximumNumberOfLines = 2
    sub.lineBreakMode = .byWordWrapping
    search.placeholderString = "筛选…"
    search.font = .systemFont(ofSize: 13)
    search.delegate = self
    win.initialFirstResponder = search
    let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
    col.title = ""
    col.width = 600
    table.addTableColumn(col)
    table.headerView = nil
    table.rowHeight = 50
    table.style = .inset
    table.backgroundColor = .clear
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.delegate = self
    table.dataSource = self
    table.allowsMultipleSelection = !selectsFirstResult
    table.target = self
    table.doubleAction = #selector(openSelected)
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.borderType = .noBorder
    scroll.drawsBackground = false
    let list = NSView()
    list.addSubview(scroll)
    pin(scroll, to: list)
    list.addSubview(emptyLabel)
    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      emptyLabel.centerXAnchor.constraint(equalTo: list.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: list.centerYAnchor),
    ])
    actionMenu.autoenablesItems = false
    actionMenu.addItem(withTitle: "操作", action: nil, keyEquivalent: "")
    for title in extras {
      let item = actionMenu.addItem(
        withTitle: title, action: #selector(performAction(_:)), keyEquivalent: "")
      item.target = self
    }
    actions.menu = actionMenu
    actions.isHidden = extras.isEmpty
    primaryButton.title = primary
    primaryButton.setAccessibilityLabel(primary)
    primaryButton.actionBlock = { [weak self] in self?.openSelected() }
    primaryButton.keyEquivalent = "\r"
    let footer = row([actions, countLabel, flexible(), primaryButton])
    let stack = NSStackView(views: [row([sub, flexible()], spacing: 0), search, list, footer])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 12
    root.addSubview(stack)
    pin(stack, to: root, inset: 18)
    filter()
  }
  required init?(coder: NSCoder) { fatalError() }
  func filter() {
    let selection = Set(selectedIDs)
    filtered = rows.filter {
      search.stringValue.isEmpty
        || ($0.title + " " + $0.subtitle).localizedCaseInsensitiveContains(search.stringValue)
    }
    table.reloadData()
    var indexes = IndexSet(filtered.indices.filter { selection.contains(filtered[$0].id) })
    if indexes.isEmpty, selectsFirstResult, !filtered.isEmpty { indexes.insert(0) }
    table.selectRowIndexes(indexes, byExtendingSelection: false)
    emptyLabel.stringValue = rows.isEmpty ? "暂无项目" : "没有匹配的项目"
    emptyLabel.isHidden = !filtered.isEmpty
    updateActions()
  }
  func controlTextDidChange(_ obj: Notification) { filter() }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if selector == #selector(NSResponder.insertNewline(_:)) {
      openSelected()
      return true
    }
    if selector == #selector(NSResponder.moveDown(_:))
      || selector == #selector(NSResponder.moveUp(_:))
    {
      guard !filtered.isEmpty else { return true }
      let step = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
      let index =
        table.selectedRow < 0 ? 0 : min(filtered.count - 1, max(0, table.selectedRow + step))
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
      table.scrollRowToVisible(index)
      return true
    }
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      if search.stringValue.isEmpty {
        close()
      } else {
        search.stringValue = ""
        filter()
      }
      return true
    }
    return false
  }
  func tableViewSelectionDidChange(_ notification: Notification) { updateActions() }
  func canPerform(_ action: String) -> Bool {
    if singleSelectionActions.contains(action) { return selectedIDs.count == 1 }
    return !selectedIDs.isEmpty || (actionsWithoutSelection.contains(action) && !rows.isEmpty)
  }
  func updateActions() {
    let selected = !selectedIDs.isEmpty
    primaryButton.isEnabled = canPerform(primaryButton.title)
    for item in actionMenu.items.dropFirst() {
      item.isEnabled = canPerform(item.title)
    }
    actions.isEnabled = actionMenu.items.dropFirst().contains { $0.isEnabled }
    countLabel.stringValue =
      "\(filtered.count) 项" + (selected ? " · 已选 \(selectedIDs.count) 项" : "")
  }
  func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row index: Int)
    -> NSView?
  {
    let item = filtered[index]
    let icon = NSImageView(image: symbol(item.icon) ?? NSImage())
    icon.contentTintColor = .mfAccent
    icon.widthAnchor.constraint(equalToConstant: 22).isActive = true
    let text = column(
      [
        label(item.title, size: 13, weight: .medium),
        label(item.subtitle, size: 11, color: .secondaryLabelColor),
      ], spacing: 3)
    text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let r = row([icon, text], spacing: 10)
    r.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 6)
    return r
  }
  @objc func openSelected() {
    guard canPerform(primaryButton.title) else { return }
    chosen?(selectedIDs)
  }
  @objc func performAction(_ item: NSMenuItem) {
    guard canPerform(item.title) else { return }
    change?(selectedIDs, item.title)
  }
}
final class LayoutCard: NSButton {
  let preset: LayoutPreset
  var selectedAction: ((LayoutPreset) -> Void)?
  init(_ preset: LayoutPreset) {
    self.preset = preset
    super.init(frame: .zero)
    isBordered = false
    target = self
    action = #selector(pick)
    toolTip = preset.name
    setAccessibilityLabel(preset.name)
  }
  required init?(coder: NSCoder) { fatalError() }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.controlBackgroundColor.setFill()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9).fill()
    NSColor.separatorColor.withAlphaComponent(0.65).setStroke()
    NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 9, yRadius: 9).stroke()
    let area = NSRect(x: 14, y: 35, width: bounds.width - 28, height: bounds.height - 49)
    for (i, r) in preset.rects.enumerated() {
      (i == 0
        ? NSColor.mfAccent.withAlphaComponent(0.85) : NSColor.mfAccent.withAlphaComponent(0.18))
        .setFill()
      NSBezierPath(
        roundedRect: NSRect(
          x: area.minX + CGFloat(r.x) * area.width + 2,
          y: area.maxY - CGFloat(r.y + r.height) * area.height + 2,
          width: CGFloat(r.width) * area.width - 4, height: CGFloat(r.height) * area.height - 4),
        xRadius: 3, yRadius: 3
      ).fill()
    }
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.labelColor,
    ]
    (preset.name as NSString).draw(
      in: NSRect(x: 12, y: 8, width: bounds.width - 24, height: 20), withAttributes: attrs)
  }
  @objc func pick() { selectedAction?(preset) }
}
final class LayoutsController: NSWindowController {
  weak var workspaceOwner: WorkspaceController?
  let grid = FlippedView()
  let scroll = NSScrollView()
  let count = NSPopUpButton()
  var presets: [LayoutPreset] = []
  init(workspaceOwner: WorkspaceController) {
    self.workspaceOwner = workspaceOwner
    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 780, height: 650),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    win.title = "布局库"
    win.minSize = NSSize(width: 780, height: 500)
    win.isReleasedWhenClosed = false
    super.init(window: win)
    count.addItem(withTitle: "全部窗口数量")
    count.addItems(withTitles: (2...12).map { "\($0) 个目录窗口" })
    count.target = self
    count.action = #selector(filter)
    let sub = label(
      "\(LayoutPreset.all.count) 种布局 · 应用后仍可拖动分隔线调整", size: 12, color: .secondaryLabelColor)
    let options = row([
      count, flexible(),
      ActionButton("收藏的布局", symbol: "star") { [weak self] in self?.showFavorites() },
    ])
    scroll.documentView = grid
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let bottom = label("窗口较少时自动补齐；窗口较多时会分组套用布局，保留全部目录。", size: 11, color: .secondaryLabelColor)
    let stack = NSStackView(views: [
      row([sub, flexible()]), options, scroll, row([bottom, flexible()]),
    ])
    stack.orientation = .vertical
    stack.spacing = 12
    stack.alignment = .width
    win.contentView!.addSubview(stack)
    pin(stack, to: win.contentView!, inset: 22)
    filter()
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc func filter() {
    let n = count.indexOfSelectedItem == 0 ? nil : count.indexOfSelectedItem + 1
    presets = LayoutPreset.all.filter { n == nil || $0.count == n }
    grid.subviews.forEach { $0.removeFromSuperview() }
    let cols = 3
    let width: CGFloat = 236
    let height: CGFloat = 148
    grid.frame = NSRect(
      x: 0, y: 0, width: 730, height: CGFloat((presets.count + cols - 1) / cols) * (height + 10))
    for (i, p) in presets.enumerated() {
      let b = LayoutCard(p)
      b.frame = NSRect(
        x: CGFloat(i % cols) * (width + 8), y: CGFloat(i / cols) * (height + 10), width: width,
        height: height)
      b.selectedAction = { [weak self] preset in
        self?.workspaceOwner?.applyPreset(preset)
        self?.close()
      }
      grid.addSubview(b)
    }
  }
  func showFavorites() {
    guard let workspaceOwner else { return }
    let d = ManagerController(
      title: "收藏的布局", subtitle: "仅调整布局，当前目录与标签保持打开。",
      rows: workspaceOwner.app.state.favorites.map {
        ManagerRow(
          id: $0.id.uuidString, title: $0.name, subtitle: "\($0.workspace.panes.count) 个目录窗口",
          icon: "star")
      }, extras: ["删除收藏"], singleSelectionActions: ["打开"])
    d.chosen = { [weak workspaceOwner, weak d] ids in
      guard let workspaceOwner, let id = ids.first,
        let favorite = workspaceOwner.app.state.favorites.first(where: { $0.id.uuidString == id })
      else { return }
      workspaceOwner.applyFavorite(favorite)
      d?.close()
    }
    d.change = { [weak workspaceOwner, weak d] ids, _ in
      workspaceOwner?.app.state.favorites.removeAll { ids.contains($0.id.uuidString) }
      workspaceOwner?.app.save()
      d?.rows.removeAll { ids.contains($0.id) }
      d?.filter()
    }
    workspaceOwner.presentUtility(d)
  }
}
final class RenameController: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource {
  weak var workspaceOwner: WorkspaceController?
  let urls: [URL]
  let find = NSTextField(), replacement = NSTextField(), prefix = NSTextField(),
    suffix = NSTextField()
  let number = NSButton(checkboxWithTitle: "添加序号", target: nil, action: nil)
  let regex = NSButton(checkboxWithTitle: "正则表达式", target: nil, action: nil)
  let ext = NSButton(checkboxWithTitle: "包含扩展名", target: nil, action: nil)
  let start = NSTextField(string: "1"), digits = NSTextField(string: "3")
  let rulePicker = NSPopUpButton()
  let table = NSTableView()
  let errorText = label("", size: 11, color: .systemRed)
  let apply = ActionButton("执行重命名", action: {})
  var names: [String] = []
  var rule: RenameRule {
    var r = RenameRule()
    r.find = find.stringValue
    r.replacement = replacement.stringValue
    r.prefix = prefix.stringValue
    r.suffix = suffix.stringValue
    r.regex = regex.state == .on
    r.number = number.state == .on
    r.start = start.integerValue
    r.digits = digits.integerValue
    r.includeExtension = ext.state == .on
    return r
  }
  init(workspaceOwner: WorkspaceController, urls: [URL]) {
    self.workspaceOwner = workspaceOwner
    self.urls = urls
    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    win.title = "批量重命名"
    win.minSize = NSSize(width: 700, height: 540)
    win.isReleasedWhenClosed = false
    win.titlebarSeparatorStyle = .none
    super.init(window: win)
    for field in [find, replacement, prefix, suffix, start, digits] {
      field.delegate = self
      field.font = .systemFont(ofSize: 13)
    }
    find.placeholderString = "查找内容"
    replacement.placeholderString = "替换为"
    prefix.placeholderString = "前缀"
    suffix.placeholderString = "后缀"
    for button in [number, regex, ext] {
      button.target = self
      button.action = #selector(updatePreview)
    }
    start.widthAnchor.constraint(equalToConstant: 60).isActive = true
    digits.widthAnchor.constraint(equalToConstant: 45).isActive = true
    let grid = NSGridView(views: [
      [label("查找"), find, label("替换"), replacement], [label("前缀"), prefix, label("后缀"), suffix],
    ])
    grid.columnSpacing = 12
    grid.rowSpacing = 10
    find.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    replacement.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    let opts = row([regex, ext, number, label("从"), start, label("位数"), digits], spacing: 10)
    rulePicker.addItem(withTitle: "已保存的规则…")
    rulePicker.addItems(withTitles: workspaceOwner.app.state.renameRules.map(\.name))
    rulePicker.target = self
    rulePicker.action = #selector(loadRule)
    let ruleBar = row([
      rulePicker, ActionButton("保存规则…") { [weak self] in self?.saveRule() }, flexible(),
    ])
    for (key, title) in [("before", "原名称"), ("after", "新名称")] {
      let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
      c.title = title
      c.width = 340
      table.addTableColumn(c)
    }
    table.dataSource = self
    table.rowHeight = 30
    table.style = .inset
    table.usesAlternatingRowBackgroundColors = true
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = table
    scroll.borderType = .noBorder
    scroll.autohidesScrollers = true
    apply.actionBlock = { [weak self] in self?.execute() }
    apply.keyEquivalent = "\r"
    let footer = row([
      errorText, flexible(), ActionButton("取消") { [weak self] in self?.close() }, apply,
    ])
    let stack = NSStackView(views: [
      row([label("先预览，后执行 · \(urls.count) 个项目", size: 12, color: .secondaryLabelColor), flexible()]
      ), ruleBar, grid,
      opts, scroll, footer,
    ])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 12
    win.contentView!.addSubview(stack)
    pin(stack, to: win.contentView!, inset: 18)
    updatePreview()
  }
  required init?(coder: NSCoder) { fatalError() }
  func controlTextDidChange(_ obj: Notification) { updatePreview() }
  @objc func updatePreview() {
    start.isEnabled = number.state == .on
    digits.isEnabled = number.state == .on
    do {
      names = try urls.enumerated().map { try rule.result(for: $0.element, index: $0.offset) }
      var targets = Set<String>()
      let sources = Set(urls.map(\.path))
      for (url, name) in zip(urls, names) {
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        guard
          targets.insert(target.path.precomposedStringWithCanonicalMapping.lowercased()).inserted
        else { throw FileOperationError.conflict(name) }
        if FileOperations.exists(target), !sources.contains(target.path),
          (try? FileIdentity(url)) != (try? FileIdentity(target))
        {
          throw FileOperationError.conflict(name)
        }
      }
      errorText.stringValue = ""
      errorText.toolTip = nil
      apply.isEnabled = zip(urls, names).contains { $0.0.lastPathComponent != $0.1 }
    } catch {
      names = []
      errorText.stringValue = error.localizedDescription
      errorText.toolTip = error.localizedDescription
      apply.isEnabled = false
    }
    table.reloadData()
  }
  func numberOfRows(in tableView: NSTableView) -> Int { urls.count }
  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int)
    -> Any?
  {
    tableColumn?.identifier.rawValue == "before"
      ? urls[row].lastPathComponent : (names.indices.contains(row) ? names[row] : "—")
  }
  func execute() {
    updatePreview()
    guard apply.isEnabled else { return }
    let pairs = Array(zip(urls, names))
    workspaceOwner?.app.tasks.perform(title: "批量重命名 · \(urls.count) 项", total: urls.count) {
      engine, done in try engine.renameBatch(pairs, didComplete: done)
    }
    close()
  }
  func saveRule() {
    askText("保存重命名规则", value: "我的规则", window: window) { [weak self] name in
      guard let self, let name, !name.isEmpty else { return }
      var rule = self.rule
      rule.name = name
      self.workspaceOwner?.app.state.renameRules.append(rule)
      self.workspaceOwner?.app.save()
      self.rulePicker.addItem(withTitle: name)
    }
  }
  @objc func loadRule() {
    guard rulePicker.indexOfSelectedItem > 0,
      let r = workspaceOwner?.app.state.renameRules[rulePicker.indexOfSelectedItem - 1]
    else { return }
    find.stringValue = r.find
    replacement.stringValue = r.replacement
    prefix.stringValue = r.prefix
    suffix.stringValue = r.suffix
    regex.state = r.regex ? .on : .off
    number.state = r.number ? .on : .off
    ext.state = r.includeExtension ? .on : .off
    start.integerValue = r.start
    digits.integerValue = r.digits
    updatePreview()
  }
}
final class TasksController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
  weak var workspaceOwner: WorkspaceController?
  let table = NSTableView()
  let detail = NSTextView()
  let pauseButton = ActionButton("暂停", action: {})
  let cancelButton = ActionButton("取消任务", action: {})
  let undoButton = ActionButton("撤销已完成项", action: {})
  var selectedTaskID: UUID?
  var selected: TaskRecord? {
    guard let records = workspaceOwner?.app.tasks.records, table.selectedRow >= 0,
      table.selectedRow < records.count
    else { return nil }
    return records[table.selectedRow]
  }
  init(workspaceOwner: WorkspaceController) {
    self.workspaceOwner = workspaceOwner
    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 780, height: 620),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    win.title = "任务中心"
    win.minSize = NSSize(width: 650, height: 450)
    win.isReleasedWhenClosed = false
    win.titlebarSeparatorStyle = .none
    super.init(window: win)
    let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("task"))
    col.width = 720
    table.addTableColumn(col)
    table.headerView = nil
    table.rowHeight = 62
    table.style = .inset
    table.backgroundColor = .clear
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.delegate = self
    table.dataSource = self
    let scroll = NSScrollView()
    scroll.documentView = table
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = false
    detail.isEditable = false
    detail.frame.size = NSSize(width: 720, height: 160)
    detail.autoresizingMask = [.width]
    detail.isVerticallyResizable = true
    detail.isHorizontallyResizable = false
    detail.textContainer?.widthTracksTextView = true
    detail.textContainer?.containerSize = NSSize(width: 720, height: CGFloat.greatestFiniteMagnitude)
    detail.font = .systemFont(ofSize: 12)
    detail.textColor = .secondaryLabelColor
    detail.drawsBackground = false
    detail.textContainerInset = NSSize(width: 6, height: 8)
    let details = NSScrollView()
    details.documentView = detail
    details.hasVerticalScroller = true
    details.autohidesScrollers = true
    details.drawsBackground = false
    details.heightAnchor.constraint(equalToConstant: 160).isActive = true
    pauseButton.actionBlock = { [weak self] in
      guard let self, let id = self.selected?.id else { return }
      self.workspaceOwner?.app.tasks.pause(id)
    }
    cancelButton.actionBlock = { [weak self] in
      guard let self, let id = self.selected?.id else { return }
      self.workspaceOwner?.app.tasks.cancel(id)
    }
    undoButton.actionBlock = { [weak self] in
      guard let self, let id = self.selected?.id else { return }
      self.workspaceOwner?.app.tasks.undo(id)
    }
    let recovery = ActionButton("中断恢复…") { [weak self] in self?.workspaceOwner?.showRecovery() }
    let divider = NSBox()
    divider.boxType = .separator
    let stack = NSStackView(views: [
      row([
        label("操作完成后可撤销；文件发生外部变化时，会停止撤销以保护数据。", size: 12, color: .secondaryLabelColor), flexible(),
      ]), scroll,
      divider, row([label("任务详情", size: 12, weight: .medium), flexible()]), details,
      row([pauseButton, cancelButton, undoButton, flexible(), recovery]),
    ])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 12
    win.contentView!.addSubview(stack)
    pin(stack, to: win.contentView!, inset: 18)
    reload()
  }
  required init?(coder: NSCoder) { fatalError() }
  func reload() {
    let selectedID = selectedTaskID
    table.reloadData()
    if let selectedID,
      let index = workspaceOwner?.app.tasks.records.firstIndex(where: { $0.id == selectedID })
    {
      table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    } else if table.numberOfRows > 0 {
      table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    } else {
      table.deselectAll(nil)
    }
    showDetail()
  }
  func numberOfRows(in tableView: NSTableView) -> Int {
    workspaceOwner?.app.tasks.records.count ?? 0
  }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard let record = workspaceOwner?.app.tasks.records[row] else { return nil }
    let title = label(record.title, size: 13, weight: .medium)
    let text = label(
      statusName(record.status) + " · " + record.current, size: 11,
      color: [.failed, .partial].contains(record.status) ? .systemOrange : .secondaryLabelColor)
    let progress = NSProgressIndicator()
    progress.style = .bar
    progress.minValue = 0
    progress.maxValue = Double(max(1, record.total))
    progress.doubleValue = Double(record.completed + record.skipped)
    progress.isIndeterminate = record.total == 0
    progress.controlSize = .small
    let active = [.queued, .running, .paused].contains(record.status)
    let stack = NSStackView(views: active ? [title, text, progress] : [title, text])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 8)
    for field in [title, text] {
      field.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -14).isActive =
        true
    }
    if active {
      progress.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -14).isActive = true
    }
    return stack
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    selectedTaskID = selected?.id
    showDetail()
  }
  func statusName(_ status: TaskStatus) -> String {
    switch status {
    case .queued: return "排队"
    case .running: return "执行中"
    case .paused: return "已暂停"
    case .completed: return "已完成"
    case .partial: return "部分完成"
    case .failed: return "失败"
    case .cancelled: return "已取消"
    case .interrupted: return "上次运行中断"
    case .undone: return "已撤销"
    }
  }
  func showDetail() {
    let active = selected.map { [.queued, .running, .paused].contains($0.status) } ?? false
    pauseButton.isEnabled = active
    cancelButton.isEnabled = active
    pauseButton.title = selected?.status == .paused ? "继续" : "暂停"
    undoButton.isEnabled =
      selected?.receipts.contains(where: { !$0.undone }) == true
      && workspaceOwner?.app.tasks.hasActive == false
    guard let record = selected else {
      detail.string = "选择任务，查看文件位置、进度与操作明细。\n\n需要找回中断操作的文件时，请使用“中断恢复”。"
      return
    }
    detail.string =
      record.errors.joined(separator: "\n") + "\n"
      + record.receipts.map {
        "\($0.undone ? "已撤销" : "完成")：\($0.source)\n  → \($0.destination)"
          + ($0.backup.map { "\n  旧目标保留于：" + $0 } ?? "")
      }.joined(separator: "\n\n")
  }
}

extension WorkspaceController {
  func showRecovery() {
    let directory = app.support.appendingPathComponent("journal")
    let files =
      ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))
      ?? []).filter { $0.pathExtension == "pending" || $0.pathExtension == "rename-pending" }
    var records: [String: (source: URL, target: URL, copy: URL?, phase: String, journal: URL)] = [:]
    for file in files {
      guard let data = try? Data(contentsOf: file) else { continue }
      if let r = try? JSONDecoder().decode(PendingMutation.self, from: data) {
        let backup = [r.staging, r.backup].compactMap { $0 }.map { URL(fileURLWithPath: $0) }.first
        { FileOperations.exists($0) }
        records[file.path] = (
          URL(fileURLWithPath: r.source), URL(fileURLWithPath: r.target), backup, r.phase, file
        )
      } else if let rename = try? JSONDecoder().decode([[String]].self, from: data) {
        for (i, row) in rename.enumerated() where row.count == 3 {
          records[file.path + "/\(i)"] = (
            URL(fileURLWithPath: row[0]), URL(fileURLWithPath: row[2]),
            FileOperations.exists(URL(fileURLWithPath: row[1]))
              ? URL(fileURLWithPath: row[1]) : nil, "重命名过程中断", file
          )
        }
      }
    }
    let d = ManagerController(
      title: "中断恢复", subtitle: "恢复操作只复制内容，保留原件。先核对文件，再选择新的恢复位置。",
      rows: records.map {
        ManagerRow(
          id: $0.key, title: $0.value.source.lastPathComponent,
          subtitle: $0.value.phase + " · " + $0.value.target.path, icon: "arrow.counterclockwise")
      }, primary: "查看来源", extras: ["查看目标", "查看保留副本", "复制恢复到…"],
      singleSelectionActions: ["查看来源", "查看目标", "查看保留副本", "复制恢复到…"])
    d.chosen = { ids in
      guard let id = ids.first, let r = records[id] else { return }
      NSWorkspace.shared.activateFileViewerSelecting([r.source])
    }
    d.change = { [weak self, weak d] ids, action in
      guard let self, let id = ids.first, let r = records[id] else { return }
      if action == "查看目标" {
        NSWorkspace.shared.activateFileViewerSelecting([r.target])
        return
      }
      if action == "查看保留副本" {
        if let copy = r.copy {
          NSWorkspace.shared.activateFileViewerSelecting([copy])
        } else {
          showError(FileOperationError.unsupported("没有保留副本。请检查来源与目标位置。"), window: d?.window)
        }
        return
      }
      guard
        let source = r.copy
          ?? (FileOperations.exists(r.source)
            ? r.source : FileOperations.exists(r.target) ? r.target : nil)
      else {
        showError(CocoaError(.fileNoSuchFile), window: d?.window)
        return
      }
      let panel = NSOpenPanel()
      panel.canChooseDirectories = true
      panel.canChooseFiles = false
      panel.prompt = "恢复到这里"
      panel.beginSheetModal(for: d!.window!) { [weak self] response in
        guard let self, response == .OK, let dest = panel.url else { return }
        self.app.tasks.perform(title: "恢复副本：" + r.source.lastPathComponent, total: 1) {
          engine, done in
          if let receipt = try engine.transfer(
            source, to: dest.appendingPathComponent(r.source.lastPathComponent), kind: .copy,
            conflict: .keepBoth)
          {
            done(receipt)
          }
        }
      }
    }
    presentUtility(d)
  }
  func presentUtility(_ controller: NSWindowController) {
    utilityControllers.removeAll { $0.window?.isVisible == false }
    utilityControllers.append(controller)
    controller.window?.center()
    controller.showWindow(nil)
  }
  func showLayouts() { presentUtility(LayoutsController(workspaceOwner: self)) }
  func showRename() {
    guard let urls = activePane?.selectedURLs, !urls.isEmpty else {
      setStatus("先选择需要重命名的文件。")
      return
    }
    presentUtility(RenameController(workspaceOwner: self, urls: urls))
  }
  func showTasks() {
    if let tasksController {
      tasksController.showWindow(nil)
      tasksController.reload()
    } else {
      let d = TasksController(workspaceOwner: self)
      tasksController = d
      d.window?.center()
      d.showWindow(nil)
    }
  }
  func applyPreset(_ preset: LayoutPreset) {
    pushLayout()
    while workspace.panes.count < preset.count {
      workspace.panes.append(
        PaneState(
          path: activePane?.currentURL.path ?? FileManager.default.homeDirectoryForCurrentUser.path)
      )
    }
    let ids = workspace.panes.map(\.id)
    if ids.count == preset.count {
      workspace.tree = preset.tree(ids: ids)
    } else {
      var groups: [SplitNode] = []
      for start in stride(from: 0, to: ids.count, by: preset.count) {
        let part = Array(ids[start..<min(ids.count, start + preset.count)])
        let layout =
          part.count == preset.count
          ? preset
          : LayoutPreset(
            id: "", name: "", count: part.count,
            rects: LayoutPreset.grid(count: part.count, columns: min(part.count, 3)))
        if let tree = layout.tree(ids: part) { groups.append(tree) }
      }
      func join(_ groups: [SplitNode]) -> SplitNode {
        if groups.count == 1 { return groups[0] }
        return .split(
          horizontal: false, fraction: 1 / Double(groups.count), first: groups[0],
          second: join(Array(groups.dropFirst())))
      }
      workspace.tree = join(groups)
    }
    workspace.arrangement = .split
    focused = nil
    rebuild()
  }
  func applyFavorite(_ favorite: LayoutFavorite) {
    pushLayout()
    let old = favorite.workspace
    while workspace.panes.count < old.panes.count {
      workspace.panes.append(
        PaneState(
          path: activePane?.currentURL.path ?? FileManager.default.homeDirectoryForCurrentUser.path)
      )
    }
    workspace.arrangement = old.arrangement
    workspace.columns = old.columns
    var tree = old.tree?.remapping(
      Dictionary(uniqueKeysWithValues: zip(old.panes, workspace.panes).map { ($0.0.id, $0.1.id) }))
    var frames: [UUID: Rect] = [:]
    for (from, to) in zip(old.panes, workspace.panes) { frames[to.id] = old.frames[from.id] }
    if workspace.panes.count > old.panes.count, var t = tree {
      for pane in workspace.panes.dropFirst(old.panes.count) {
        t = .split(horizontal: false, fraction: 0.75, first: t, second: .leaf(pane.id))
      }
      tree = t
    }
    workspace.tree = tree
    workspace.frames = frames
    focused = nil
    rebuild()
  }
  func showOverview() {
    let d = ManagerController(
      title: "目录窗口总览", subtitle: "定位、放大或关闭目录窗口；所有标签保持原样。",
      rows: workspace.panes.map {
        ManagerRow(
          id: $0.id.uuidString, title: URL(fileURLWithPath: $0.current.path).lastPathComponent,
          subtitle: "\($0.tabs.count) 个标签 · \($0.current.path)")
      }, primary: "定位", extras: ["放大", "关闭目录窗口"], singleSelectionActions: ["定位", "放大"])
    d.chosen = { [weak self, weak d] ids in
      guard let self, let raw = ids.first, let id = UUID(uuidString: raw), let pane = self.panes[id]
      else { return }
      self.activate(id)
      self.canvas.scrollToVisible(pane.view.convert(pane.view.bounds, to: self.canvas))
      d?.close()
    }
    d.change = { [weak self, weak d] ids, action in
      guard let self else { return }
      if action == "放大", let raw = ids.first, let id = UUID(uuidString: raw) {
        self.toggleFocus(id)
        d?.close()
      } else {
        ids.compactMap(UUID.init(uuidString:)).forEach(self.closePane)
        d?.rows.removeAll { ids.contains($0.id) }
        d?.filter()
      }
    }
    presentUtility(d)
  }
  func showBookmarks() {
    let d = ManagerController(
      title: "书签", subtitle: "保存常用目录或单个文件；删除书签不删除原文件。",
      rows: app.state.bookmarks.map {
        ManagerRow(id: $0.id.uuidString, title: $0.name, subtitle: $0.path, icon: "bookmark")
      }, extras: ["重命名", "重新定位", "删除书签"],
      singleSelectionActions: ["打开", "重命名", "重新定位"])
    d.chosen = { [weak self, weak d] ids in
      guard let self,
        let b = self.app.state.bookmarks.first(where: { ids.contains($0.id.uuidString) })
      else { return }
      self.openPath(URL(fileURLWithPath: b.path))
      d?.close()
    }
    d.change = { [weak self, weak d] ids, action in
      guard let self else { return }
      if action == "删除书签" {
        self.app.state.bookmarks.removeAll { ids.contains($0.id.uuidString) }
        d?.rows.removeAll { ids.contains($0.id) }
        d?.filter()
        self.app.refreshShared()
      } else if let bookmark = self.app.state.bookmarks.first(where: {
        ids.contains($0.id.uuidString)
      }) {
        if action == "重命名" {
          askText("书签名称", value: bookmark.name, window: d?.window) {
            [weak self, weak d] name in
            guard let self, let name else { return }
            do {
              try self.updateBookmark(bookmark.id) { $0.name = name }
              d?.close()
              self.showBookmarks()
            } catch { showError(error, window: d?.window) }
          }
        } else {
          let panel = NSOpenPanel()
          panel.canChooseDirectories = true
          panel.canChooseFiles = true
          panel.beginSheetModal(for: d!.window!) { [weak self, weak d] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
              try self.updateBookmark(bookmark.id) { $0.path = url.path }
              d?.close()
              self.showBookmarks()
            } catch { showError(error, window: d?.window) }
          }
        }
      }
    }
    presentUtility(d)
  }
  func updateBookmark(_ id: UUID, change: (inout Bookmark) -> Void) throws {
    guard let index = app.state.bookmarks.firstIndex(where: { $0.id == id }) else {
      throw FileOperationError.unsupported("此书签已被移除，请重新打开书签列表。")
    }
    change(&app.state.bookmarks[index])
    app.refreshShared()
  }
  func showWorkspaces() {
    let d = ManagerController(
      title: "保存的工作区", subtitle: "恢复目录、标签、布局和显示模式。",
      rows: app.state.workspaces.map {
        ManagerRow(
          id: $0.id.uuidString, title: $0.name, subtitle: "\($0.panes.count) 个目录窗口",
          icon: "rectangle.3.group")
      }, extras: ["删除工作区"], singleSelectionActions: ["打开"])
    d.chosen = { [weak self, weak d] ids in
      guard let self,
        let w = self.app.state.workspaces.first(where: { ids.contains($0.id.uuidString) })
      else { return }
      self.loadWorkspace(w)
      d?.close()
    }
    d.change = { [weak self, weak d] ids, _ in
      self?.app.state.workspaces.removeAll { ids.contains($0.id.uuidString) }
      self?.app.refreshShared()
      d?.rows.removeAll { ids.contains($0.id) }
      d?.filter()
    }
    presentUtility(d)
  }
  func showSearches() {
    let d = ManagerController(
      title: "保存的搜索", subtitle: "在保存的目录范围内重新搜索，不保存过期结果。",
      rows: app.state.searches.map {
        ManagerRow(
          id: $0.id.uuidString, title: $0.name,
          subtitle: "\($0.query) · \($0.root)\($0.recursive ? "（含子目录）" : "")",
          icon: "magnifyingglass")
      }, extras: ["删除搜索"], singleSelectionActions: ["打开"])
    d.chosen = { [weak self, weak d] ids in
      guard let self,
        let s = self.app.state.searches.first(where: { ids.contains($0.id.uuidString) })
      else { return }
      self.activePane?.runSearch(s)
      d?.close()
    }
    d.change = { [weak self, weak d] ids, _ in
      self?.app.state.searches.removeAll { ids.contains($0.id.uuidString) }
      self?.app.save()
      d?.rows.removeAll { ids.contains($0.id) }
      d?.filter()
    }
    presentUtility(d)
  }
  func showBasket() {
    let d = ManagerController(
      title: "收集篮", subtitle: "这里保存文件引用。可从多个目录收集，再统一复制或移动到当前目录。",
      rows: app.state.basket.map {
        ManagerRow(
          id: $0, title: URL(fileURLWithPath: $0).lastPathComponent,
          subtitle: (FileOperations.exists(URL(fileURLWithPath: $0)) ? "" : "位置不可用 · ") + $0,
          icon: "doc")
      }, primary: "在 Finder 中显示", extras: ["复制到当前目录", "移动到当前目录", "移除引用", "清理失效引用"],
      actionsWithoutSelection: ["清理失效引用"])
    d.chosen = { ids in
      NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
    }
    d.change = { [weak self, weak d] ids, action in
      guard let self else { return }
      switch action {
      case "移除引用": self.app.state.basket.removeAll { ids.contains($0) }
      case "清理失效引用":
        self.app.state.basket.removeAll { !FileOperations.exists(URL(fileURLWithPath: $0)) }
      default:
        guard let destination = self.activePane?.currentURL, !ids.isEmpty else { return }
        d?.close()
        self.transfer(
          ids.map { URL(fileURLWithPath: $0) }, to: destination, move: action.hasPrefix("移动"))
        return
      }
      self.app.refreshShared()
      d?.rows.removeAll { !self.app.state.basket.contains($0.id) }
      d?.filter()
    }
    presentUtility(d)
  }
  func showCommands() {
    let commands = [
      ("addPane", "添加目录窗口", "⌥⌘N"), ("splitH", "左右分割", "⌘D"), ("splitV", "上下分割", "⇧⌘D"),
      ("layouts", "打开布局库", "⌥⌘L"), ("free", "自由摆放", ""), ("tile", "自动平铺", ""),
      ("overview", "窗口总览", "⌥⌘O"), ("batchRename", "批量重命名", "⇧⌘R"), ("basket", "收集篮", "⌥⌘B"),
      ("tasks", "任务中心", "⌘J"), ("saveWorkspace", "保存工作区", "⌘S"), ("saveSearch", "保存搜索", "⇧⌘F"),
      ("bookmark", "添加书签", "⌥⌘D"), ("terminal", "在终端中打开", ""), ("newFolder", "新建文件夹", "⇧⌘N"),
      ("inspector", "切换检查器", "⌥⌘I"),
    ]
    let d = ManagerController(
      title: "快捷操作", subtitle: "输入名称筛选操作，也可使用菜单栏中的快捷键。",
      rows: commands.map { ManagerRow(id: $0.0, title: $0.1, subtitle: $0.2, icon: "command") },
      primary: "执行", selectsFirstResult: true)
    d.chosen = { [weak self, weak d] ids in
      guard let cmd = ids.first else { return }
      d?.close()
      self?.command(cmd)
    }
    presentUtility(d)
  }
}
