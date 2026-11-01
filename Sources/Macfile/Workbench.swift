import AppKit
import MacfileCore

extension NSPasteboard.PasteboardType {
  static let macfilePane = NSPasteboard.PasteboardType("com.macfile.directory-pane")
}
final class LayoutPreview: NSView {
  var rects: [Rect] = [] { didSet { needsDisplay = true } }
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    for (i, r) in rects.enumerated() {
      let frame = NSRect(
        x: CGFloat(r.x) * bounds.width + 2, y: CGFloat(r.y) * bounds.height + 2,
        width: CGFloat(r.width) * bounds.width - 4, height: CGFloat(r.height) * bounds.height - 4)
      (i == 0
        ? NSColor.mfAccent.withAlphaComponent(0.8) : NSColor.mfAccent.withAlphaComponent(0.19))
        .setFill()
      NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3).fill()
    }
  }
}
final class PaneHeader: NSView, NSDraggingSource {
  weak var pane: PaneController?
  var active = false { didSet { needsDisplay = true } }
  override var isFlipped: Bool { true }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
    if active {
      NSColor.controlAccentColor.withAlphaComponent(0.055).setFill()
      bounds.fill()
    }
    NSColor.separatorColor.withAlphaComponent(0.6).setFill()
    let pixel = 1 / (window?.backingScaleFactor ?? 2)
    NSRect(x: 0, y: bounds.height - pixel, width: bounds.width, height: pixel).fill()
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
  override func hitTest(_ point: NSPoint) -> NSView? {
    let local = convert(point, from: superview)
    if bounds.contains(local), local.x < 20 { return self }
    return super.hitTest(point)
  }
  override func mouseDown(with event: NSEvent) {
    guard let pane, let owner = pane.owner else { return }
    owner.activate(pane.id)
    guard !owner.workspace.locked else { return }
    if event.clickCount == 2 {
      owner.toggleFocus(pane.id)
      return
    }
    let initial = event.locationInWindow
    guard let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]),
      next.type == .leftMouseDragged
    else { return }
    if owner.workspace.arrangement == .free {
      let origin = pane.view.frame.origin
      var current: NSEvent? = next
      while let e = current, e.type == .leftMouseDragged {
        let d = NSPoint(x: e.locationInWindow.x - initial.x, y: initial.y - e.locationInWindow.y)
        owner.updateFreeFrame(
          pane.id, origin: NSPoint(x: origin.x + d.x, y: origin.y + d.y), size: nil, commit: false)
        current = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
      }
      owner.finishFreeChange()
    } else {
      let item = NSPasteboardItem()
      item.setString(pane.id.uuidString, forType: .macfilePane)
      let drag = NSDraggingItem(pasteboardWriter: item)
      drag.setDraggingFrame(
        bounds,
        contents: NSImage(size: bounds.size, flipped: false) { rect in
          NSColor.mfAccent.withAlphaComponent(0.6).setFill()
          NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
          return true
        })
      beginDraggingSession(with: [drag], event: next, source: self)
    }
  }
  func draggingSession(
    _ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation { .move }
}
final class ResizeGrip: NSView {
  weak var pane: PaneController?
  override func draw(_ dirtyRect: NSRect) {
    NSColor.tertiaryLabelColor.setStroke()
    let p = NSBezierPath()
    for n in [4, 8, 12] {
      p.move(to: NSPoint(x: bounds.width - CGFloat(n), y: 1))
      p.line(to: NSPoint(x: bounds.width - 1, y: CGFloat(n)))
    }
    p.stroke()
  }
  override func mouseDown(with event: NSEvent) {
    guard let pane, let owner = pane.owner, !owner.workspace.locked,
      owner.workspace.arrangement == .free
    else { return }
    let start = event.locationInWindow
    let size = pane.view.frame.size
    var current = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
    while let e = current, e.type == .leftMouseDragged {
      owner.updateFreeFrame(
        pane.id, origin: nil,
        size: NSSize(
          width: size.width + e.locationInWindow.x - start.x,
          height: size.height + start.y - e.locationInWindow.y), commit: false)
      current = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
    }
    owner.finishFreeChange()
  }
}
final class PaneSurface: NSView {
  weak var pane: PaneController?
  var dropZone: String?
  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    registerForDraggedTypes([.macfilePane] + FileDrop.types)
  }
  required init?(coder: NSCoder) { fatalError() }
  func highlight(_ active: Bool) {
    let floating = pane?.owner?.workspace.arrangement == .free
    layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    layer?.cornerRadius = floating ? 7 : 0
    layer?.borderWidth = floating ? 1 : 0
    layer?.borderColor = NSColor.separatorColor.cgColor
    pane?.header.active = active
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    highlight(pane?.owner?.workspace.active == pane?.id)
  }
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    draggingUpdated(sender)
  }
  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    guard sender.draggingPasteboard.string(forType: .macfilePane) != nil else {
      guard let pane else { return [] }
      return FileDrop.operation(sender, to: pane.currentURL)
    }
    guard pane?.owner?.workspace.locked == false else { return [] }
    let p = convert(sender.draggingLocation, from: nil)
    dropZone =
      p.x < bounds.width * 0.22
      ? "left"
      : p.x > bounds.width * 0.78
        ? "right"
        : p.y < bounds.height * 0.22 ? "top" : p.y > bounds.height * 0.78 ? "bottom" : "center"
    needsDisplay = true
    return .move
  }
  override func draggingExited(_ sender: NSDraggingInfo?) {
    dropZone = nil
    needsDisplay = true
  }
  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer {
      dropZone = nil
      needsDisplay = true
    }
    guard let pane else { return false }
    guard let raw = sender.draggingPasteboard.string(forType: .macfilePane) else {
      guard let owner = pane.owner else { return false }
      return FileDrop.receive(sender, to: pane.currentURL, owner: owner)
    }
    guard let id = UUID(uuidString: raw), id != pane.id else { return false }
    pane.owner?.rearrange(id, relativeTo: pane.id, zone: dropZone ?? "center")
    return true
  }
  override func draw(_ dirtyRect: NSRect) {
    guard let zone = dropZone else { return }
    var r = bounds.insetBy(dx: 3, dy: 3)
    switch zone {
    case "left": r.size.width /= 2
    case "right":
      r.origin.x += r.width / 2
      r.size.width /= 2
    case "top": r.size.height /= 2
    case "bottom":
      r.origin.y += r.height / 2
      r.size.height /= 2
    default: break
    }
    NSColor.mfAccent.withAlphaComponent(0.12).setFill()
    NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
  }
}
final class FlippedSplit: NSSplitView {
  var beginResize: (() -> Void)?
  override var isFlipped: Bool { true }
  override func mouseDown(with event: NSEvent) {
    beginResize?()
    super.mouseDown(with: event)
  }
}
final class SplitHandler: NSObject, NSSplitViewDelegate {
  var onChange: (Double) -> Void
  var ready = false
  var locked: () -> Bool = { false }
  init(onChange: @escaping (Double) -> Void) { self.onChange = onChange }
  func splitViewDidResizeSubviews(_ notification: Notification) {
    guard ready, let s = notification.object as? NSSplitView, s.subviews.count == 2 else { return }
    let length =
      s.isVertical ? s.bounds.width - s.dividerThickness : s.bounds.height - s.dividerThickness
    if length > 0 {
      onChange(
        Double(s.isVertical ? s.subviews[0].frame.width : s.subviews[0].frame.height)
          / Double(length))
    }
  }
  func splitView(
    _ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat { max(proposedMinimumPosition, splitView.isVertical ? 220 : 180) }
  func splitView(
    _ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    min(
      proposedMaximumPosition,
      (splitView.isVertical ? splitView.bounds.width - 220 : splitView.bounds.height - 180))
  }
  func splitView(
    _ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
    forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int
  ) -> NSRect { locked() ? .zero : proposedEffectiveRect }
}
extension SplitNode {
  func changingFraction(at path: [Bool], to fraction: Double) -> SplitNode {
    guard case .split(let h, let f, let a, let b) = self else { return self }
    guard let first = path.first else {
      return .split(horizontal: h, fraction: max(0.02, min(0.98, fraction)), first: a, second: b)
    }
    return .split(
      horizontal: h, fraction: f,
      first: first ? a : a.changingFraction(at: Array(path.dropFirst()), to: fraction),
      second: first ? b.changingFraction(at: Array(path.dropFirst()), to: fraction) : b)
  }
  var minimumSize: NSSize {
    switch self {
    case .leaf: return NSSize(width: 270, height: 240)
    case .split(let h, let fraction, let a, let b):
      let x = a.minimumSize
      let y = b.minimumSize
      let f = CGFloat(max(0.02, min(0.98, fraction)))
      return h
        ? NSSize(width: max(x.width / f, y.width / (1 - f)) + 8, height: max(x.height, y.height))
        : NSSize(width: max(x.width, y.width), height: max(x.height / f, y.height / (1 - f)) + 8)
    }
  }
}
