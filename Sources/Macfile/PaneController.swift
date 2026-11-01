import AppKit
import MacfileCore
import QuickLookThumbnailing
import QuickLookUI
import UniformTypeIdentifiers

final class BrowserNode: NSObject {
  let item: FileItem
  init(_ item: FileItem) { self.item = item }
}
final class FileBrowser: NSBrowser {
  weak var pane: PaneController?
  override func mouseDown(with event: NSEvent) {
    if let pane { pane.owner?.activate(pane.id) }
    super.mouseDown(with: event)
  }
  override func keyDown(with event: NSEvent) {
    if pane?.handleKey(event) == true { return }
    super.keyDown(with: event)
  }
}
final class DirectoryTabView: NSView {
  var selected = false
  override func draw(_ dirtyRect: NSRect) {
    (selected ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).setFill()
    bounds.fill()
    NSColor.separatorColor.setFill()
    if !selected { NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() }
    NSRect(x: bounds.maxX - 1, y: 6, width: 1, height: bounds.height - 12).fill()
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}
final class PaneController: NSViewController, NSSearchFieldDelegate, QLPreviewPanelDataSource,
  QLPreviewPanelDelegate, NSBrowserDelegate
{
  weak var owner: WorkspaceController?
  var state: PaneState
  var id: UUID { state.id }
  var currentURL: URL { URL(fileURLWithPath: state.current.path) }
  var operationDirectoryURL: URL {
    guard state.current.mode == .columns else { return currentURL }
    if let navigation = browserNavigationToRestore {
      return navigation.directories.last ?? currentURL
    }
    guard browser.lastColumn > 0 else { return currentURL }
    return (browser.parentForItems(inColumn: browser.lastColumn) as? BrowserNode)?.item.url
      ?? currentURL
  }
  var items: [FileItem] = []
  var allItems: [FileItem] = []
  var selection = Set<URL>()
  var selectedURLs: [URL] {
    selection.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
  }
  let surface = PaneSurface()
  let table = FileTable()
  let collection = FileCollection()
  let fileScroll = FileScrollView()
  let browser = FileBrowser()
  let content = NSView()
  let tabs = NSStackView()
  let tabScroll = NSScrollView()
  let tabStrip = NSStackView()
  let header = PaneHeader()
  let location = NSView()
  let breadcrumbs = NSPathControl()
  let ancestorsButton = ActionButton("", symbol: "ellipsis", help: "完整路径与上级目录", action: {})
  var fullPathItems: [NSPathControlItem] = []
  private var visiblePathCount = 0
  let backButton = ActionButton("", symbol: "chevron.left", help: "后退 ⌘[", action: {})
  let forwardButton = ActionButton("", symbol: "chevron.right", help: "前进 ⌘]", action: {})
  let queryLabel = label("", size: 10, color: .secondaryLabelColor)
  private var lastColumnWidth: CGFloat = 0
  let pathField = NSTextField()
  let searchField = NSSearchField()
  let scopeButton = NSButton(checkboxWithTitle: "子目录", target: nil, action: nil)
  let searchScopeRow = NSStackView()
  let searchScope = NSSegmentedControl(
    labels: ["当前目录", "包含子目录"], trackingMode: .selectOne, target: nil, action: nil)
  let clearSearchButton = ActionButton("", symbol: "xmark.circle.fill", help: "清除搜索", action: {})
  let modeButton = NSPopUpButton()
  let countLabel = label("正在读取…", size: 10, color: .secondaryLabelColor)
  let emptyLabel = label("", size: 13, color: .secondaryLabelColor)
  let emptyDetail = label("", size: 11, color: .secondaryLabelColor)
  let emptyIcon = NSImageView()
  let emptyState = NSStackView()
  let emptyActions = NSStackView()
  let emptyPrimary = ActionButton("", action: {})
  let emptySecondary = ActionButton("返回上一级", action: {})
  let loadingIndicator = NSProgressIndicator()
  let galleryPreview = QLPreviewView(
    frame: NSRect(x: 0, y: 0, width: 300, height: 250), style: .normal)!
  let galleryHost = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 250))
  let galleryImage = NSImageView()
  let galleryPlaceholder = NSStackView()
  let galleryIcon = NSImageView()
  let galleryTitle = label("", size: 13, weight: .medium, color: .secondaryLabelColor)
  let galleryHint = label("", size: 11, color: .secondaryLabelColor)
  private var galleryImageRequest: QLThumbnailGenerator.Request?
  private(set) var galleryImageURL: URL?
  private(set) var galleryImageLoading = false
  let grip = ResizeGrip()
  let queue = OperationQueue()
  var generation = UUID()
  var watch: DispatchSourceFileSystemObject?
  var searchTimer: Timer?
  var history: [String] = []
  var forwardHistory: [String] = []
  var recursive = false
  private struct TabNavigation {
    var history: [String] = []
    var forwardHistory: [String] = []
    var query = ""
    var recursive = false
  }
  private var tabNavigation: [UUID: TabNavigation] = [:]
  private var contentsURL: URL?
  private var contentsTabID: UUID?
  private(set) var isLoading = false
  private(set) var readError: String?
  private var skippedLocations = 0
  var browserCache: [String: [BrowserNode]] = [:]
  var browserLoading = Set<String>()
  private struct BrowserNavigation {
    var directories: [URL]
    var selectedColumn: Int
    var selection: Set<URL>
  }
  private var browserNavigationToRestore: BrowserNavigation?
  private var browserRootPath: String?
  private var browserTabID: UUID?
  private var restoringBrowser = false
  private(set) var isReloadingViews = false
  var quickLookURLs: [URL] = []
  init(owner: WorkspaceController, state: PaneState) {
    self.owner = owner
    self.state = state
    super.init(nibName: nil, bundle: nil)
    queue.maxConcurrentOperationCount = 2
    queue.qualityOfService = .userInitiated
    loadView()
    build()
    refresh()
  }
  required init?(coder: NSCoder) { fatalError() }
  override func loadView() {
    view = surface
    surface.pane = self
  }
  func build() {
    surface.highlight(false)
    header.pane = self
    let handle = label("⠿", size: 13, color: .tertiaryLabelColor)
    handle.widthAnchor.constraint(equalToConstant: 12).isActive = true
    handle.toolTip = "拖动排列分栏；双击放大"
    backButton.actionBlock = { [weak self] in self?.back() }
    forwardButton.actionBlock = { [weak self] in self?.forward() }
    for button in [backButton, forwardButton] {
      button.isBordered = false
      button.controlSize = .small
      button.widthAnchor.constraint(equalToConstant: 22).isActive = true
    }
    breadcrumbs.pathStyle = .standard
    breadcrumbs.isEditable = false
    breadcrumbs.focusRingType = .none
    breadcrumbs.backgroundColor = .clear
    breadcrumbs.font = .systemFont(ofSize: 13)
    breadcrumbs.target = self
    breadcrumbs.action = #selector(pathComponentClicked)
    breadcrumbs.doubleAction = #selector(editLocation)
    breadcrumbs.setAccessibilityLabel("路径导航")
    pathField.font = .systemFont(ofSize: 13)
    pathField.lineBreakMode = .byTruncatingMiddle
    pathField.bezelStyle = .roundedBezel
    pathField.target = self
    pathField.action = #selector(pathEntered)
    pathField.delegate = self
    pathField.setAccessibilityLabel("编辑目录路径")
    ancestorsButton.actionBlock = { [weak self] in self?.showAncestors() }
    ancestorsButton.isBordered = false
    ancestorsButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
    let pathRow = row([ancestorsButton, breadcrumbs], spacing: 0)
    breadcrumbs.setContentHuggingPriority(.defaultLow, for: .horizontal)
    location.addSubview(pathRow)
    location.addSubview(pathField)
    pin(pathRow, to: location)
    pin(pathField, to: location)
    location.heightAnchor.constraint(equalToConstant: 24).isActive = true
    location.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
    location.setContentHuggingPriority(.defaultLow, for: .horizontal)
    pathField.isHidden = true
    let more = ActionButton("", symbol: "ellipsis", help: "分栏操作") { [weak self] in
      self?.showPaneMenu()
    }
    more.isBordered = false
    more.widthAnchor.constraint(equalToConstant: 24).isActive = true
    let headerRow = row([handle, backButton, forwardButton, location, more], spacing: 2)
    headerRow.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
    header.addSubview(headerRow)
    pin(headerRow, to: header)
    header.heightAnchor.constraint(equalToConstant: 40).isActive = true

    tabs.orientation = .horizontal
    tabs.spacing = 0
    tabScroll.drawsBackground = false
    tabScroll.hasHorizontalScroller = true
    tabScroll.autohidesScrollers = true
    tabScroll.scrollerStyle = .overlay
    tabScroll.borderType = .noBorder
    tabScroll.documentView = tabs
    tabs.translatesAutoresizingMaskIntoConstraints = false
    tabs.heightAnchor.constraint(equalTo: tabScroll.contentView.heightAnchor).isActive = true
    let plus = ActionButton("", symbol: "plus", help: "新建标签 ⌘T") { [weak self] in self?.addTab() }
    plus.isBordered = false
    plus.controlSize = .small
    plus.widthAnchor.constraint(equalToConstant: 28).isActive = true
    tabStrip.orientation = .horizontal
    tabStrip.spacing = 0
    tabStrip.addArrangedSubview(tabScroll)
    tabStrip.addArrangedSubview(plus)
    tabStrip.heightAnchor.constraint(equalToConstant: 30).isActive = true
    tabScroll.setContentHuggingPriority(.defaultLow, for: .horizontal)

    // Each pane keeps its query and mode; the shared toolbar edits the active pane.
    searchField.delegate = self
    scopeButton.target = self
    scopeButton.action = #selector(scopeChanged)
    searchScope.target = self
    searchScope.action = #selector(searchScopeChanged)
    searchScope.controlSize = .small
    searchScope.segmentStyle = .rounded
    searchScope.setAccessibilityLabel("搜索范围")
    clearSearchButton.isBordered = false
    clearSearchButton.controlSize = .small
    clearSearchButton.contentTintColor = .secondaryLabelColor
    clearSearchButton.actionBlock = { [weak self] in self?.clearSearch() }
    searchScopeRow.orientation = .horizontal
    searchScopeRow.alignment = .centerY
    searchScopeRow.spacing = 6
    searchScopeRow.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 8)
    for child in [searchScope, flexible(), clearSearchButton] {
      searchScopeRow.addArrangedSubview(child)
    }
    searchScopeRow.heightAnchor.constraint(equalToConstant: 32).isActive = true
    searchScopeRow.isHidden = true
    modeButton.addItems(withTitles: ViewMode.allCases.map(\.title))
    modeButton.target = self
    modeButton.action = #selector(modeChanged)
    grip.pane = self
    grip.widthAnchor.constraint(equalToConstant: 14).isActive = true
    grip.heightAnchor.constraint(equalToConstant: 14).isActive = true
    loadingIndicator.style = .spinning
    loadingIndicator.controlSize = .small
    loadingIndicator.isDisplayedWhenStopped = false
    loadingIndicator.isHidden = true
    loadingIndicator.widthAnchor.constraint(equalToConstant: 12).isActive = true
    loadingIndicator.heightAnchor.constraint(equalToConstant: 12).isActive = true
    loadingIndicator.setAccessibilityLabel("正在读取目录")
    let footer = row([loadingIndicator, countLabel, flexible(), queryLabel, grip], spacing: 5)
    footer.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 2, right: 8)
    footer.heightAnchor.constraint(equalToConstant: 22).isActive = true
    let stack = NSStackView(views: [tabStrip, header, searchScopeRow, content, footer])
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 0
    stack.detachesHiddenViews = true
    surface.addSubview(stack)
    pin(stack, to: surface)
    content.setContentHuggingPriority(.defaultLow, for: .vertical)
    configureFiles()
    renderTabs()
    showMode()
  }
  override func viewDidLayout() {
    super.viewDidLayout()
    fitPath()
    fitColumns()
  }
  func fitPath() {
    let count = location.bounds.width < 270 ? 1 : 2
    guard visiblePathCount != count else { return }
    visiblePathCount = count
    breadcrumbs.pathItems = Array(fullPathItems.suffix(count))
  }
  func showAncestors() {
    owner?.activate(id)
    let menu = NSMenu()
    for component in fullPathItems.reversed() {
      guard let url = component.url else { continue }
      let item = NSMenuItem(
        title: component.title, action: #selector(ancestorSelected(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = url
      item.image = symbol(url.path == "/" ? "internaldrive" : "folder")
      item.state = url.standardizedFileURL.path == currentURL.standardizedFileURL.path ? .on : .off
      item.toolTip = url.path
      menu.addItem(item)
    }
    menu.addItem(.separator())
    let edit = NSMenuItem(title: "编辑完整路径…", action: #selector(editLocation), keyEquivalent: "")
    edit.target = self
    menu.addItem(edit)
    menu.popUp(
      positioning: nil, at: NSPoint(x: 0, y: ancestorsButton.bounds.maxY), in: ancestorsButton)
  }
  @objc func ancestorSelected(_ sender: NSMenuItem) {
    if let url = sender.representedObject as? URL { navigate(url) }
  }
  func fitColumns() {
    guard state.current.mode == .list else { return }
    let width = fileScroll.contentView.bounds.width
    guard width > 100, abs(width - lastColumnWidth) > 0.5 else { return }
    lastColumnWidth = width
    let columns = table.tableColumns
    guard columns.count == 4 else { return }
    columns[3].isHidden = width < 540
    columns[2].isHidden = width < 390
    columns[1].width = 72
    columns[2].width = 130
    columns[3].width = 74
    let metadata = columns.dropFirst().filter { !$0.isHidden }.reduce(CGFloat(0)) { $0 + $1.width }
    let lastVisible = columns.lastIndex { !$0.isHidden } ?? 0
    // Inset tables add native cell padding and outer margins beyond the configured widths.
    let inset =
      table.rect(ofColumn: 0).minX + table.rect(ofColumn: lastVisible).maxX
      - columns[0].width - metadata
    columns[0].width = max(140, width - metadata - inset)
  }
  @objc func pathComponentClicked() {
    guard let url = breadcrumbs.clickedPathItem?.url,
      url.standardizedFileURL.path != currentURL.standardizedFileURL.path
    else { return }
    navigate(url)
  }
  @objc func editLocation() { beginPathEditing() }
  func beginPathEditing() {
    owner?.activate(id)
    pathField.stringValue = (currentURL.path as NSString).abbreviatingWithTildeInPath
    breadcrumbs.isHidden = true
    ancestorsButton.isHidden = true
    pathField.isHidden = false
    view.window?.makeFirstResponder(pathField)
    pathField.selectText(nil)
  }
  func finishPathEditing() {
    pathField.isHidden = true
    breadcrumbs.isHidden = false
    ancestorsButton.isHidden = false
  }
  func focusFiles() {
    guard view.window?.attachedSheet == nil else { return }
    let responder: NSView =
      state.current.mode == .list
      ? table : state.current.mode == .columns ? browser : collection
    view.window?.makeFirstResponder(responder)
  }
  func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
    if control === pathField, selector == #selector(NSResponder.cancelOperation(_:)) {
      finishPathEditing()
      focusFiles()
      return true
    }
    if control === searchField { return handleSearchCommand(selector) }
    return false
  }
  func handleSearchCommand(_ selector: Selector) -> Bool {
    if selector == #selector(NSResponder.cancelOperation(_:)) {
      clearSearch()
      return true
    }
    if selector == #selector(NSResponder.insertNewline(_:)) {
      searchTimer?.invalidate()
      if recursive { refresh() } else { filterItems() }
      focusFiles()
      return true
    }
    return false
  }
  func clearSearch() {
    owner?.activate(id)
    searchTimer?.invalidate()
    searchField.stringValue = ""
    owner?.syncToolbar()
    if recursive { refresh() } else { filterItems() }
    focusFiles()
  }
  func configureFiles() {
    table.pane = self
    table.delegate = self
    table.dataSource = self
    table.allowsMultipleSelection = true
    table.allowsEmptySelection = true
    table.rowHeight = 30
    table.intercellSpacing = NSSize(width: 0, height: 1)
    table.style = .inset
    table.usesAlternatingRowBackgroundColors = false
    table.columnAutoresizingStyle = .noColumnAutoresizing
    table.target = self
    table.doubleAction = #selector(doubleClick)
    for (key, title, width) in [
      ("name", "名称", 210.0), ("size", "大小", 70.0), ("modified", "修改日期", 126.0),
      ("kind", "种类", 70.0),
    ] {
      let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(key))
      col.title = title
      col.width = width
      col.minWidth = key == "name" ? 120 : 50
      col.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
      table.addTableColumn(col)
    }
    table.registerForDraggedTypes(FileDrop.types)
    table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
    table.setDraggingSourceOperationMask(.copy, forLocal: false)
    collection.pane = self
    collection.dataSource = self
    collection.delegate = self
    collection.isSelectable = true
    collection.allowsMultipleSelection = true
    let flow = NSCollectionViewFlowLayout()
    flow.minimumInteritemSpacing = 6
    flow.minimumLineSpacing = 8
    flow.sectionInset = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
    collection.collectionViewLayout = flow
    collection.register(FileTile.self, forItemWithIdentifier: NSUserInterfaceItemIdentifier("file"))
    collection.registerForDraggedTypes(FileDrop.types)
    collection.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
    collection.setDraggingSourceOperationMask(.copy, forLocal: false)
    fileScroll.hasVerticalScroller = true
    fileScroll.hasHorizontalScroller = false
    fileScroll.autohidesScrollers = true
    fileScroll.borderType = .noBorder
    fileScroll.drawsBackground = false
    fileScroll.pane = self
    browser.pane = self
    browser.delegate = self
    browser.minColumnWidth = 180
    browser.allowsMultipleSelection = true
    browser.allowsBranchSelection = true
    browser.allowsEmptySelection = true
    browser.isTitled = false
    browser.registerForDraggedTypes(FileDrop.types)
    browser.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
    browser.setDraggingSourceOperationMask(.copy, forLocal: false)
    browser.target = self
    browser.action = #selector(browserSelected)
    browser.doubleAction = #selector(browserOpened)
    emptyLabel.alignment = .center
    emptyLabel.maximumNumberOfLines = 2
    emptyDetail.alignment = .center
    emptyDetail.maximumNumberOfLines = 3
    emptyDetail.lineBreakMode = .byWordWrapping
    emptyIcon.contentTintColor = .tertiaryLabelColor
    emptyIcon.imageScaling = .scaleProportionallyDown
    emptyIcon.widthAnchor.constraint(equalToConstant: 28).isActive = true
    emptyIcon.heightAnchor.constraint(equalToConstant: 28).isActive = true
    emptyState.orientation = .vertical
    emptyState.alignment = .centerX
    emptyState.spacing = 7
    for view in [emptyIcon, emptyLabel, emptyDetail] { emptyState.addArrangedSubview(view) }
    emptyActions.orientation = .horizontal
    emptyActions.spacing = 8
    for button in [emptyPrimary, emptySecondary] {
      button.controlSize = .small
      emptyActions.addArrangedSubview(button)
    }
    emptyPrimary.actionBlock = { [weak self] in
      guard let self else { return }
      self.owner?.activate(self.id)
      if self.readError != nil {
        self.refresh()
        self.focusFiles()
      } else if !self.searchField.stringValue.isEmpty {
        self.clearSearch()
      } else {
        self.owner?.command("newFolder")
      }
    }
    emptySecondary.actionBlock = { [weak self] in
      guard let self else { return }
      self.navigate(self.currentURL.deletingLastPathComponent())
    }
    emptyState.addArrangedSubview(emptyActions)
    emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: emptyState.widthAnchor).isActive = true
    emptyDetail.widthAnchor.constraint(lessThanOrEqualTo: emptyState.widthAnchor).isActive = true
    galleryHost.addSubview(galleryPreview)
    pin(galleryPreview, to: galleryHost)
    galleryImage.imageScaling = .scaleProportionallyDown
    galleryImage.imageAlignment = .alignCenter
    galleryImage.isHidden = true
    galleryHost.addSubview(galleryImage)
    pin(galleryImage, to: galleryHost, inset: 20)
    galleryIcon.contentTintColor = .tertiaryLabelColor
    galleryIcon.imageScaling = .scaleProportionallyDown
    galleryIcon.widthAnchor.constraint(equalToConstant: 36).isActive = true
    galleryIcon.heightAnchor.constraint(equalToConstant: 36).isActive = true
    galleryTitle.alignment = .center
    galleryTitle.maximumNumberOfLines = 2
    galleryHint.alignment = .center
    galleryHint.maximumNumberOfLines = 3
    galleryHint.lineBreakMode = .byWordWrapping
    galleryPlaceholder.orientation = .vertical
    galleryPlaceholder.alignment = .centerX
    galleryPlaceholder.spacing = 8
    for view in [galleryIcon, galleryTitle, galleryHint] {
      galleryPlaceholder.addArrangedSubview(view)
    }
    galleryHost.addSubview(galleryPlaceholder)
    galleryPlaceholder.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      galleryPlaceholder.centerXAnchor.constraint(equalTo: galleryHost.centerXAnchor),
      galleryPlaceholder.centerYAnchor.constraint(equalTo: galleryHost.centerYAnchor),
      galleryPlaceholder.widthAnchor.constraint(
        lessThanOrEqualTo: galleryHost.widthAnchor, constant: -40),
      galleryTitle.widthAnchor.constraint(lessThanOrEqualTo: galleryPlaceholder.widthAnchor),
      galleryHint.widthAnchor.constraint(lessThanOrEqualTo: galleryPlaceholder.widthAnchor),
    ])
  }
  func apply(_ state: PaneState) {
    guard self.state != state else {
      grip.isHidden = owner?.workspace.arrangement != .free
      return
    }
    let reload = self.state.current != state.current
    let changedTab = self.state.current.id != state.current.id
    if changedTab { saveTabNavigation() }
    self.state = state
    if changedTab { restoreTabNavigation() }
    tabNavigation = tabNavigation.filter { id, _ in state.tabs.contains { $0.id == id } }
    renderTabs()
    if reload {
      showMode()
      refresh()
    }
  }
  func updateTab(_ body: (inout FileTab) -> Void) {
    body(&state.tabs[state.selectedTab])
    owner?.paneChanged(state)
  }
  func renderTabs() {
    tabs.arrangedSubviews.forEach {
      tabs.removeArrangedSubview($0)
      $0.removeFromSuperview()
    }
    for (index, tab) in state.tabs.enumerated() {
      let title = URL(fileURLWithPath: tab.path).lastPathComponent
      let tabView = DirectoryTabView()
      tabView.selected = index == state.selectedTab
      let b = FileDropButton(title.isEmpty ? "/" : title, symbol: "folder", help: tab.path) {
        [weak self] in self?.selectTab(index)
      }
      b.workspace = owner
      b.destination = URL(fileURLWithPath: tab.path)
      b.spring = { [weak self] in self?.selectTab(index) }
      b.registerForDraggedTypes(FileDrop.types)
      b.isBordered = false
      b.bezelStyle = .inline
      b.contentTintColor = index == state.selectedTab ? .labelColor : .secondaryLabelColor
      b.state = index == state.selectedTab ? .on : .off
      b.font = .systemFont(ofSize: 12, weight: index == state.selectedTab ? .medium : .regular)
      b.lineBreakMode = .byTruncatingMiddle
      b.setContentHuggingPriority(.defaultLow, for: .horizontal)
      b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      let close = ActionButton("", symbol: "xmark", help: "关闭标签：" + (title.isEmpty ? "/" : title)) {
        [weak self] in self?.closeTab(tab.id)
      }
      close.isBordered = false
      close.controlSize = .mini
      close.contentTintColor = .secondaryLabelColor
      close.image = symbol("xmark")?.withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 9, weight: .medium))
      close.widthAnchor.constraint(equalToConstant: 18).isActive = true
      let contents = row([b, close], spacing: 2)
      contents.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
      tabView.addSubview(contents)
      pin(contents, to: tabView)
      let textWidth = (title as NSString).size(withAttributes: [.font: b.font!]).width
      tabView.widthAnchor.constraint(equalToConstant: min(190, max(120, textWidth + 64))).isActive =
        true
      tabView.heightAnchor.constraint(equalToConstant: 30).isActive = true
      tabs.addArrangedSubview(tabView)
    }
    tabStrip.isHidden = state.tabs.count < 2
    let selectedID = state.current.id
    DispatchQueue.main.async { [weak self] in
      guard let self, self.state.current.id == selectedID, !self.tabStrip.isHidden else { return }
      // A tab's final frame is available after the stack has laid out its new document views.
      self.view.layoutSubtreeIfNeeded()
      self.tabs.layoutSubtreeIfNeeded()
      let selected = self.tabs.arrangedSubviews[self.state.selectedTab]
      self.tabs.scrollToVisible(selected.frame)
    }
    breadcrumbs.url = currentURL
    fullPathItems = breadcrumbs.pathItems
    for (index, component) in fullPathItems.enumerated() {
      let current = index == fullPathItems.count - 1
      component.attributedTitle = NSAttributedString(
        string: component.title,
        attributes: [
          .font: NSFont.systemFont(ofSize: 13, weight: current ? .medium : .regular),
          .foregroundColor: current ? NSColor.labelColor : NSColor.secondaryLabelColor,
        ])
      if !current { component.image = nil }
    }
    visiblePathCount = 0
    fitPath()
    breadcrumbs.toolTip = currentURL.path
    backButton.isEnabled = !history.isEmpty
    forwardButton.isEnabled = !forwardHistory.isEmpty
    pathField.stringValue = (state.current.path as NSString).abbreviatingWithTildeInPath
    pathField.toolTip = state.current.path
    modeButton.selectItem(at: ViewMode.allCases.firstIndex(of: state.current.mode) ?? 0)
    grip.isHidden = owner?.workspace.arrangement != .free
  }
  func addTab(path: String? = nil) {
    state.tabs.append(FileTab(path: path ?? operationDirectoryURL.path, mode: state.current.mode))
    selectTab(state.tabs.count - 1)
  }
  func closeTab(_ tabID: UUID? = nil) {
    guard let index = state.tabs.firstIndex(where: { $0.id == (tabID ?? state.current.id) }) else {
      return
    }
    if state.tabs.count == 1 {
      owner?.closePane(id)
      return
    }
    let selectedID = state.current.id
    let closingSelected = state.tabs[index].id == selectedID
    tabNavigation.removeValue(forKey: state.tabs[index].id)
    state.tabs.remove(at: index)
    if closingSelected {
      state.selectedTab = min(index, state.tabs.count - 1)
      finishTabSelection()
    } else {
      state.selectedTab = state.tabs.firstIndex { $0.id == selectedID }!
      owner?.paneChanged(state)
      renderTabs()
    }
  }
  func selectTab(_ index: Int) {
    guard state.tabs.indices.contains(index) else { return }
    guard index != state.selectedTab else {
      owner?.activate(id)
      return
    }
    saveTabNavigation()
    state.selectedTab = index
    finishTabSelection()
  }
  private func saveTabNavigation() {
    tabNavigation[state.current.id] = TabNavigation(
      history: history, forwardHistory: forwardHistory, query: searchField.stringValue,
      recursive: recursive)
  }
  private func restoreTabNavigation() {
    let navigation = tabNavigation[state.current.id] ?? TabNavigation()
    history = navigation.history
    forwardHistory = navigation.forwardHistory
    searchField.stringValue = navigation.query
    recursive = navigation.recursive
    scopeButton.state = recursive ? .on : .off
  }
  private func finishTabSelection() {
    restoreTabNavigation()
    selection.removeAll()
    owner?.paneChanged(state)
    owner?.activate(id)
    renderTabs()
    showMode()
    refresh()
    focusFiles()
  }
  func navigate(_ url: URL, record: Bool = true) {
    finishPathEditing()
    guard url.standardizedFileURL != currentURL.standardizedFileURL else {
      refresh()
      focusFiles()
      return
    }
    if record {
      history.append(currentURL.path)
      forwardHistory.removeAll()
    }
    updateTab { $0.path = url.standardizedFileURL.path }
    selection.removeAll()
    searchField.stringValue = ""
    renderTabs()
    owner?.activate(id)
    refresh()
    focusFiles()
  }
  func back() {
    guard let path = history.popLast() else { return }
    forwardHistory.append(currentURL.path)
    navigate(URL(fileURLWithPath: path), record: false)
  }
  func forward() {
    guard let path = forwardHistory.popLast() else { return }
    history.append(currentURL.path)
    navigate(URL(fileURLWithPath: path), record: false)
  }
  @objc func pathEntered() {
    finishPathEditing()
    let path = (pathField.stringValue as NSString).expandingTildeInPath
    navigate(
      path.hasPrefix("/") ? URL(fileURLWithPath: path) : currentURL.appendingPathComponent(path))
  }
  func goToPath() {
    askText("前往文件夹", value: currentURL.path, window: owner?.window) { [weak self] value in
      guard let self, let value else { return }
      self.navigate(URL(fileURLWithPath: (value as NSString).expandingTildeInPath))
    }
  }
  @objc func scopeChanged() {
    setSearchScope(scopeButton.state == .on)
  }
  @objc func searchScopeChanged() {
    setSearchScope(searchScope.selectedSegment == 1)
  }
  func setSearchScope(_ includeSubdirectories: Bool) {
    owner?.activate(id)
    recursive = includeSubdirectories
    scopeButton.state = recursive ? .on : .off
    owner?.syncToolbar()
    refresh()
  }
  @objc func modeChanged() { setMode(ViewMode.allCases[modeButton.indexOfSelectedItem]) }
  func setMode(_ mode: ViewMode) {
    if state.current.mode != mode {
      browserNavigationToRestore = nil
      browserRootPath = nil
    }
    updateTab { $0.mode = mode }
    modeButton.selectItem(at: ViewMode.allCases.firstIndex(of: mode)!)
    owner?.activate(id)
    showMode()
    reloadViews()
    focusFiles()
  }
  func showMode() {
    if state.current.mode != .gallery { cancelGalleryImage() }
    content.subviews.forEach { $0.removeFromSuperview() }
    fileScroll.documentView = nil
    switch state.current.mode {
    case .list:
      fileScroll.documentView = table
      content.addSubview(fileScroll)
      pin(fileScroll, to: content)
    case .icons, .thumbnails:
      fileScroll.documentView = collection
      content.addSubview(fileScroll)
      pin(fileScroll, to: content)
    case .columns:
      content.addSubview(browser)
      pin(browser, to: content)
    case .gallery:
      fileScroll.documentView = collection
      let split = NSSplitView()
      split.isVertical = false
      split.dividerStyle = .thin
      split.addSubview(galleryHost)
      split.addSubview(fileScroll)
      content.addSubview(split)
      pin(split, to: content)
      split.frame = content.bounds
      split.adjustSubviews()
      split.setPosition(max(100, content.bounds.height * 0.62), ofDividerAt: 0)
    }
    content.addSubview(emptyState)
    emptyState.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      emptyState.centerXAnchor.constraint(equalTo: content.centerXAnchor),
      emptyState.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      emptyState.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -48),
    ])
    updateStatus()
  }
  func toggleHidden() {
    updateTab { $0.showHidden.toggle() }
    refresh()
  }
  func controlTextDidChange(_ obj: Notification) {
    guard obj.object as? NSSearchField === searchField else { return }
    searchTimer?.invalidate()
    updateStatus()
    if recursive {
      queue.cancelAllOperations()
      generation = UUID()
    }
    searchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
      guard let self else { return }
      if self.recursive { self.refresh() } else { self.filterItems() }
    }
  }
  func refresh() {
    cancelGalleryImage()
    searchTimer?.invalidate()
    queue.cancelAllOperations()
    let token = UUID()
    generation = token
    let url = currentURL
    let hidden = state.current.showHidden
    let query = searchField.stringValue
    let deep = recursive && !query.isEmpty
    isLoading = true
    readError = nil
    emptyDetail.toolTip = nil
    skippedLocations = 0
    watch?.cancel()
    watch = nil
    browserLoading.removeAll()
    if contentsURL != url || contentsTabID != state.current.id {
      browserNavigationToRestore = nil
      browserCache.removeAll()
      contentsURL = url
      contentsTabID = state.current.id
      allItems = []
      items = []
      selection.removeAll()
      reloadViews()
    } else {
      updateStatus()
    }
    let operation = BlockOperation()
    operation.addExecutionBlock { [weak self, weak operation] in
      guard let self, let operation, !operation.isCancelled else { return }
      do {
        var files: [FileItem] = []
        var skipped = 0
        let keys: [URLResourceKey] = [
          .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey,
          .contentModificationDateKey,
        ]
        if deep {
          let options: FileManager.DirectoryEnumerationOptions =
            hidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants]
          guard
            let enumerator = FileManager.default.enumerator(
              at: url, includingPropertiesForKeys: keys, options: options,
              errorHandler: { _, _ in
                skipped += 1
                return true
              })
          else { throw CocoaError(.fileReadNoPermission) }
          for case let itemURL as URL in enumerator {
            if operation.isCancelled { return }
            if itemURL.lastPathComponent.localizedCaseInsensitiveContains(query),
              let item = try? FileItem(url: itemURL)
            {
              files.append(item)
            }
          }
        } else {
          let urls = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: keys, options: hidden ? [] : [.skipsHiddenFiles]
          )
          for itemURL in urls {
            if operation.isCancelled { return }
            if let item = try? FileItem(url: itemURL) { files.append(item) }
          }
        }
        if operation.isCancelled { return }
        let result = files
        let skippedCount = skipped
        DispatchQueue.main.async { [weak self] in
          guard let self, self.generation == token else { return }
          self.isLoading = false
          self.skippedLocations = skippedCount
          self.allItems = result
          if self.state.current.mode == .columns {
            self.browserNavigationToRestore = self.captureBrowserNavigation()
          }
          self.browserCache.removeAll()
          self.browserLoading.removeAll()
          self.filterItems()
          self.startWatching()
        }
      } catch {
        DispatchQueue.main.async { [weak self] in
          guard let self, self.generation == token else { return }
          self.isLoading = false
          self.readError = Self.directoryErrorMessage(error)
          self.emptyDetail.toolTip = error.localizedDescription
          self.allItems = []
          self.items = []
          self.selection.removeAll()
          self.browserNavigationToRestore = nil
          self.browserRootPath = nil
          self.browserCache.removeAll()
          self.browserLoading.removeAll()
          self.reloadViews()
        }
      }
    }
    queue.addOperation(operation)
  }
  func filterItems() {
    let query = searchField.stringValue
    queryLabel.stringValue = query.isEmpty ? "" : "筛选：" + query
    queryLabel.toolTip = recursive ? "包含子目录" : "当前目录"
    items =
      query.isEmpty ? allItems : allItems.filter { $0.name.localizedCaseInsensitiveContains(query) }
    if state.current.mode != .columns {
      selection = selection.intersection(Set(items.map(\.url)))
    }
    sortItems()
  }
  func sortItems() {
    items = FileItem.sorted(items, by: state.current.sort, descending: state.current.descending)
    reloadViews()
  }
  func reloadViews() {
    let navigation = state.current.mode == .columns ? captureBrowserNavigation() : nil
    if state.current.mode != .columns { selection.formIntersection(Set(items.map(\.url))) }
    if state.current.mode == .gallery, selection.isEmpty,
      let first = items.first(where: {
        !$0.isDirectory
          && UTType(filenameExtension: $0.url.pathExtension)?.conforms(to: .image) == true
      }) ?? items.first(where: { !$0.isDirectory }) ?? items.first
    {
      selection = [first.url]
    }
    let savedSelection = selection
    isReloadingViews = true
    table.reloadData()
    table.selectRowIndexes(
      IndexSet(items.indices.filter { savedSelection.contains(items[$0].url) }),
      byExtendingSelection: false)
    collection.reloadData()
    collection.selectionIndexPaths = Set(
      items.indices.filter { savedSelection.contains(items[$0].url) }.map {
        IndexPath(item: $0, section: 0)
      })
    browserCache[currentURL.path] = items.map(BrowserNode.init)
    selection = savedSelection
    if let navigation {
      browserNavigationToRestore = navigation
      browserRootPath = currentURL.path
      browserTabID = state.current.id
      browser.loadColumnZero()
      restoreBrowserNavigation()
    }
    isReloadingViews = false
    selectionDidChange()
  }
  private func captureBrowserNavigation() -> BrowserNavigation {
    if let browserNavigationToRestore { return browserNavigationToRestore }
    guard browserRootPath == currentURL.path, browserTabID == state.current.id else {
      return BrowserNavigation(directories: [], selectedColumn: 0, selection: selection)
    }
    let directories =
      browser.lastColumn > 0
      ? (1...browser.lastColumn).compactMap {
        (browser.parentForItems(inColumn: $0) as? BrowserNode)?.item.url
      } : []
    return BrowserNavigation(
      directories: directories, selectedColumn: browser.selectedColumn, selection: selection)
  }
  private func restoreBrowserNavigation() {
    guard let navigation = browserNavigationToRestore, state.current.mode == .columns else {
      return
    }
    restoringBrowser = true
    defer { restoringBrowser = false }
    var parent = currentURL
    for (column, directory) in navigation.directories.enumerated() {
      guard let children = browserCache[parent.path] else { return }
      guard let row = children.firstIndex(where: { $0.item.url == directory && $0.item.isFolder })
      else {
        browserNavigationToRestore = nil
        updateBrowserSelection()
        return
      }
      browser.selectRow(row, inColumn: column)
      parent = directory
      if browserCache[parent.path] == nil {
        updateBrowserSelection()
        return  // The asynchronous child read resumes restoration after populating its cache.
      }
    }
    let column = navigation.selectedColumn
    if column >= 0, column <= browser.lastColumn {
      let parent =
        (browser.parentForItems(inColumn: column) as? BrowserNode)?.item.url ?? currentURL
      let children = browserCache[parent.path] ?? []
      let indexes = IndexSet(
        children.indices.filter { navigation.selection.contains(children[$0].item.url) })
      browser.selectRowIndexes(indexes, inColumn: column)
    }
    browserNavigationToRestore = nil
    updateBrowserSelection()
  }
  private func updateBrowserSelection() {
    guard browserNavigationToRestore == nil else {
      selection.removeAll()
      return
    }
    let column = browser.selectedColumn
    selection =
      column < 0
      ? []
      : Set(
        (browser.selectedRowIndexes(inColumn: column) ?? []).compactMap {
          (browser.item(atRow: $0, inColumn: column) as? BrowserNode)?.item.url
        })
  }
  private func updateStatus() {
    let query = searchField.stringValue
    searchScopeRow.isHidden = query.isEmpty
    searchScope.selectedSegment = recursive ? 1 : 0
    queryLabel.stringValue = query.isEmpty ? "" : "筛选：" + query
    queryLabel.toolTip = recursive ? "包含子目录" : "当前目录"
    let restoringColumns = state.current.mode == .columns && browserNavigationToRestore != nil
    loadingIndicator.isHidden = !(isLoading || restoringColumns)
    if isLoading || restoringColumns {
      loadingIndicator.startAnimation(nil)
    } else {
      loadingIndicator.stopAnimation(nil)
    }
    emptyState.isHidden = !items.isEmpty
    emptyLabel.isHidden = !items.isEmpty
    emptyDetail.isHidden = true
    emptyActions.isHidden = isLoading || !items.isEmpty
    emptySecondary.isHidden = readError == nil || currentURL.path == "/"
    if isLoading {
      let message = recursive && !query.isEmpty ? "正在搜索子目录…" : "正在读取…"
      countLabel.stringValue = message
      emptyLabel.stringValue = message
      emptyIcon.image = symbol("folder")
      return
    }
    if restoringColumns {
      countLabel.stringValue = "正在恢复分栏…"
      return
    }
    if let readError {
      countLabel.stringValue = "位置不可用"
      emptyLabel.stringValue = "无法读取此位置"
      emptyDetail.stringValue = readError
      emptyDetail.isHidden = false
      emptyPrimary.title = "重试"
      emptyPrimary.setAccessibilityLabel(emptyPrimary.title)
      emptyIcon.image = symbol("exclamationmark.folder") ?? symbol("folder")
      return
    }
    emptyLabel.stringValue = query.isEmpty ? "这个文件夹为空" : "没有符合“\(query)”的文件"
    emptyPrimary.title = query.isEmpty ? "新建文件夹…" : "清除搜索"
    emptyPrimary.setAccessibilityLabel(emptyPrimary.title)
    emptyIcon.image = symbol(query.isEmpty ? "folder" : "magnifyingglass")
    if !query.isEmpty {
      emptyDetail.stringValue = "试试其他关键词，或清除搜索。"
      emptyDetail.isHidden = false
    }
    var displayedItems = items
    if state.current.mode == .columns, browser.lastColumn >= 0 {
      let column = max(0, browser.selectedColumn >= 0 ? browser.selectedColumn : browser.lastColumn)
      let parent =
        (browser.parentForItems(inColumn: column) as? BrowserNode)?.item.url ?? currentURL
      displayedItems = browserCache[parent.path]?.map(\.item) ?? []
    }
    let size = displayedItems.filter { selection.contains($0.url) && !$0.isFolder }.reduce(Int64(0))
    {
      $0 + $1.size
    }
    countLabel.stringValue =
      "\(displayedItems.count) 项"
      + (selection.isEmpty
        ? "" : " · 已选 \(selection.count) 项 · \(bytesFormatter.string(fromByteCount: size))")
      + (skippedLocations > 0 ? " · \(skippedLocations) 个位置不可访问" : "")
  }
  private static func directoryErrorMessage(_ error: Error) -> String {
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain {
      switch nsError.code {
      case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
        return "文件夹可能已移动或删除，请返回上一级查找。"
      case NSFileReadNoPermissionError:
        return "没有读取权限，请检查文件夹权限或系统隐私设置后重试。"
      case NSFileReadInvalidFileNameError:
        return "目录路径无效，请检查路径后重试。"
      default: break
      }
    }
    return "请检查磁盘或网络连接后重试，也可以返回上一级。"
  }
  func selectionDidChange() {
    guard !isReloadingViews else { return }
    updateStatus()
    syncQuickLookSelection()
    if state.current.mode == .gallery {
      let selected = selectedURLs.first.flatMap { url in items.first { $0.url == url } }
      if let selected, !selected.isFolder {
        if UTType(filenameExtension: selected.url.pathExtension)?.conforms(to: .image) == true {
          showGalleryImage(selected)
        } else {
          cancelGalleryImage()
          galleryImage.isHidden = true
          galleryImage.image = nil
          galleryPlaceholder.isHidden = true
          galleryPreview.isHidden = false
          galleryPreview.previewItem = selected.url as NSURL
        }
      } else {
        cancelGalleryImage()
        galleryImage.isHidden = true
        galleryImage.image = nil
        galleryPreview.previewItem = nil
        galleryPreview.isHidden = true
        galleryPlaceholder.isHidden = items.isEmpty
        galleryIcon.image = symbol("folder")
        galleryTitle.stringValue =
          selected?.name ?? (items.isEmpty ? emptyLabel.stringValue : "选择文件以预览")
        galleryHint.stringValue =
          selected != nil
          ? "双击打开文件夹，或选择其他文件预览。"
          : (emptyDetail.isHidden ? "" : emptyDetail.stringValue)
        galleryHint.isHidden = galleryHint.stringValue.isEmpty
      }
    }
    if owner?.workspace.active == id { owner?.selectionChanged() }
  }
  private func cancelGalleryImage() {
    if let galleryImageRequest { QLThumbnailGenerator.shared.cancel(galleryImageRequest) }
    galleryImageRequest = nil
    galleryImageURL = nil
    galleryImageLoading = false
  }
  private func showGalleryImage(_ item: FileItem) {
    guard galleryImageURL != item.url else { return }
    cancelGalleryImage()
    galleryImageURL = item.url
    galleryImageLoading = true
    galleryPreview.previewItem = nil
    galleryPreview.isHidden = true
    galleryImage.image = nil
    galleryImage.isHidden = true
    galleryImage.toolTip = item.url.path
    galleryImage.setAccessibilityLabel(item.name)
    galleryPlaceholder.isHidden = false
    galleryIcon.image = symbol("photo")
    galleryTitle.stringValue = "正在载入预览…"
    galleryHint.stringValue = item.name
    galleryHint.isHidden = false
    let request = QLThumbnailGenerator.Request(
      fileAt: item.url, size: NSSize(width: 1200, height: 900), scale: 2,
      representationTypes: [.thumbnail])
    galleryImageRequest = request
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] result, _ in
      DispatchQueue.main.async {
        guard let self, self.galleryImageRequest === request,
          self.state.current.mode == .gallery, self.selectedURLs.first == item.url
        else { return }
        self.galleryImageRequest = nil
        self.galleryImageLoading = false
        if let result {
          self.galleryImage.image = result.nsImage
          self.galleryImage.isHidden = false
          self.galleryPlaceholder.isHidden = true
        } else {
          self.galleryTitle.stringValue = item.name
          self.galleryHint.stringValue = "暂时无法生成预览，可双击使用默认应用打开。"
        }
      }
    }
  }
  func startWatching() {
    watch?.cancel()
    watch = nil
    let descriptor = open(currentURL.path, O_EVTONLY)
    guard descriptor >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .attrib], queue: .main)
    source.setEventHandler { [weak self] in
      self?.searchTimer?.invalidate()
      self?.searchTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) {
        [weak self] _ in self?.refresh()
      }
    }
    source.setCancelHandler { close(descriptor) }
    source.resume()
    watch = source
  }
  func stop() {
    cancelGalleryImage()
    queue.cancelAllOperations()
    generation = UUID()
    watch?.cancel()
    watch = nil
    searchTimer?.invalidate()
    if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().dataSource === self {
      quickLookURLs = []
      QLPreviewPanel.shared().orderOut(nil)
    }
  }
  deinit {
    if let galleryImageRequest { QLThumbnailGenerator.shared.cancel(galleryImageRequest) }
    watch?.cancel()
    queue.cancelAllOperations()
  }
  @objc func doubleClick() { openSelected() }
  func openSelected() {
    for url in selectedURLs {
      if let item = try? FileItem(url: url), item.isFolder {
        navigate(url)
        break
      } else {
        NSWorkspace.shared.open(url)
      }
    }
  }
  func selectAll() {
    if state.current.mode == .columns {
      guard browserNavigationToRestore == nil else { return }
      browser.selectAll(nil)
      updateBrowserSelection()
      selectionDidChange()
      return
    }
    selection = Set(items.map(\.url))
    table.selectAll(nil)
    collection.selectionIndexPaths = Set(items.indices.map { IndexPath(item: $0, section: 0) })
    selectionDidChange()
  }
  func handleKey(_ event: NSEvent) -> Bool {
    owner?.activate(id)
    if event.modifierFlags.contains(.command) {
      switch event.keyCode {
      case 126:
        navigate(currentURL.deletingLastPathComponent())
        return true
      case 125:
        openSelected()
        return true
      default: break
      }
      if event.charactersIgnoringModifiers == "[" {
        back()
        return true
      }
      if event.charactersIgnoringModifiers == "]" {
        forward()
        return true
      }
    } else {
      switch event.keyCode {
      case 49:
        quickLook()
        return true
      case 36:
        owner?.rename()
        return true
      default: break
      }
    }
    return false
  }
  func quickLook() {
    if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible,
      QLPreviewPanel.shared().dataSource === self
    {
      QLPreviewPanel.shared().orderOut(nil)
      focusFiles()
      return
    }
    quickLookURLs = selectedURLs
    guard !quickLookURLs.isEmpty else { return }
    focusFiles()
    let panel = QLPreviewPanel.shared()!
    panel.dataSource = self
    panel.delegate = self
    panel.makeKeyAndOrderFront(nil)
    panel.reloadData()
  }
  private func syncQuickLookSelection() {
    guard browserNavigationToRestore == nil, QLPreviewPanel.sharedPreviewPanelExists() else {
      return
    }
    let panel = QLPreviewPanel.shared()!
    guard panel.isVisible,
      panel.dataSource === self || (owner?.workspace.active == id && owner?.app.active === owner)
    else { return }
    quickLookURLs = selectedURLs
    if quickLookURLs.isEmpty {
      panel.orderOut(nil)
    } else {
      panel.dataSource = self
      panel.delegate = self
      panel.reloadData()
    }
  }
  override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }
  override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
    quickLookURLs = selectedURLs
    panel.dataSource = self
    panel.delegate = self
  }
  override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
    guard panel.dataSource === self else { return }
    panel.dataSource = nil
    panel.delegate = nil
  }
  func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { quickLookURLs.count }
  func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
    quickLookURLs[index] as NSURL
  }
  func contextMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    var entries: [(String, String)]
    if selection.isEmpty {
      entries = [
        ("新建文件夹…", "newFolder"), ("粘贴到此处", "paste"), ("移动已复制文件到此处", "movePaste"),
        ("-", ""), ("刷新", "refresh"),
        (state.current.showHidden ? "隐藏隐藏文件" : "显示隐藏文件", "hidden"),
        ("-", ""), ("复制文件夹路径", "copyPath"), ("在 Finder 中显示", "finder"),
        ("在终端中打开", "terminal"),
      ]
    } else {
      entries = [("打开", "open")]
      if selection.count == 1, let url = selectedURLs.first,
        (try? FileItem(url: url))?.isFolder == true
      {
        entries += [("在新标签中打开", "openTab"), ("在新分栏中打开", "openPane")]
      }
      entries += [
        ("快速预览", "preview"), ("-", ""), ("复制", "copy"), ("复制到…", "copyTo"), ("移动到…", "moveTo"),
        ("-", ""), (selection.count == 1 ? "重命名…" : "批量重命名…", "rename"),
        ("加入收集篮", "basketAdd"),
      ]
      if selection.count == 1 { entries.append(("加入书签…", "bookmark")) }
      entries += [("复制路径", "copyPath"), ("在 Finder 中显示", "finder"), ("-", ""), ("移入废纸篓", "trash")]
    }
    for (title, cmd) in entries {
      if title == "-" {
        menu.addItem(.separator())
        continue
      }
      let item = NSMenuItem(title: title, action: #selector(contextAction(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = cmd
      if cmd == "paste" || cmd == "movePaste" {
        item.isEnabled = NSPasteboard.general.canReadObject(
          forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      }
      menu.addItem(item)
    }
    return menu
  }
  @objc func contextAction(_ sender: NSMenuItem) {
    owner?.activate(id)
    switch sender.representedObject as? String {
    case "open": openSelected()
    case "openTab": if let url = selectedURLs.first { addTab(path: url.path) }
    case "openPane": if let url = selectedURLs.first { owner?.openPath(url, newPane: true) }
    default: owner?.command(sender.representedObject as? String ?? "")
    }
  }
  func showPaneMenu() {
    owner?.activate(id)
    let menu = NSMenu()
    for (title, cmd) in [
      ("编辑路径…", "editPath"), ("添加标签", "newTab"), ("关闭当前标签", "closeTab"), ("复制此目录窗口", "addPane"),
      ("左右分割", "splitH"),
      ("上下分割", "splitV"), ("放大／还原", "focus"), ("保存当前搜索…", "saveSearch"), ("显示／隐藏隐藏文件", "hidden"),
    ] {
      let item = NSMenuItem(title: title, action: #selector(contextAction(_:)), keyEquivalent: "")
      item.target = self
      item.representedObject = cmd
      menu.addItem(item)
    }
    let separate = NSMenuItem(title: "移到独立主窗口", action: #selector(detachPane), keyEquivalent: "")
    separate.target = self
    menu.addItem(separate)
    menu.popUp(
      positioning: nil, at: NSPoint(x: header.bounds.width - 24, y: header.bounds.height),
      in: header)
  }
  @objc func detachPane() {
    guard let owner else { return }
    var detached = state
    detached.tabs[detached.selectedTab].path = operationDirectoryURL.path
    var w = Workspace(name: "独立工作台", paths: [operationDirectoryURL.path])
    w.panes = [detached]
    w.active = id
    owner.app.openWindow(workspace: w)
    if owner.workspace.panes.count > 1 { owner.closePane(id) }
  }
  func saveSearch() {
    let query = searchField.stringValue
    guard !query.isEmpty else {
      owner?.setStatus("先输入搜索词，再保存搜索。")
      return
    }
    askText("保存搜索", value: query, detail: "保存搜索范围和关键词，每次打开重新查询。", window: owner?.window) {
      [weak self] name in
      guard let self, let name, let owner = self.owner else { return }
      owner.app.state.searches.append(
        SavedSearch(name: name, root: self.currentURL.path, query: query, recursive: self.recursive)
      )
      owner.app.refreshShared()
    }
  }
  func runSearch(_ saved: SavedSearch) {
    navigate(URL(fileURLWithPath: saved.root))
    recursive = saved.recursive
    scopeButton.state = recursive ? .on : .off
    searchField.stringValue = saved.query
    refresh()
  }
  func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int {
    let url = (item as? BrowserNode)?.item.url ?? currentURL
    if let cached = browserCache[url.path] { return cached.count }
    if !browserLoading.contains(url.path) {
      browserLoading.insert(url.path)
      let token = generation
      let hidden = state.current.showHidden
      queue.addOperation { [weak self] in
        let result = Result {
          try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey],
            options: hidden ? [] : [.skipsHiddenFiles]
          ).compactMap { try? FileItem(url: $0) }
        }
        DispatchQueue.main.async {
          guard let self, self.generation == token else { return }
          self.browserLoading.remove(url.path)
          switch result {
          case .success(let files):
            self.browserCache[url.path] = FileItem.sorted(files, by: .name, descending: false).map(
              BrowserNode.init)
          case .failure(let error):
            self.browserCache[url.path] = []
            self.owner?.setStatus(error.localizedDescription)
          }
          self.isReloadingViews = true
          for column in 0...max(0, browser.lastColumn) {
            let parent =
              (browser.parentForItems(inColumn: column) as? BrowserNode)?.item.url
              ?? self.currentURL
            if parent == url { browser.reloadColumn(column) }
          }
          if self.state.current.mode == .columns {
            self.restoreBrowserNavigation()
            self.updateBrowserSelection()
          }
          self.isReloadingViews = false
          if self.state.current.mode == .columns { self.selectionDidChange() }
        }
      }
    }
    return 0
  }
  func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any {
    browserCache[((item as? BrowserNode)?.item.url ?? currentURL).path]![index]
  }
  func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool {
    !((item as? BrowserNode)?.item.isFolder ?? true)
  }
  func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? {
    (item as? BrowserNode)?.item.name
  }
  @objc func browserSelected() {
    guard state.current.mode == .columns, !restoringBrowser, !isReloadingViews else { return }
    browserNavigationToRestore = nil
    owner?.activate(id)
    updateBrowserSelection()
    selectionDidChange()
  }
  @objc func browserOpened() { openSelected() }
  func browser(
    _ browser: NSBrowser, writeRowsWith rowIndexes: IndexSet, inColumn column: Int,
    to pasteboard: NSPasteboard
  ) -> Bool {
    let urls = rowIndexes.compactMap {
      (browser.item(atRow: $0, inColumn: column) as? BrowserNode)?.item.url as NSURL?
    }
    return pasteboard.writeObjects(urls)
  }
  func browserDestination(row: Int, column: Int) -> URL {
    if row >= 0, let node = browser.item(atRow: row, inColumn: column) as? BrowserNode,
      node.item.isFolder
    {
      return node.item.url
    }
    return (browser.parentForItems(inColumn: max(0, column)) as? BrowserNode)?.item.url
      ?? currentURL
  }
  func browser(
    _ browser: NSBrowser, validateDrop info: NSDraggingInfo,
    proposedRow row: UnsafeMutablePointer<Int>, column: UnsafeMutablePointer<Int>,
    dropOperation: UnsafeMutablePointer<NSBrowser.DropOperation>
  ) -> NSDragOperation {
    let target = browserDestination(row: row.pointee, column: column.pointee)
    if row.pointee >= 0,
      let node = browser.item(atRow: row.pointee, inColumn: column.pointee) as? BrowserNode,
      !node.item.isFolder
    {
      row.pointee = -1
    }
    dropOperation.pointee = .on
    return FileDrop.operation(info, to: target)
  }
  func browser(
    _ browser: NSBrowser, acceptDrop info: NSDraggingInfo, atRow row: Int, column: Int,
    dropOperation: NSBrowser.DropOperation
  ) -> Bool {
    guard let owner else { return false }
    return FileDrop.receive(info, to: browserDestination(row: row, column: column), owner: owner)
  }
}
