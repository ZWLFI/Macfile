import AppKit
import MacfileCore
import QuickLookUI

final class SidebarLocationButton: FileDropButton {
  var locationSelected = false { didSet { needsDisplay = true } }
  private var hoverTracking: NSTrackingArea?

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTracking { removeTrackingArea(hoverTracking) }
    let tracking = NSTrackingArea(
      rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self, userInfo: nil)
    addTrackingArea(tracking)
    hoverTracking = tracking
  }
  override func mouseEntered(with event: NSEvent) {
    needsDisplay = true
  }
  override func mouseExited(with event: NSEvent) {
    needsDisplay = true
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
  override func draw(_ dirtyRect: NSRect) {
    let hovered =
      window.map {
        $0.isKeyWindow && bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil))
      } ?? false
    if locationSelected || isHighlighted || hovered {
      let color =
        locationSelected || isHighlighted
        ? (window?.isKeyWindow == true
          ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16)
          : NSColor.unemphasizedSelectedContentBackgroundColor)
        : NSColor.labelColor.withAlphaComponent(0.05)
      color.setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
    cell?.draw(withFrame: bounds.insetBy(dx: 9, dy: 0), in: self)
  }
}

final class WorkspaceController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
  unowned let app: AppDelegate
  var workspace: Workspace
  var panes: [UUID: PaneController] = [:]
  var layoutHistory: [Workspace] = []
  var closedPanes: [PaneState] = []
  var focused: UUID?
  let canvas = FlippedView()
  let scroll = NSScrollView()
  let sidebar = FlippedStack()
  let status = label("", size: 11, color: .secondaryLabelColor)
  let statusBar = NSStackView()
  var statusHeight: NSLayoutConstraint?
  let sideBackground = NSVisualEffectView()
  let sidebarDivider = NSBox()
  var sidebarItems: [(FileDropButton, String)] = []
  var toolbarCommands: [NSToolbarItem.Identifier: String] = [:]
  let searchToolbar = NSSearchToolbarItem(itemIdentifier: NSToolbarItem.Identifier("search"))
  let viewSegments = NSSegmentedControl()
  var statusTimer: Timer?
  let inspector = NSStackView()
  var inspectorVisible = false
  var inspectorName = label("选择文件查看详情", size: 14, weight: .semibold)
  var inspectorDetail = label("", size: 12, color: .secondaryLabelColor)
  let preview = QLPreviewView(frame: NSRect(x: 0, y: 0, width: 220, height: 220), style: .normal)!
  var rootSplit: NSView?
  var splitHandlers: [SplitHandler] = []
  var utilityControllers: [NSWindowController] = []
  var tasksController: TasksController?
  private var saveTimer: Timer?
  private var freeHistorySaved = false
  private var focusMonitor: Any?
  var activePane: PaneController? { panes[workspace.active] }
  init(app: AppDelegate, workspace: Workspace) {
    self.app = app
    self.workspace = workspace
    self.workspace.normalize()
    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1320, height: 840),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    win.minSize = NSSize(width: 800, height: 520)
    win.title = "Macfile"
    win.titleVisibility = .hidden
    win.titlebarAppearsTransparent = true
    win.toolbarStyle = .unified
    win.titlebarSeparatorStyle = .line
    win.backgroundColor = .windowBackgroundColor
    win.tabbingMode = .disallowed
    win.isReleasedWhenClosed = false
    win.contentView = WindowContentView(frame: NSRect(x: 0, y: 0, width: 1320, height: 840))
    super.init(window: win)
    win.delegate = self
    win.center()
    buildChrome()
    buildToolbar()
    rebuild()
    reloadSidebar()
    focusMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
      [weak self] event in
      guard let self, event.window === self.window, let root = self.window?.contentView,
        let hit = root.hitTest(root.convert(event.locationInWindow, from: nil))
      else { return event }
      if let pane = self.panes.values.first(where: {
        hit === $0.view || hit.isDescendant(of: $0.view)
      }) {
        self.activate(pane.id)
        if hit is NSClipView || hit === pane.emptyLabel {
          pane.focusFiles()
        }
      }
      return event
    }
  }
  required init?(coder: NSCoder) { fatalError() }
  func buildChrome() {
    guard let root = window?.contentView else { return }
    let body = NSStackView()
    body.orientation = .horizontal
    body.spacing = 0
    body.alignment = .height
    sideBackground.material = .sidebar
    sideBackground.blendingMode = .behindWindow
    sideBackground.widthAnchor.constraint(equalToConstant: 196).isActive = true
    let sideScroll = NSScrollView()
    sideScroll.drawsBackground = false
    sideScroll.hasVerticalScroller = true
    sideScroll.autohidesScrollers = true
    sidebar.orientation = .vertical
    sidebar.alignment = .leading
    sidebar.spacing = 2
    sidebar.distribution = .fill
    sidebar.setContentHuggingPriority(.required, for: .vertical)
    sidebar.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 12, right: 10)
    sidebar.translatesAutoresizingMaskIntoConstraints = false
    sideScroll.documentView = sidebar
    sidebar.widthAnchor.constraint(equalTo: sideScroll.contentView.widthAnchor).isActive = true
    sideBackground.addSubview(sideScroll)
    pin(sideScroll, to: sideBackground)
    scroll.hasHorizontalScroller = true
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.drawsBackground = true
    scroll.backgroundColor = .separatorColor
    scroll.documentView = canvas
    body.addArrangedSubview(sideBackground)
    sidebarDivider.boxType = .separator
    sidebarDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
    body.addArrangedSubview(sidebarDivider)
    body.addArrangedSubview(scroll)
    for view in [sideBackground, sidebarDivider, scroll] {
      body.setVisibilityPriority(.mustHold, for: view)
    }
    inspector.orientation = .vertical
    inspector.alignment = .leading
    inspector.spacing = 14
    inspector.detachesHiddenViews = true
    inspector.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    inspector.widthAnchor.constraint(equalToConstant: 248).isActive = true
    let closeInspector = ActionButton("", symbol: "xmark", help: "关闭文件信息") { [weak self] in
      self?.toggleInspector()
    }
    closeInspector.isBordered = false
    closeInspector.controlSize = .small
    let inspectorHeading = row([
      label("文件信息", size: 12, weight: .semibold), flexible(), closeInspector,
    ])
    inspectorHeading.widthAnchor.constraint(equalToConstant: 216).isActive = true
    inspector.addArrangedSubview(inspectorHeading)
    inspector.addArrangedSubview(preview)
    preview.translatesAutoresizingMaskIntoConstraints = false
    preview.widthAnchor.constraint(equalToConstant: 216).isActive = true
    preview.heightAnchor.constraint(equalToConstant: 216).isActive = true
    preview.isHidden = true
    inspector.addArrangedSubview(inspectorName)
    inspector.addArrangedSubview(inspectorDetail)
    inspectorName.maximumNumberOfLines = 3
    inspectorName.widthAnchor.constraint(equalToConstant: 216).isActive = true
    inspectorDetail.maximumNumberOfLines = 0
    inspectorDetail.lineBreakMode = .byWordWrapping
    inspectorDetail.widthAnchor.constraint(equalToConstant: 216).isActive = true
    inspector.addArrangedSubview(
      ActionButton("在 Finder 中显示", symbol: "folder") { [weak self] in self?.command("finder") })
    inspector.addArrangedSubview(NSView())
    body.addArrangedSubview(inspector)
    inspector.isHidden = true
    statusBar.orientation = .horizontal
    statusBar.addArrangedSubview(status)
    statusBar.addArrangedSubview(flexible())
    statusBar.edgeInsets = NSEdgeInsets(top: 3, left: 12, bottom: 3, right: 12)
    statusBar.isHidden = true
    root.addSubview(body)
    root.addSubview(statusBar)
    body.translatesAutoresizingMaskIntoConstraints = false
    statusBar.translatesAutoresizingMaskIntoConstraints = false
    statusHeight = statusBar.heightAnchor.constraint(equalToConstant: 0)
    NSLayoutConstraint.activate([
      body.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      body.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      body.topAnchor.constraint(equalTo: root.topAnchor),
      body.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
      statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
      statusHeight!,
    ])
    scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
    body.setContentHuggingPriority(.defaultLow, for: .vertical)
  }
  func reloadSidebar() {
    for view in sidebar.arrangedSubviews {
      sidebar.removeArrangedSubview(view)
      view.removeFromSuperview()
    }
    sidebarItems.removeAll()
    func heading(_ name: String, add: (() -> Void)? = nil, manage: (() -> Void)? = nil) {
      let title = label(name, size: 11, weight: .semibold, color: .secondaryLabelColor)
      var controls: [NSView] = [title, flexible()]
      for (icon, help, action) in [("plus", "添加" + name, add), ("ellipsis", "管理" + name, manage)] {
        if let action {
          let button = FileDropButton("", symbol: icon, help: help, action: action)
          if name == "书签", icon == "plus" {
            button.toolTip = "添加书签；可拖入文件或目录"
            button.receiveReferences = { [weak self] urls in
              guard let self else { return }
              for url in urls
              where !self.app.state.bookmarks.contains(where: { $0.path == url.path }) {
                self.app.state.bookmarks.append(
                  Bookmark(name: url.lastPathComponent, path: url.path))
              }
              self.app.refreshShared()
            }
            button.registerForDraggedTypes(FileDrop.types)
          }
          button.isBordered = false
          button.controlSize = .mini
          button.widthAnchor.constraint(equalToConstant: 18).isActive = true
          controls.append(button)
        }
      }
      let section = row(controls, spacing: 2)
      section.edgeInsets = NSEdgeInsets(top: 10, left: 9, bottom: 3, right: 7)
      section.heightAnchor.constraint(equalToConstant: 34).isActive = true
      sidebar.addArrangedSubview(section)
      section.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -20).isActive = true
    }
    func button(
      _ name: String, _ icon: String, destination: URL? = nil,
      references: (([URL]) -> Void)? = nil, _ action: @escaping () -> Void
    ) {
      let button = SidebarLocationButton(name, symbol: icon, action: action)
      button.workspace = self
      button.destination = destination
      button.receiveReferences = references
      if destination != nil || references != nil { button.registerForDraggedTypes(FileDrop.types) }
      button.isBordered = false
      button.bezelStyle = .recessed
      button.alignment = .left
      button.font = .systemFont(ofSize: 13)
      button.contentTintColor = .secondaryLabelColor
      button.imageHugsTitle = true
      button.image?.isTemplate = true
      button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
      sidebar.addArrangedSubview(button)
      button.widthAnchor.constraint(equalTo: sidebar.widthAnchor, constant: -20).isActive = true
      button.heightAnchor.constraint(equalToConstant: 32).isActive = true
      button.lineBreakMode = .byTruncatingMiddle
      if let destination { sidebarItems.append((button, destination.path)) }
    }
    heading("位置")
    let home = FileManager.default.homeDirectoryForCurrentUser
    for (name, icon, path) in [
      ("个人目录", "house", home), ("桌面", "desktopcomputer", home.appendingPathComponent("Desktop")),
      ("下载", "arrow.down.circle", home.appendingPathComponent("Downloads")),
      ("文稿", "doc.text", home.appendingPathComponent("Documents")),
      ("图片", "photo", home.appendingPathComponent("Pictures")),
    ] { button(name, icon, destination: path) { [weak self] in self?.openPath(path) } }
    heading(
      "书签", add: { [weak self] in self?.addBookmark() },
      manage: { [weak self] in self?.showBookmarks() })
    for bookmark in app.state.bookmarks {
      button(
        bookmark.name, "bookmark",
        destination: (try? FileItem(url: URL(fileURLWithPath: bookmark.path)))?.isFolder == true
          ? URL(fileURLWithPath: bookmark.path) : nil
      ) { [weak self] in self?.openPath(URL(fileURLWithPath: bookmark.path)) }
    }
    if !app.state.workspaces.isEmpty {
      heading(
        "工作区", add: { [weak self] in self?.saveWorkspace() },
        manage: { [weak self] in self?.showWorkspaces() })
      for workspace in app.state.workspaces {
        button(workspace.name, "rectangle.3.group") { [weak self] in self?.loadWorkspace(workspace)
        }
      }
    }
    heading("整理")
    button(
      "收集篮" + (app.state.basket.isEmpty ? "" : "  \(app.state.basket.count)"), "tray",
      references: { [weak self] urls in
        guard let self else { return }
        for url in urls where !self.app.state.basket.contains(url.path) {
          self.app.state.basket.append(url.path)
        }
        self.app.refreshShared()
        self.setStatus("已加入收集篮")
      }
    ) { [weak self] in self?.showBasket() }
    button("保存的搜索", "magnifyingglass") { [weak self] in self?.showSearches() }
    let devices =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? []
    if !devices.isEmpty {
      heading("设备")
      for url in devices {
        let title =
          (try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName) ?? url.lastPathComponent
        button(title, "externaldrive", destination: url) { [weak self] in self?.openPath(url) }
      }
    }
    syncToolbar()
  }
  func scheduleSave() {
    saveTimer?.invalidate()
    saveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
      self?.app.save()
    }
  }
  func setStatus(_ text: String) {
    status.stringValue = text
    status.toolTip = text
    statusBar.isHidden = text.isEmpty
    statusHeight?.constant = text.isEmpty ? 0 : 24
    statusTimer?.invalidate()
    window?.contentView?.layoutSubtreeIfNeeded()
    layoutWorkbench()
    if !app.tasks.hasActive && !text.isEmpty {
      statusTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
        self?.statusBar.isHidden = true
        self?.statusHeight?.constant = 0
        self?.window?.contentView?.layoutSubtreeIfNeeded()
        self?.layoutWorkbench()
      }
    }
  }
  func activate(_ id: UUID) {
    guard workspace.panes.contains(where: { $0.id == id }) else { return }
    workspace.active = id
    for (i, pane) in panes { pane.surface.highlight(i == id) }
    if workspace.arrangement == .free, let view = panes[id]?.view {
      canvas.addSubview(view, positioned: .above, relativeTo: nil)
    }
    selectionChanged()
    syncToolbar()
    scheduleSave()
  }
  func paneChanged(_ state: PaneState) {
    if let i = workspace.panes.firstIndex(where: { $0.id == state.id }) {
      workspace.panes[i] = state
    }
    scheduleSave()
  }
  func pushLayout() {
    layoutHistory.append(workspace)
    if layoutHistory.count > 50 { layoutHistory.removeFirst() }
  }
  func rebuild() {
    workspace.normalize()
    window?.title = "Macfile"
    let ids = Set(workspace.panes.map(\.id))
    for id in panes.keys.filter({ !ids.contains($0) }) {
      panes[id]?.stop()
      panes.removeValue(forKey: id)
    }
    for state in workspace.panes {
      if let existing = panes[state.id] {
        existing.apply(state)
      } else {
        panes[state.id] = PaneController(owner: self, state: state)
      }
    }
    canvas.subviews.forEach { $0.removeFromSuperview() }
    splitHandlers.removeAll()
    rootSplit = nil
    if let focused, let view = panes[focused]?.view {
      canvas.addSubview(view)
      rootSplit = view
    } else if workspace.arrangement == .split, let tree = workspace.tree {
      rootSplit = buildSplit(tree, path: [])
      canvas.addSubview(rootSplit!)
    } else {
      for state in workspace.panes {
        if let view = panes[state.id]?.view { canvas.addSubview(view) }
      }
    }
    layoutWorkbench()
    activate(workspace.active)
    scheduleSave()
    syncToolbar()
  }
  func buildSplit(_ node: SplitNode, path: [Bool]) -> NSView {
    switch node {
    case .leaf(let id): return panes[id]!.view
    case .split(let horizontal, let fraction, let a, let b):
      let split = FlippedSplit()
      split.isVertical = horizontal
      split.dividerStyle = .thin
      split.beginResize = { [weak self] in
        guard self?.workspace.locked == false else { return }
        self?.pushLayout()
      }
      split.addSubview(buildSplit(a, path: path + [false]))
      split.addSubview(buildSplit(b, path: path + [true]))
      let handler = SplitHandler { [weak self] value in
        guard let self, !self.workspace.locked else { return }
        self.workspace.tree = self.workspace.tree?.changingFraction(at: path, to: value)
        self.scheduleSave()
      }
      handler.locked = { [weak self] in self?.workspace.locked ?? false }
      split.delegate = handler
      splitHandlers.append(handler)
      split.identifier = NSUserInterfaceItemIdentifier(String(fraction))
      return split
    }
  }
  func positionSplits(_ view: NSView) {
    guard let split = view as? NSSplitView else { return }
    let f = Double(split.identifier?.rawValue ?? "0.5") ?? 0.5
    split.adjustSubviews()
    split.setPosition(
      (split.isVertical ? split.bounds.width : split.bounds.height) * f, ofDividerAt: 0)
    split.subviews.forEach(positionSplits)
  }
  func layoutWorkbench() {
    let visible = scroll.contentSize
    let width = max(420, visible.width)
    let height = max(320, visible.height)
    if focused != nil {
      canvas.frame = NSRect(x: 0, y: 0, width: width, height: height)
      rootSplit?.frame = canvas.bounds
      return
    }
    if workspace.arrangement == .split, let tree = workspace.tree, let rootSplit {
      let minimum = tree.minimumSize
      canvas.frame = NSRect(
        x: 0, y: 0, width: max(width, minimum.width), height: max(height, minimum.height))
      rootSplit.frame = canvas.bounds
      if splitHandlers.contains(where: { !$0.ready }) {
        positionSplits(rootSplit)
        splitHandlers.forEach { $0.ready = true }
      }
    } else if workspace.arrangement == .free {
      var maxX = width
      var maxY = height
      for (index, state) in workspace.panes.enumerated() {
        let r =
          workspace.frames[state.id]
          ?? Rect(Double(18 + (index % 4) * 48), Double(18 + (index % 4) * 48), 440, 370)
        let f = NSRect(x: r.x, y: r.y, width: max(270, r.width), height: max(240, r.height))
        panes[state.id]?.view.frame = f
        maxX = max(maxX, f.maxX + 18)
        maxY = max(maxY, f.maxY + 18)
      }
      canvas.frame = NSRect(x: 0, y: 0, width: maxX, height: maxY)
    } else {
      let count = workspace.panes.count
      let cols = max(1, min(workspace.columns, count))
      let rows = Int(ceil(Double(count) / Double(cols)))
      canvas.frame = NSRect(
        x: 0, y: 0, width: max(width, CGFloat(cols) * 280),
        height: max(height, CGFloat(rows) * 255))
      let rects = LayoutPreset.grid(count: count, columns: cols)
      for (state, r) in zip(workspace.panes, rects) {
        let x = (r.x * canvas.bounds.width).rounded()
        let y = (r.y * canvas.bounds.height).rounded()
        let maxX = ((r.x + r.width) * canvas.bounds.width).rounded()
        let maxY = ((r.y + r.height) * canvas.bounds.height).rounded()
        panes[state.id]?.view.frame = NSRect(
          x: x, y: y,
          width: maxX - x - (r.x + r.width < 0.999 ? 1 : 0),
          height: maxY - y - (r.y + r.height < 0.999 ? 1 : 0))
      }
    }
    for pane in panes.values {
      pane.view.layoutSubtreeIfNeeded()
      pane.fitPath()
      pane.fitColumns()
    }
  }
  func updateFreeFrame(_ id: UUID, origin: NSPoint?, size: NSSize?, commit: Bool) {
    guard let pane = panes[id] else { return }
    if !freeHistorySaved {
      pushLayout()
      freeHistorySaved = true
    }
    var f = pane.view.frame
    if let origin {
      f.origin = NSPoint(
        x: max(8, (origin.x / 8).rounded() * 8), y: max(8, (origin.y / 8).rounded() * 8))
    }
    if let size {
      f.size = NSSize(
        width: max(270, (size.width / 8).rounded() * 8),
        height: max(240, (size.height / 8).rounded() * 8))
    }
    workspace.frames[id] = Rect(f.origin.x, f.origin.y, f.width, f.height)
    pane.view.frame = f
    canvas.frame.size = NSSize(
      width: max(scroll.contentSize.width, f.maxX + 18, canvas.frame.width),
      height: max(scroll.contentSize.height, f.maxY + 18, canvas.frame.height))
    if commit { finishFreeChange() }
  }
  func finishFreeChange() {
    freeHistorySaved = false
    scheduleSave()
  }
  func addPane(path: String? = nil, horizontal: Bool? = nil) {
    pushLayout()
    let state = PaneState(
      path: path ?? activePane?.currentURL.path
        ?? FileManager.default.homeDirectoryForCurrentUser.path)
    if let horizontal {
      if workspace.tree == nil {
        workspace.tree = LayoutPreset(
          id: "", name: "", count: workspace.panes.count,
          rects: LayoutPreset.grid(count: workspace.panes.count, columns: workspace.columns)
        ).tree(ids: workspace.panes.map(\.id))
      }
      workspace.tree = (workspace.tree ?? .leaf(workspace.active)).splitting(
        workspace.active, adding: state.id, horizontal: horizontal)
      workspace.arrangement = .split
    } else if workspace.arrangement == .split {
      workspace.tree = workspace.tree?.splitting(
        workspace.active, adding: state.id, horizontal: true)
    }
    workspace.panes.append(state)
    workspace.active = state.id
    focused = nil
    rebuild()
  }
  func closePane(_ id: UUID) {
    guard workspace.panes.count > 1, let i = workspace.panes.firstIndex(where: { $0.id == id })
    else {
      setStatus("保留最后一个目录窗口；可关闭主窗口。")
      return
    }
    pushLayout()
    closedPanes.append(workspace.panes.remove(at: i))
    workspace.tree = workspace.tree?.removing(id)
    workspace.frames.removeValue(forKey: id)
    focused = nil
    rebuild()
  }
  func rearrange(_ source: UUID, relativeTo target: UUID, zone: String) {
    guard source != target, !workspace.locked,
      let si = workspace.panes.firstIndex(where: { $0.id == source }),
      let ti = workspace.panes.firstIndex(where: { $0.id == target })
    else { return }
    pushLayout()
    if zone == "center" {
      workspace.panes.swapAt(si, ti)
      if let tree = workspace.tree {
        let temporary = UUID()
        workspace.tree = tree.replacing(source, with: temporary).replacing(target, with: source)
          .replacing(temporary, with: target)
      }
      let a = workspace.frames[source]
      let b = workspace.frames[target]
      workspace.frames[source] = b
      workspace.frames[target] = a
    } else {
      let base =
        workspace.tree
        ?? LayoutPreset(
          id: "", name: "", count: workspace.panes.count,
          rects: LayoutPreset.grid(count: workspace.panes.count, columns: workspace.columns)
        ).tree(ids: workspace.panes.map(\.id))
      var tree = base?.removing(source)?.splitting(
        target, adding: source, horizontal: zone == "left" || zone == "right")
      if zone == "left" || zone == "top", let current = tree {
        let temp = UUID()
        tree = current.replacing(source, with: temp).replacing(target, with: source).replacing(
          temp, with: target)
      }
      workspace.tree = tree
      workspace.arrangement = .split
    }
    rebuild()
  }
  func toggleFocus(_ id: UUID) {
    focused = focused == id ? nil : id
    rebuild()
  }
  func openPath(_ url: URL, newPane: Bool = false) {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
      NSWorkspace.shared.open(url)
      return
    }
    if newPane { addPane(path: url.path) } else { activePane?.navigate(url) }
  }
  func loadWorkspace(_ saved: Workspace) {
    pushLayout()
    workspace = saved
    focused = nil
    rebuild()
  }
  func saveWorkspace() {
    askText("保存工作区", value: workspace.name, window: window) { [weak self] name in
      guard let self, let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
      self.workspace.name = name
      if let i = self.app.state.workspaces.firstIndex(where: { $0.name == name }) {
        self.app.state.workspaces[i] = self.workspace
      } else {
        var saved = self.workspace
        saved.id = UUID()
        self.app.state.workspaces.append(saved)
      }
      self.rebuild()
      self.app.refreshShared()
    }
  }
  func addBookmark() {
    guard let pane = activePane else { return }
    let url = pane.selectedURLs.count == 1 ? pane.selectedURLs[0] : pane.currentURL
    askText("添加书签", value: url.lastPathComponent, detail: url.path, window: window) {
      [weak self] name in
      guard let self, let name, !name.isEmpty else { return }
      self.app.state.bookmarks.append(Bookmark(name: name, path: url.path))
      self.app.refreshShared()
    }
  }
  func selectionChanged() {
    guard let pane = activePane else { return }
    syncToolbar()
    let urls = pane.selectedURLs
    if urls.count == 1,
      let item = pane.items.first(where: { $0.url == urls[0] }) ?? (try? FileItem(url: urls[0]))
    {
      inspectorName.stringValue = item.name
      inspectorDetail.stringValue =
        "种类    \(item.kind)\n大小    \(item.isFolder ? "—" : bytesFormatter.string(fromByteCount: item.size))\n修改    \(shortDateFormatter.string(from: item.modified))\n\n位置\n\(item.url.deletingLastPathComponent().path)"
      preview.isHidden = false
      if inspectorVisible { preview.previewItem = item.url as NSURL }
    } else {
      inspectorName.stringValue = urls.isEmpty ? "选择文件查看详情" : "已选择 \(urls.count) 项"
      inspectorDetail.stringValue =
        (urls.isEmpty ? "选择一个文件，查看预览、大小与修改时间。" : "选择单个文件可查看详细信息。")
        + "\n\n当前目录\n" + pane.currentURL.path
      preview.previewItem = nil
      preview.isHidden = true
    }
  }
  func toggleInspector() {
    inspectorVisible.toggle()
    inspector.isHidden = !inspectorVisible
    window?.contentView?.layoutSubtreeIfNeeded()
    layoutWorkbench()
    selectionChanged()
  }
  func tasksChanged() {
    let activeCount = app.tasks.records.filter { [.running, .queued, .paused].contains($0.status) }
      .count
    let item = window?.toolbar?.items.first { $0.itemIdentifier.rawValue == "tasks" }
    item?.label = activeCount == 0 ? "任务" : "任务 · \(activeCount)"
    if let r = app.tasks.records.first { setStatus(r.title + " · " + r.current) }
    tasksController?.reload()
    if !app.tasks.hasActive { panes.values.forEach { $0.refresh() } }
  }
  func transfer(_ urls: [URL], to destination: URL, move: Bool) {
    guard !urls.isEmpty else { return }
    let conflicts = urls.filter {
      FileOperations.exists(destination.appendingPathComponent($0.lastPathComponent))
    }
    if conflicts.isEmpty {
      app.tasks.transfer(urls, to: destination, move: move, conflict: .ask)
      return
    }
    let alert = NSAlert()
    alert.messageText = "目标已有 \(conflicts.count) 个同名项目"
    alert.informativeText =
      "\(destination.path)\n\n\(conflicts.prefix(5).map(\.lastPathComponent).joined(separator: "\n"))\n\n替换会保留隐藏备份用于撤销；文件夹替换整个文件夹，不合并内容。以下选择仅用于本次任务的冲突项目。"
    alert.addButton(withTitle: "保留两者")
    alert.addButton(withTitle: "替换并保留备份")
    alert.addButton(withTitle: "跳过同名项")
    alert.addButton(withTitle: "取消")
    alert.beginSheetModal(for: window!) { [weak self] response in
      guard let self else { return }
      let policies: [NSApplication.ModalResponse: ConflictPolicy] = [
        .alertFirstButtonReturn: .keepBoth, .alertSecondButtonReturn: .replace,
        .alertThirdButtonReturn: .skip,
      ]
      if let policy = policies[response] {
        self.app.tasks.transfer(urls, to: destination, move: move, conflict: policy)
      }
    }
  }
  func chooseDestination(move: Bool) {
    guard let urls = activePane?.selectedURLs, !urls.isEmpty else { return }
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.prompt = move ? "移动到这里" : "复制到这里"
    panel.beginSheetModal(for: window!) { [weak self] response in
      if response == .OK, let url = panel.url { self?.transfer(urls, to: url, move: move) }
    }
  }
  func newFolder() {
    guard let current = activePane?.currentURL else { return }
    askText("新建文件夹", value: "未命名文件夹", window: window) { [weak self] name in
      guard let self, let name else { return }
      var rule = RenameRule()
      rule.prefix = name
      rule.find = "x"
      do {
        let valid = try rule.result(for: URL(fileURLWithPath: "/x"), index: 0)
        self.app.tasks.perform(title: "新建文件夹：" + valid, total: 1) { engine, done in
          done(try engine.createFolder(current.appendingPathComponent(valid)))
        }
      } catch { showError(error, window: self.window) }
    }
  }
  func rename() {
    guard let urls = activePane?.selectedURLs, !urls.isEmpty else { return }
    if urls.count > 1 {
      showRename()
      return
    }
    let url = urls[0]
    askText("重命名", value: url.lastPathComponent, window: window) { [weak self] name in
      guard let self, let name, name != url.lastPathComponent else { return }
      self.app.tasks.perform(title: "重命名：" + url.lastPathComponent, total: 1) { engine, done in
        try engine.renameBatch([(url, name)], didComplete: done)
      }
    }
  }
  func trash() {
    guard let urls = activePane?.selectedURLs, !urls.isEmpty else { return }
    let alert = NSAlert()
    alert.messageText = "将 \(urls.count) 项移入废纸篓？"
    alert.informativeText = urls.prefix(5).map(\.lastPathComponent).joined(separator: "\n")
    alert.addButton(withTitle: "移入废纸篓")
    alert.addButton(withTitle: "取消")
    alert.beginSheetModal(for: window!) { [weak self] response in
      if response == .alertFirstButtonReturn {
        self?.app.tasks.perform(title: "移入废纸篓 · \(urls.count) 项", total: urls.count) {
          engine, done in for url in urls { done(try engine.trash(url)) }
        }
      }
    }
  }
  func copyFiles() {
    guard let urls = activePane?.selectedURLs, !urls.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects(urls as [NSURL])
    setStatus("已复制 \(urls.count) 项 · ⌘V 复制到目标，⌥⌘V 移动到目标")
  }
  func pasteFiles(move: Bool) {
    guard
      let urls = NSPasteboard.general.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
      let destination = activePane?.currentURL
    else { return }
    transfer(urls, to: destination, move: move)
  }
  func validateMenuItem(_ item: NSMenuItem) -> Bool {
    guard let command = item.representedObject as? String else { return true }
    guard let pane = activePane else { return false }
    if app.canPerformTextCommand(command) { return true }
    item.state = .off
    if command.hasPrefix("view-") {
      item.state = command == "view-" + pane.state.current.mode.rawValue ? .on : .off
    }
    switch command {
    case "rename": return pane.selection.count == 1
    case "copy", "copyTo", "moveTo", "trash", "preview", "batchRename", "basketAdd":
      return !pane.selection.isEmpty
    case "paste", "movePaste":
      return NSPasteboard.general.canReadObject(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    case "nextTab", "previousTab": return pane.state.tabs.count > 1
    case "restorePane": return !closedPanes.isEmpty
    case "undoLayout": return !layoutHistory.isEmpty
    case "undoFiles":
      return !app.tasks.hasActive
        && app.tasks.records.contains { $0.receipts.contains { !$0.undone } }
    case "saveSearch": return !pane.searchField.stringValue.isEmpty
    case "hidden": item.state = pane.state.current.showHidden ? .on : .off
    case "inspector": item.state = inspectorVisible ? .on : .off
    case "lock": item.state = workspace.locked ? .on : .off
    case "focus": item.state = focused == workspace.active ? .on : .off
    case "tile": item.state = workspace.arrangement == .tile ? .on : .off
    case "free": item.state = workspace.arrangement == .free ? .on : .off
    case "recursive": item.state = pane.recursive ? .on : .off
    default: break
    }
    return true
  }
  func command(_ command: String) {
    if command.hasPrefix("view-"), let mode = ViewMode(rawValue: String(command.dropFirst(5))) {
      activePane?.setMode(mode)
      return
    }
    if app.performTextCommand(command) { return }
    switch command {
    case "addPane": addPane()
    case "newTab": activePane?.addTab()
    case "closeTab": activePane?.closeTab()
    case "nextTab", "previousTab":
      guard let pane = activePane, !pane.state.tabs.isEmpty else { return }
      let count = pane.state.tabs.count
      let offset = command == "nextTab" ? 1 : -1
      pane.selectTab((pane.state.selectedTab + offset + count) % count)
    case "restorePane":
      if let pane = closedPanes.popLast() {
        pushLayout()
        workspace.panes.append(pane)
        workspace.active = pane.id
        workspace.arrangement = .tile
        workspace.tree = nil
        rebuild()
      }
    case "newFolder": newFolder()
    case "rename": rename()
    case "batchRename": showRename()
    case "trash": trash()
    case "saveWorkspace": saveWorkspace()
    case "go": activePane?.goToPath()
    case "undoLayout":
      if let old = layoutHistory.popLast() {
        workspace = old
        focused = nil
        rebuild()
      }
    case "undoFiles":
      if let record = app.tasks.records.first(where: { $0.receipts.contains { !$0.undone } }) {
        app.tasks.undo(record.id)
      }
    case "copy": copyFiles()
    case "paste": pasteFiles(move: false)
    case "movePaste": pasteFiles(move: true)
    case "selectAll": activePane?.selectAll()
    case "copyPath":
      let text =
        (activePane?.selectedURLs.isEmpty == false
        ? activePane!.selectedURLs : [activePane?.currentURL].compactMap { $0 }).map(\.path).joined(
          separator: "\n")
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    case "copyTo": chooseDestination(move: false)
    case "moveTo": chooseDestination(move: true)
    case "hidden": activePane?.toggleHidden()
    case "preview": activePane?.quickLook()
    case "inspector": toggleInspector()
    case "refresh": activePane?.refresh()
    case "search": searchToolbar.beginSearchInteraction()
    case "editPath": activePane?.beginPathEditing()
    case "sidebar":
      sideBackground.isHidden.toggle()
      sidebarDivider.isHidden = sideBackground.isHidden
      window?.contentView?.layoutSubtreeIfNeeded()
      layoutWorkbench()
    case "workspaces": showWorkspaces()
    case "searches": showSearches()
    case "saveSearch": activePane?.saveSearch()
    case "layouts": showLayouts()
    case "tile":
      pushLayout()
      workspace.arrangement = .tile
      workspace.tree = nil
      focused = nil
      rebuild()
    case "free":
      pushLayout()
      for (id, pane) in panes {
        let frame = pane.view.convert(pane.view.bounds, to: canvas)
        workspace.frames[id] = Rect(frame.origin.x, frame.origin.y, frame.width, frame.height)
      }
      workspace.arrangement = .free
      focused = nil
      rebuild()
    case "splitH": addPane(horizontal: true)
    case "splitV": addPane(horizontal: false)
    case "focus": toggleFocus(workspace.active)
    case "lock":
      workspace.locked.toggle()
      rebuild()
    case "overview": showOverview()
    case "favoriteLayout":
      askText("收藏布局", value: "\(workspace.panes.count) 窗口布局", window: window) { [weak self] name in
        guard let self, let name, !name.isEmpty else { return }
        self.app.state.favorites.append(LayoutFavorite(name: name, workspace: self.workspace))
        self.app.save()
      }
    case "bookmark": addBookmark()
    case "bookmarks": showBookmarks()
    case "basketAdd":
      for url in activePane?.selectedURLs ?? [] {
        if !app.state.basket.contains(url.path) { app.state.basket.append(url.path) }
      }
      app.refreshShared()
      setStatus("已加入收集篮；原文件保持原位")
    case "basket": showBasket()
    case "tasks": showTasks()
    case "commands": showCommands()
    case "finder":
      let urls = activePane?.selectedURLs ?? []
      NSWorkspace.shared.activateFileViewerSelecting(
        urls.isEmpty ? [activePane?.currentURL].compactMap { $0 } : urls)
    case "terminal":
      if let url = activePane?.currentURL,
        let terminal = NSWorkspace.shared.urlForApplication(
          withBundleIdentifier: "com.apple.Terminal")
      {
        NSWorkspace.shared.open(
          [url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
      }
    default: break
    }
  }
  func windowDidResize(_ notification: Notification) { layoutWorkbench() }
  func windowDidBecomeKey(_ notification: Notification) {
    app.lastActiveWorkspace = self
    syncToolbar()
    scheduleSave()
  }
  func windowDidResignKey(_ notification: Notification) {
    sidebar.arrangedSubviews.forEach { $0.needsDisplay = true }
  }
  func windowWillClose(_ notification: Notification) {
    app.state.session = workspace
    app.controllers.removeAll { $0 === self }
    app.state.sessions = app.controllers.map(\.workspace)
    try? app.store.save(app.state)
    saveTimer?.invalidate()
    if let focusMonitor { NSEvent.removeMonitor(focusMonitor) }
    panes.values.forEach { $0.stop() }
  }
}
