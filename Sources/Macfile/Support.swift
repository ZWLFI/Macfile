import AppKit
import MacfileCore

extension NSColor {
  static var mfAccent: NSColor { .controlAccentColor }
  static var mfBackground: NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(white: 0.12, alpha: 1)
        : NSColor(srgbRed: 0.95, green: 0.96, blue: 0.975, alpha: 1)
    }
  }
}
final class FlippedView: NSView { override var isFlipped: Bool { true } }
final class FlippedStack: NSStackView { override var isFlipped: Bool { true } }
final class WindowContentView: NSView {
  override func draw(_ dirtyRect: NSRect) {
    NSColor.windowBackgroundColor.setFill()
    dirtyRect.fill()
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }
}
func label(
  _ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular, color: NSColor = .labelColor
) -> NSTextField {
  let v = NSTextField(labelWithString: text)
  v.font = .systemFont(ofSize: size, weight: weight)
  v.textColor = color
  v.lineBreakMode = .byTruncatingMiddle
  return v
}
func symbol(_ name: String) -> NSImage? {
  NSImage(systemSymbolName: name, accessibilityDescription: nil)
}
class ActionButton: NSButton {
  var actionBlock: (() -> Void)?
  init(
    _ title: String = "", symbol name: String? = nil, help: String? = nil,
    action: @escaping () -> Void
  ) {
    super.init(frame: .zero)
    self.title = title
    bezelStyle = .rounded
    controlSize = .regular
    if let name {
      image = symbol(name)
      imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    }
    target = self
    self.action = #selector(invoke)
    actionBlock = action
    toolTip = help ?? title
    setAccessibilityLabel(help ?? title)
  }
  required init?(coder: NSCoder) { fatalError() }
  @objc private func invoke() { actionBlock?() }
}
func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
  let stack = NSStackView(views: views)
  stack.orientation = .horizontal
  stack.spacing = spacing
  stack.alignment = .centerY
  return stack
}
func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
  let stack = NSStackView(views: views)
  stack.orientation = .vertical
  stack.spacing = spacing
  stack.alignment = .leading
  return stack
}
func pin(_ view: NSView, to parent: NSView, inset: CGFloat = 0) {
  view.translatesAutoresizingMaskIntoConstraints = false
  NSLayoutConstraint.activate([
    view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
    view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
    view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
    view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset),
  ])
}
func flexible() -> NSView {
  let v = NSView()
  v.setContentHuggingPriority(.defaultLow, for: .horizontal)
  return v
}
func showError(_ error: Error, window: NSWindow?) {
  let alert = NSAlert()
  alert.messageText = "操作未完成"
  alert.informativeText = error.localizedDescription
  alert.alertStyle = .warning
  if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
}
func askText(
  _ title: String, value: String, detail: String = "", window: NSWindow?,
  completion: @escaping (String?) -> Void
) {
  let alert = NSAlert()
  alert.messageText = title
  alert.informativeText = detail
  alert.addButton(withTitle: "确定")
  alert.addButton(withTitle: "取消")
  let field = NSTextField(string: value)
  field.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
  alert.accessoryView = field
  let finish: (NSApplication.ModalResponse) -> Void = { response in
    completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
  }
  if let window {
    alert.beginSheetModal(for: window, completionHandler: finish)
    alert.window.makeFirstResponder(field)
  } else {
    finish(alert.runModal())
  }
}
let bytesFormatter: ByteCountFormatter = {
  let f = ByteCountFormatter()
  f.countStyle = .file
  return f
}()
let shortDateFormatter: DateFormatter = {
  let f = DateFormatter()
  f.dateStyle = .short
  f.timeStyle = .short
  return f
}()

final class TaskGate {
  let condition = NSCondition()
  private var isPaused = false, isCancelled = false
  func pause(_ value: Bool) {
    condition.lock()
    isPaused = value
    condition.broadcast()
    condition.unlock()
  }
  func cancel() {
    condition.lock()
    isCancelled = true
    condition.broadcast()
    condition.unlock()
  }
  func check() throws {
    condition.lock()
    defer { condition.unlock() }
    while isPaused && !isCancelled { condition.wait() }
    if isCancelled { throw FileOperationError.cancelled }
  }
}
final class TaskCenter {
  var records: [TaskRecord] = []
  var onChange: (() -> Void)?
  let folder: URL
  private let queue = OperationQueue()
  private var gates: [UUID: TaskGate] = [:]
  private let stateURL: URL
  var hasActive: Bool {
    queue.operationCount > 0
      || records.contains { [.queued, .running, .paused].contains($0.status) }
  }
  init(folder: URL) {
    self.folder = folder
    stateURL = folder.appendingPathComponent("tasks.json")
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInitiated
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    records = (try? JSONDecoder().decode([TaskRecord].self, from: Data(contentsOf: stateURL))) ?? []
    for i in records.indices where [.running, .paused, .queued].contains(records[i].status) {
      records[i].status = .interrupted
      records[i].current = "上次运行中断；检查已完成项目后再操作"
    }
    let seen = Set(records.flatMap(\.receipts).map(\.id))
    let journal = folder.appendingPathComponent("journal")
    let journalReceipts =
      ((try? FileManager.default.contentsOfDirectory(at: journal, includingPropertiesForKeys: nil))
      ?? []).filter { $0.pathExtension == "receipt" }.compactMap {
        try? JSONDecoder().decode(OperationReceipt.self, from: Data(contentsOf: $0))
      }
    for receipt in journalReceipts {
      for i in records.indices {
        if let j = records[i].receipts.firstIndex(where: { $0.id == receipt.id }) {
          records[i].receipts[j] = receipt
          if records[i].receipts.allSatisfy(\.undone) { records[i].status = .undone }
        }
      }
    }
    let recovered = journalReceipts.filter { !seen.contains($0.id) && !$0.undone }
      .sorted { $0.date < $1.date }
    if !recovered.isEmpty {
      let legacyRenameGroup = UUID()
      let groups = Dictionary(grouping: recovered) {
        $0.renameBatchID ?? ($0.kind == .rename ? legacyRenameGroup : $0.id)
      }
      for receipts in groups.values {
        var task = TaskRecord(title: "恢复的操作记录 · " + receipts[0].kind.title, total: receipts.count)
        task.status = .interrupted
        task.receipts = receipts
        task.completed = receipts.count
        task.date = receipts.last!.date
        records.append(task)
      }
      records.sort { $0.date > $1.date }
    }
  }
  func changed() {
    do { try JSONEncoder().encode(records).write(to: stateURL, options: .atomic) } catch {
      NSLog("Macfile 任务记录保存失败: %@", error.localizedDescription)
    }
    onChange?()
  }
  private func update(_ id: UUID, _ body: @escaping (inout TaskRecord) -> Void) {
    DispatchQueue.main.async { [weak self] in
      guard let self, let i = self.records.firstIndex(where: { $0.id == id }) else { return }
      body(&self.records[i])
      self.changed()
    }
  }
  func submit(
    id: UUID = UUID(), title: String, total: Int,
    work: @escaping (FileOperations, (OperationReceipt?) -> Void) -> Void
  ) {
    var task = TaskRecord(title: title, total: total)
    task.id = id
    let gate = TaskGate()
    records.insert(task, at: 0)
    gates[id] = gate
    changed()
    queue.addOperation { [weak self] in
      guard let self else { return }
      self.update(id) {
        if $0.status != .paused && $0.status != .cancelled { $0.status = .running }
      }
      do {
        let engine = try FileOperations(
          journalDirectory: self.folder.appendingPathComponent("journal"))
        engine.checkpoint = { try gate.check() }
        engine.progress = { message in self.update(id) { $0.current = message } }
        try gate.check()
        work(engine) { receipt in
          self.update(id) { r in
            if let receipt {
              r.receipts.append(receipt)
              r.completed += 1
            } else {
              r.skipped += 1
            }
          }
        }
        self.update(id) { r in
          if r.status != .cancelled {
            r.status = r.errors.isEmpty ? .completed : (r.completed > 0 ? .partial : .failed)
          }
          if r.title.hasPrefix("撤销："), r.errors.isEmpty { r.completed = r.total }
          r.current =
            r.errors.isEmpty
            ? "已完成 \(r.completed) 项 · 跳过 \(r.skipped) 项" : "\(r.errors.count) 项未完成，请查看明细"
        }
      } catch {
        self.update(id) {
          $0.errors.append(error.localizedDescription)
          if case FileOperationError.cancelled = error {
            $0.status = .cancelled
          } else {
            $0.status = .failed
          }
          $0.current = error.localizedDescription
        }
      }
    }
  }
  func transfer(_ urls: [URL], to destination: URL, move: Bool, conflict: ConflictPolicy) {
    let id = UUID()
    submit(
      id: id, title: "\(move ? "移动" : "复制") \(urls.count) 项 → \(destination.lastPathComponent)",
      total: urls.count
    ) { [weak self] engine, done in
      for url in urls {
        do {
          try engine.checkpoint?()
          done(
            try engine.transfer(
              url, to: destination.appendingPathComponent(url.lastPathComponent),
              kind: move ? .move : .copy, conflict: conflict))
        } catch {
          self?.update(id) {
            $0.errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
          }
          if case FileOperationError.cancelled = error { break }
        }
      }
    }
  }
  func perform(
    title: String, total: Int,
    operation: @escaping (FileOperations, (OperationReceipt) -> Void) throws -> Void
  ) {
    let id = UUID()
    submit(id: id, title: title, total: total) { [weak self] engine, done in
      do { try operation(engine) { done($0) } } catch {
        self?.update(id) { $0.errors.append(error.localizedDescription) }
      }
    }
  }
  func pause(_ id: UUID) {
    guard
      let i = records.firstIndex(where: {
        $0.id == id && [.queued, .running, .paused].contains($0.status)
      }), let gate = gates[id]
    else { return }
    let pause = records[i].status != .paused
    gate.pause(pause)
    records[i].status = pause ? .paused : .running
    records[i].current = pause ? "在安全检查点暂停；正在复制的单个文件会先完成" : "继续执行"
    changed()
  }
  func cancel(_ id: UUID) {
    guard
      records.contains(where: { $0.id == id && [.queued, .running, .paused].contains($0.status) })
    else { return }
    gates[id]?.cancel()
    if let i = records.firstIndex(where: { $0.id == id }) {
      records[i].status = .cancelled
      records[i].current = "正在取消，已完成项目保留"
    }
    changed()
  }
  func undo(_ id: UUID) {
    guard let task = records.first(where: { $0.id == id }), !hasActive else { return }
    let receipts = task.receipts.filter { !$0.undone }
    guard !receipts.isEmpty else { return }
    perform(title: "撤销：" + task.title, total: receipts.count) { [weak self] engine, _ in
      let receiptIDs = Set(receipts.map(\.id))
      let hasDependencies = receipts.contains { receipt in
        receipt.undoPredecessors?.contains { receiptIDs.contains($0.receiptID) } == true
      }
      if receipts.allSatisfy({ $0.kind == .rename }) && !hasDependencies {
        self?.mergeReceipts(try engine.undoRenames(receipts))
      } else {
        for receipt in receipts.reversed() {
          self?.mergeReceipts(try engine.undo(receipt))
        }
      }
    }
  }
  private func mergeReceipts(_ receipts: [OperationReceipt]) {
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      for receipt in receipts {
        for i in self.records.indices {
          if let j = self.records[i].receipts.firstIndex(where: { $0.id == receipt.id }) {
            self.records[i].receipts[j] = receipt
            if self.records[i].receipts.allSatisfy(\.undone) { self.records[i].status = .undone }
          }
        }
      }
      self.changed()
    }
  }
}
