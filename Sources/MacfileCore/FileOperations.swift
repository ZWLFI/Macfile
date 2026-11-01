import CryptoKit
import Darwin
import Foundation

public enum FileOperationError: LocalizedError {
  case invalidName(String)
  case unsafeDestination, sourceChanged
  case conflict(String)
  case changedSinceOperation(String)
  case cancelled
  case unsupported(String)
  public var errorDescription: String? {
    switch self {
    case .invalidName(let name): return "文件名无效：\(name)"
    case .unsafeDestination: return "目标不能是源文件自身或源文件夹内部。"
    case .sourceChanged: return "源文件在操作期间发生变化；已保留源文件，请重新检查。"
    case .conflict(let name): return "目标已有同名项目：\(name)"
    case .changedSinceOperation(let path): return "文件已被修改或替换，无法安全撤销：\(path)"
    case .cancelled: return "任务已取消，已完成的项目仍保留。"
    case .unsupported(let reason): return reason
    }
  }
}
public enum OperationKind: String, Codable {
  case copy, move, rename, trash, createFolder
  public var title: String {
    switch self {
    case .copy: return "复制"
    case .move: return "移动"
    case .rename: return "重命名"
    case .trash: return "移入废纸篓"
    case .createFolder: return "新建文件夹"
    }
  }
}
public enum ConflictPolicy: String, Codable { case ask, keepBoth, replace, skip }
public struct FileIdentity: Codable, Equatable {
  public var device: Int32
  public var inode: UInt64
  public init(_ url: URL) throws {
    var value = stat()
    guard lstat(url.path, &value) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT)
    }
    device = value.st_dev
    inode = value.st_ino
  }
}
public struct OperationReceipt: Codable, Identifiable {
  public var id = UUID()
  public var kind: OperationKind
  public var source: String
  public var destination: String
  public var backup: String?
  public var signature: String
  public var identity: FileIdentity
  public var undone = false
  public var date = Date()
}
public enum TaskStatus: String, Codable {
  case queued, running, paused, completed, partial, failed, cancelled, interrupted, undone
}
public struct TaskRecord: Codable, Identifiable {
  public var id = UUID()
  public var title: String
  public var status: TaskStatus = .queued
  public var total = 0
  public var completed = 0
  public var skipped = 0
  public var current = ""
  public var errors: [String] = []
  public var receipts: [OperationReceipt] = []
  public var date = Date()
  public init(title: String, total: Int) {
    self.title = title
    self.total = total
  }
}
public struct PendingMutation: Codable {
  public var operation: String
  public var source: String
  public var target: String
  public var staging: String?
  public var backup: String?
  public var phase: String
}

public final class FileOperations {
  private let fm = FileManager.default
  public let journalDirectory: URL
  public var trashHandler: ((URL) throws -> URL)?
  public var checkpoint: (() throws -> Void)?
  public var progress: ((String) -> Void)?
  public init(journalDirectory: URL) throws {
    self.journalDirectory = journalDirectory
    try fm.createDirectory(at: journalDirectory, withIntermediateDirectories: true)
  }
  public static func exists(_ url: URL) -> Bool { (try? FileIdentity(url)) != nil }
  public static func uniqueURL(_ proposed: URL) -> URL {
    if !exists(proposed) { return proposed }
    let parent = proposed.deletingLastPathComponent()
    let ext = proposed.pathExtension
    let stem =
      ext.isEmpty ? proposed.lastPathComponent : proposed.deletingPathExtension().lastPathComponent
    var i = 2
    while true {
      let candidate = parent.appendingPathComponent(
        stem + " (\(i))" + (ext.isEmpty ? "" : "." + ext))
      if !exists(candidate) { return candidate }
      i += 1
    }
  }
  private func save(_ record: PendingMutation, to url: URL) throws {
    try JSONEncoder().encode(record).write(to: url, options: .atomic)
  }
  public func pending() -> [PendingMutation] {
    ((try? fm.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "pending" }.compactMap {
        try? JSONDecoder().decode(PendingMutation.self, from: Data(contentsOf: $0))
      }
  }
  private func validate(_ source: URL, _ destination: URL) throws {
    let src = source.standardizedFileURL
    let dst = destination.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(destination.lastPathComponent).standardizedFileURL
    let resolvedSource = source.resolvingSymlinksInPath().standardizedFileURL
    if src == dst || source.standardizedFileURL == destination.standardizedFileURL {
      throw FileOperationError.unsafeDestination
    }
    if let a = try? FileIdentity(source), let b = try? FileIdentity(destination), a == b {
      throw FileOperationError.unsafeDestination
    }
    let attr = try fm.attributesOfItem(atPath: source.path)
    if attr[.type] as? FileAttributeType == .typeDirectory {
      if dst.path == resolvedSource.path || dst.path.hasPrefix(resolvedSource.path + "/") {
        throw FileOperationError.unsafeDestination
      }
    }
    guard FileOperations.exists(dst.deletingLastPathComponent()) else {
      throw CocoaError(.fileNoSuchFile)
    }
  }
  // A content manifest verifies files without following symbolic links or loading whole files into memory.
  public func digest(_ root: URL, metadata: Bool = false) throws -> String {
    var hash = SHA256()
    func add(_ value: String) { hash.update(data: Data((value + "\0").utf8)) }
    func walk(_ url: URL, relative: String) throws {
      try checkpoint?()
      let attrs = try fm.attributesOfItem(atPath: url.path)
      let type = attrs[.type] as? FileAttributeType ?? .typeUnknown
      add(relative)
      add(type.rawValue)
      if metadata {
        add(String(describing: attrs[.posixPermissions] ?? ""))
        add(String(describing: attrs[.modificationDate] ?? ""))
        add(String(describing: attrs[.ownerAccountID] ?? ""))
        add(String(describing: attrs[.groupOwnerAccountID] ?? ""))
        var statValue = stat()
        if lstat(url.path, &statValue) == 0 {
          add("\(statValue.st_ctimespec.tv_sec).\(statValue.st_ctimespec.tv_nsec)")
        }
      }
      if type == .typeSymbolicLink {
        add(try fm.destinationOfSymbolicLink(atPath: url.path))
      } else if type == .typeDirectory {
        for child in try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil).sorted(
          by: { $0.lastPathComponent < $1.lastPathComponent })
        {
          try walk(child, relative: relative + "/" + child.lastPathComponent)
        }
      } else if type == .typeRegular {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
          try checkpoint?()
          hash.update(data: data)
        }
      } else {
        throw FileOperationError.unsupported("暂不操作设备、套接字或管道：\(url.path)")
      }
    }
    try walk(root, relative: "")
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  public func transfer(
    _ source: URL, to requested: URL, kind: OperationKind, conflict: ConflictPolicy,
    recordReceipt: Bool = true
  ) throws -> OperationReceipt? {
    precondition(kind == .copy || kind == .move || kind == .rename)
    try checkpoint?()
    var target = requested
    if Self.exists(target) {
      switch conflict {
      case .skip: return nil
      case .ask: throw FileOperationError.conflict(target.lastPathComponent)
      case .keepBoth: target = Self.uniqueURL(target)
      case .replace: break
      }
    }
    try validate(source, target)
    let journal = journalDirectory.appendingPathComponent(UUID().uuidString + ".pending")
    let staging = target.deletingLastPathComponent().appendingPathComponent(
      ".macfile-" + UUID().uuidString + ".partial")
    let backup =
      Self.exists(target)
      ? target.deletingLastPathComponent().appendingPathComponent(
        ".macfile-" + UUID().uuidString + ".backup") : nil
    var record = PendingMutation(
      operation: kind.rawValue, source: source.path, target: target.path, staging: staging.path,
      backup: backup?.path, phase: "准备")
    try save(record, to: journal)
    let sourceID = try FileIdentity(source)
    var sourceMoved = false
    var targetCommitted = false
    var backupMade = false
    do {
      progress?("校验 \(source.lastPathComponent)")
      let before = try digest(source)
      try checkpoint?()
      let sameVolume =
        sourceID.device
        == (try FileIdentity(target.deletingLastPathComponent().resolvingSymlinksInPath())).device
      if kind != .copy && sameVolume {
        record.phase = "准备移动源到临时位置"
        try save(record, to: journal)
        try fm.moveItem(at: source, to: staging)
        sourceMoved = true
      } else {
        record.phase = "复制到临时位置"
        try save(record, to: journal)
        progress?("复制 \(source.lastPathComponent)")
        try fm.copyItem(at: source, to: staging)
      }
      progress?("验证 \(source.lastPathComponent)")
      guard try digest(staging) == before else { throw FileOperationError.sourceChanged }
      if !sourceMoved {
        guard try FileIdentity(source) == sourceID, try digest(source) == before else {
          throw FileOperationError.sourceChanged
        }
      }
      try checkpoint?()
      if let backup {
        record.phase = "准备保留目标原件"
        try save(record, to: journal)
        try fm.moveItem(at: target, to: backup)
        backupMade = true
      }
      record.phase = "准备提交目标"
      try save(record, to: journal)
      try fm.moveItem(at: staging, to: target)
      targetCommitted = true
      if kind != .copy && !sourceMoved {
        record.phase = "目标已验证，准备删除源"
        try save(record, to: journal)
        guard try FileIdentity(source) == sourceID, try digest(source) == before else {
          throw FileOperationError.sourceChanged
        }
        try fm.removeItem(at: source)
      }
      // Record a receipt before removing the pending intent so crashes remain inspectable.
      let receipt = OperationReceipt(
        kind: kind, source: source.path, destination: target.path, backup: backup?.path,
        signature: try digest(target, metadata: true), identity: try FileIdentity(target))
      if recordReceipt { try saveReceipt(receipt) }
      try fm.removeItem(at: journal)
      return receipt
    } catch {
      // Never delete a committed target: a cross-volume source may already have been removed.
      if !targetCommitted {
        if sourceMoved && Self.exists(staging) && !Self.exists(source) {
          try? fm.moveItem(at: staging, to: source)
        } else if !sourceMoved && Self.exists(staging) {
          try? fm.removeItem(at: staging)
        }
        if backupMade, let backup, !Self.exists(target) { try? fm.moveItem(at: backup, to: target) }
        if !Self.exists(staging), !backupMade || backup.map({ !Self.exists($0) }) == true {
          try? fm.removeItem(at: journal)
        }
      }
      throw error
    }
  }
  private func moveToTrash(_ url: URL) throws -> URL {
    if let trashHandler { return try trashHandler(url) }
    var result: NSURL?
    try fm.trashItem(at: url, resultingItemURL: &result)
    guard let target = result as URL? else {
      throw FileOperationError.unsupported("已移入废纸篓，请通过 Finder 恢复。")
    }
    return target
  }
  public func trash(_ source: URL) throws -> OperationReceipt {
    try checkpoint?()
    _ = try digest(source)
    let journal = journalDirectory.appendingPathComponent(UUID().uuidString + ".pending")
    try save(
      PendingMutation(
        operation: "trash", source: source.path, target: "废纸篓（由系统选择）", phase: "准备移入废纸篓"),
      to: journal)
    let target = try moveToTrash(source)
    let receipt = OperationReceipt(
      kind: .trash, source: source.path, destination: target.path,
      signature: try digest(target, metadata: true), identity: try FileIdentity(target))
    try saveReceipt(receipt)
    try fm.removeItem(at: journal)
    return receipt
  }
  public func saveReceipt(_ receipt: OperationReceipt) throws {
    try JSONEncoder().encode(receipt).write(
      to: journalDirectory.appendingPathComponent(receipt.id.uuidString + ".receipt"),
      options: .atomic)
  }
  public func markUndone(_ receipt: OperationReceipt) throws {
    var updated = receipt
    updated.undone = true
    try saveReceipt(updated)
  }
  public func createFolder(_ target: URL) throws -> OperationReceipt {
    guard !Self.exists(target) else { throw FileOperationError.conflict(target.lastPathComponent) }
    try fm.createDirectory(at: target, withIntermediateDirectories: false)
    let receipt = OperationReceipt(
      kind: .createFolder, source: "", destination: target.path,
      signature: try digest(target, metadata: true), identity: try FileIdentity(target))
    try saveReceipt(receipt)
    return receipt
  }
  public func undo(_ receipt: OperationReceipt) throws {
    let target = URL(fileURLWithPath: receipt.destination)
    let source = URL(fileURLWithPath: receipt.source)
    guard !receipt.undone, try FileIdentity(target) == receipt.identity,
      try digest(target, metadata: true) == receipt.signature
    else { throw FileOperationError.changedSinceOperation(receipt.destination) }
    if receipt.kind != .copy && receipt.kind != .createFolder && Self.exists(source) {
      throw FileOperationError.conflict(source.lastPathComponent)
    }
    let journal = journalDirectory.appendingPathComponent(UUID().uuidString + ".pending")
    try save(
      PendingMutation(
        operation: "undo", source: target.path, target: source.path, backup: receipt.backup,
        phase: "准备撤销"), to: journal)
    if receipt.kind == .copy || receipt.kind == .createFolder {
      // Undo copies goes to Trash too, so an interrupted undo does not silently destroy data.
      _ = try moveToTrash(target)
    } else {
      _ = try transfer(target, to: source, kind: .move, conflict: .ask, recordReceipt: false)
    }
    if let backup = receipt.backup { try fm.moveItem(at: URL(fileURLWithPath: backup), to: target) }
    try markUndone(receipt)
    try fm.removeItem(at: journal)
  }
  public func renameBatch(
    _ pairs: [(URL, String)], recordReceipts: Bool = true, didComplete: (OperationReceipt) -> Void
  ) throws {
    let sources = Set(pairs.map { $0.0.standardizedFileURL.path })
    guard sources.count == pairs.count else { throw FileOperationError.unsupported("重命名列表包含重复项目。") }
    var targets = Set<String>()
    for (url, name) in pairs {
      var r = RenameRule()
      r.find = url.lastPathComponent
      r.replacement = name
      r.includeExtension = true
      _ = try r.result(for: url, index: 0)
      let target = url.deletingLastPathComponent().appendingPathComponent(name)
      // Case-folding is conservative on case-sensitive volumes and avoids accidental collisions on default APFS.
      let key = target.path.precomposedStringWithCanonicalMapping.lowercased()
      guard targets.insert(key).inserted else { throw FileOperationError.conflict(name) }
      if Self.exists(target), !sources.contains(target.path),
        (try? FileIdentity(url)) != (try? FileIdentity(target))
      {
        throw FileOperationError.conflict(name)
      }
    }
    var staged: [(URL, URL, URL)] = []
    let journal = journalDirectory.appendingPathComponent(UUID().uuidString + ".rename-pending")
    let moves = pairs.filter { $0.0.lastPathComponent != $0.1 }.map {
      (
        $0.0,
        $0.0.deletingLastPathComponent().appendingPathComponent(
          ".macfile-" + UUID().uuidString + ".rename"),
        $0.0.deletingLastPathComponent().appendingPathComponent($0.1)
      )
    }
    try JSONEncoder().encode(moves.map { [$0.0.path, $0.1.path, $0.2.path] }).write(
      to: journal, options: .atomic)
    do {
      for (source, temp, target) in moves {
        try checkpoint?()
        try fm.moveItem(at: source, to: temp)
        staged.append((source, temp, target))
      }
    } catch {
      for (source, temp, _) in staged.reversed() { try? fm.moveItem(at: temp, to: source) }
      if staged.allSatisfy({ !Self.exists($0.1) }) { try? fm.removeItem(at: journal) }
      throw error
    }
    // Finalization is not interruptible; this keeps name swaps and cycles coherent.
    var committed: [(URL, URL, URL)] = []
    do {
      for (source, temp, target) in staged {
        try fm.moveItem(at: temp, to: target)
        committed.append((source, temp, target))
      }
    } catch {
      for (_, temp, target) in committed.reversed() { try? fm.moveItem(at: target, to: temp) }
      for (source, temp, _) in staged {
        if !Self.exists(source) { try? fm.moveItem(at: temp, to: source) }
      }
      if staged.allSatisfy({ Self.exists($0.0) && !Self.exists($0.1) }) {
        try? fm.removeItem(at: journal)
      }
      throw error
    }
    for (source, _, target) in staged {
      let receipt = OperationReceipt(
        kind: .rename, source: source.path, destination: target.path,
        signature: try digest(target, metadata: true), identity: try FileIdentity(target))
      if recordReceipts { try saveReceipt(receipt) }
      didComplete(receipt)
    }
    try fm.removeItem(at: journal)
  }
}
