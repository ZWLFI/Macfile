import AppKit
import MacfileCore
import QuickLookThumbnailing

enum FileDrop {
  static let types: [NSPasteboard.PasteboardType] =
    [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
  static func urls(_ info: NSDraggingInfo) -> [URL] {
    (info.draggingPasteboard.readObjects(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
  }
  static func operation(
    _ info: NSDraggingInfo, to target: URL, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags
  ) -> NSDragOperation {
    if modifiers.contains(.option) {
      return info.draggingSourceOperationMask.contains(.copy) ? .copy : []
    }
    let sources = urls(info)
    if !sources.isEmpty, let device = try? FileIdentity(target.resolvingSymlinksInPath()).device,
      sources.allSatisfy({ (try? FileIdentity($0).device) == device }),
      info.draggingSourceOperationMask.contains(.move)
    {
      return .move
    }
    return info.draggingSourceOperationMask.contains(.copy) ? .copy : []
  }
  static func receive(_ info: NSDraggingInfo, to target: URL, owner: WorkspaceController) -> Bool {
    guard !operation(info, to: target).isEmpty else { return false }
    let sourceURLs = urls(info)
    let move = operation(info, to: target) == .move
    if !sourceURLs.isEmpty {
      owner.transfer(sourceURLs, to: target, move: move)
      return true
    }
    guard
      let promises = info.draggingPasteboard.readObjects(
        forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
      !promises.isEmpty
    else { return false }
    let queue = OperationQueue()
    queue.maxConcurrentOperationCount = 2
    for promise in promises {
      let staging = owner.app.support.appendingPathComponent("Incoming/" + UUID().uuidString)
      do {
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
      } catch {
        showError(error, window: owner.window)
        continue
      }
      promise.receivePromisedFiles(atDestination: staging, options: [:], operationQueue: queue) {
        [weak owner] url, error in
        DispatchQueue.main.async {
          guard let owner else { return }
          if let error {
            showError(error, window: owner.window)
          } else {
            owner.transfer([url], to: target, move: true)
          }
        }
      }
    }
    owner.setStatus("正在接收外部应用提供的文件…")
    return true
  }
}
class FileDropButton: ActionButton {
  weak var workspace: WorkspaceController?
  var destination: URL?
  var receiveReferences: (([URL]) -> Void)?
  var spring: (() -> Void)?
  var timer: Timer?
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    timer?.invalidate()
    if let spring {
      timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { _ in spring() }
    }
    return draggingUpdated(sender)
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    if receiveReferences != nil { return FileDrop.urls(sender).isEmpty ? [] : .copy }
    guard let destination else { return [] }
    return FileDrop.operation(sender, to: destination)
  }
  override func draggingExited(_ sender: NSDraggingInfo?) { timer?.invalidate() }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    timer?.invalidate()
    if let receiveReferences {
      let urls = FileDrop.urls(sender)
      guard !urls.isEmpty else { return false }
      receiveReferences(urls)
      return true
    }
    guard let destination, let workspace else { return false }
    return FileDrop.receive(sender, to: destination, owner: workspace)
  }
}
final class FileScrollView: NSScrollView {
  weak var pane: PaneController?
  override func tile() {
    super.tile()
    pane?.fitColumns()
  }
}
final class FileTable: NSTableView {
  weak var pane: PaneController?
  override func keyDown(with event: NSEvent) {
    if pane?.handleKey(event) == true { return }
    super.keyDown(with: event)
  }
  override func mouseDown(with event: NSEvent) {
    if let pane { pane.owner?.activate(pane.id) }
    super.mouseDown(with: event)
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    let row = row(at: convert(event.locationInWindow, from: nil))
    if row >= 0 && !selectedRowIndexes.contains(row) {
      selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    } else if row < 0 {
      deselectAll(nil)
    }
    if let pane { pane.owner?.activate(pane.id) }
    return pane?.contextMenu()
  }
}
final class FileCollection: NSCollectionView {
  weak var pane: PaneController?
  override func keyDown(with event: NSEvent) {
    if pane?.handleKey(event) == true { return }
    super.keyDown(with: event)
  }
  override func mouseDown(with event: NSEvent) {
    if let pane { pane.owner?.activate(pane.id) }
    super.mouseDown(with: event)
    if event.clickCount == 2 {
      openDoubleClickedItem(at: convert(event.locationInWindow, from: nil))
    }
  }
  func openDoubleClickedItem(at point: NSPoint) {
    guard let path = indexPathForItem(at: point), selectionIndexPaths.contains(path) else { return }
    pane?.openSelected()
  }
  override func menu(for event: NSEvent) -> NSMenu? {
    if let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)),
      !selectionIndexPaths.contains(path)
    {
      selectionIndexPaths = [path]
      pane?.collectionSelectionChanged()
    } else if indexPathForItem(at: convert(event.locationInWindow, from: nil)) == nil {
      selectionIndexPaths = []
      pane?.collectionSelectionChanged()
    }
    if let pane { pane.owner?.activate(pane.id) }
    return pane?.contextMenu()
  }
}
final class FileTileBackground: NSView {
  var selected = false { didSet { needsDisplay = true } }
  override func draw(_ dirtyRect: NSRect) {
    guard selected else { return }
    let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    NSColor.controlAccentColor.withAlphaComponent(dark ? 0.22 : 0.10).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}
final class FileTile: NSCollectionViewItem {
  let icon = NSImageView()
  let name = NSTextField(wrappingLabelWithString: "")
  let detail = label("", size: 11, color: .secondaryLabelColor)
  var url: URL?
  var request: QLThumbnailGenerator.Request?
  var iconHeight: NSLayoutConstraint?
  override func loadView() {
    view = FileTileBackground()
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.imageAlignment = .alignCenter
    name.alignment = .center
    name.font = .systemFont(ofSize: 13)
    name.maximumNumberOfLines = 2
    name.lineBreakMode = .byWordWrapping
    name.cell?.truncatesLastVisibleLine = true
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    detail.alignment = .center
    for child in [icon, name, detail] {
      view.addSubview(child)
      child.translatesAutoresizingMaskIntoConstraints = false
      child.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6).isActive = true
      child.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6).isActive = true
    }
    icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 6).isActive = true
    name.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 4).isActive = true
    detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 3).isActive = true
    iconHeight = icon.heightAnchor.constraint(equalToConstant: 48)
    iconHeight?.isActive = true
    icon.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    name.heightAnchor.constraint(equalToConstant: 32).isActive = true
    detail.heightAnchor.constraint(equalToConstant: 15).isActive = true
  }
  override var isSelected: Bool {
    didSet {
      (view as? FileTileBackground)?.selected = isSelected
      name.textColor = isSelected ? .controlAccentColor : .labelColor
      name.font = .systemFont(ofSize: 13, weight: isSelected ? .medium : .regular)
    }
  }
  func configure(_ item: FileItem, thumbnails: Bool) {
    if let request { QLThumbnailGenerator.shared.cancel(request) }
    request = nil
    url = item.url
    name.stringValue = item.name
    name.toolTip = item.url.path
    detail.stringValue = item.isFolder ? "文件夹" : bytesFormatter.string(fromByteCount: item.size)
    iconHeight?.constant = thumbnails ? 90 : 48
    icon.image = NSWorkspace.shared.icon(forFile: item.url.path)
    view.setAccessibilityElement(true)
    view.setAccessibilityLabel(item.name)
    if thumbnails && !item.isFolder {
      let r = QLThumbnailGenerator.Request(
        fileAt: item.url, size: NSSize(width: 220, height: 180), scale: 2,
        representationTypes: [.thumbnail])
      request = r
      QLThumbnailGenerator.shared.generateBestRepresentation(for: r) { [weak self] result, _ in
        DispatchQueue.main.async {
          guard let self, self.request === r, let result else { return }
          self.icon.image = result.nsImage
        }
      }
    }
  }
  override func prepareForReuse() {
    super.prepareForReuse()
    if let request { QLThumbnailGenerator.shared.cancel(request) }
    request = nil
    url = nil
  }
}

extension PaneController: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int { items.count }
  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard row < items.count else { return nil }
    let item = items[row]
    let id = tableColumn?.identifier.rawValue ?? "name"
    let identifier = NSUserInterfaceItemIdentifier("file-" + id)
    let cell: NSTableCellView
    if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
      cell = reused
    } else {
      cell = NSTableCellView()
      cell.identifier = identifier
      if id == "name" {
        let icon = NSImageView()
        icon.imageScaling = .scaleProportionallyDown
        let text = label("", size: 13)
        let stack = rowStack(icon, text)
        cell.addSubview(stack)
        pin(stack, to: cell, inset: 3)
        cell.textField = text
        cell.imageView = icon
      } else {
        let field = label("", size: 12, color: .secondaryLabelColor)
        field.lineBreakMode = .byTruncatingTail
        if id == "size" { field.alignment = .right }
        cell.addSubview(field)
        field.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
          field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
          field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
          field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
        ])
        cell.textField = field
      }
    }
    if id == "name" {
      cell.textField?.stringValue = item.name
      cell.textField?.toolTip = item.url.path
      cell.imageView?.image = NSWorkspace.shared.icon(forFile: item.url.path)
      cell.toolTip = item.url.path
      return cell
    }
    let text =
      id == "size"
      ? (item.isFolder ? "—" : bytesFormatter.string(fromByteCount: item.size))
      : id == "modified" ? shortDateFormatter.string(from: item.modified) : item.kind
    cell.textField?.stringValue = text
    return cell
  }
  func rowStack(_ icon: NSImageView, _ text: NSTextField) -> NSStackView {
    icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 20).isActive = true
    return row([icon, text], spacing: 7)
  }
  func tableViewSelectionDidChange(_ notification: Notification) {
    guard !isReloadingViews else { return }
    selection = Set(table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].url : nil })
    selectionDidChange()
  }
  func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting?
  {
    guard row < items.count else { return nil }
    return items[row].url as NSURL
  }
  func tableView(
    _ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
  ) {
    guard let descriptor = table.sortDescriptors.first, let key = descriptor.key,
      let sort = FileSort(rawValue: key)
    else { return }
    updateTab {
      $0.sort = sort
      $0.descending = !descriptor.ascending
    }
    sortItems()
  }
  func tableView(
    _ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
    proposedDropOperation operation: NSTableView.DropOperation
  ) -> NSDragOperation {
    let folder = row >= 0 && row < items.count && items[row].isFolder && operation == .on
    table.setDropRow(folder ? row : -1, dropOperation: .on)
    let destination = folder ? items[row].url : currentURL
    let action = FileDrop.operation(info, to: destination)
    owner?.setStatus("\(action == .move ? "移动" : "复制") → \(destination.path)")
    return action
  }
  func tableView(
    _ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
    dropOperation: NSTableView.DropOperation
  ) -> Bool {
    guard let owner else { return false }
    let destination =
      row >= 0 && row < items.count && items[row].isFolder ? items[row].url : currentURL
    return FileDrop.receive(info, to: destination, owner: owner)
  }
}
extension PaneController: NSCollectionViewDataSource, NSCollectionViewDelegate,
  NSCollectionViewDelegateFlowLayout
{
  func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int)
    -> Int
  { items.count }
  func collectionView(
    _ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath
  ) -> NSCollectionViewItem {
    let cell =
      collectionView.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("file"), for: indexPath)
      as! FileTile
    cell.configure(items[indexPath.item], thumbnails: state.current.mode != .icons)
    return cell
  }
  func collectionView(
    _ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>
  ) { collectionSelectionChanged() }
  func collectionView(
    _ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>
  ) { collectionSelectionChanged() }
  func collectionSelectionChanged() {
    guard !isReloadingViews else { return }
    selection = Set(
      collection.selectionIndexPaths.compactMap { $0.item < items.count ? items[$0.item].url : nil }
    )
    selectionDidChange()
  }
  func collectionView(
    _ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath
  ) -> NSPasteboardWriting? { items[indexPath.item].url as NSURL }
  func collectionView(
    _ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
    proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
    dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
  ) -> NSDragOperation {
    let i = (proposedDropIndexPath.pointee as IndexPath).item
    if i < items.count, items[i].isFolder, proposedDropOperation.pointee == .on {
      return FileDrop.operation(draggingInfo, to: items[i].url)
    }
    proposedDropOperation.pointee = .before
    return FileDrop.operation(draggingInfo, to: currentURL)
  }
  func collectionView(
    _ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
    indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation
  ) -> Bool {
    guard let owner else { return false }
    let i = indexPath.item
    return FileDrop.receive(
      draggingInfo,
      to: i < items.count && items[i].isFolder && dropOperation == .on ? items[i].url : currentURL,
      owner: owner)
  }
  func collectionView(
    _ collectionView: NSCollectionView, layout collectionViewLayout: NSCollectionViewLayout,
    sizeForItemAt indexPath: IndexPath
  ) -> NSSize {
    state.current.mode == .icons ? NSSize(width: 105, height: 116) : NSSize(width: 156, height: 164)
  }
}
