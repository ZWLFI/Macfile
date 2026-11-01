import Darwin
import Foundation
import MacfileCore

extension CoreTests {
  func testCopyMoveUndoChainAfterRestart() throws {
    let source = try file("original.txt", "original")
    let metadata = Array("original metadata".utf8)
    checkEqual(
      metadata.withUnsafeBytes {
        setxattr(
          source.path, "com.macfile.undo-test", $0.baseAddress, metadata.count, 0, XATTR_NOFOLLOW)
      }, 0)
    let permissions = Process()
    permissions.executableURL = URL(fileURLWithPath: "/bin/chmod")
    permissions.arguments = ["+a", "everyone allow read", source.path]
    try permissions.run()
    permissions.waitUntilExit()
    checkEqual(permissions.terminationStatus, 0)
    let copied = root.appendingPathComponent("copy.txt")
    let moved = root.appendingPathComponent("moved.txt")
    let copy = try unwrap(engine.transfer(source, to: copied, kind: .copy, conflict: .ask))
    let move = try unwrap(engine.transfer(copied, to: moved, kind: .move, conflict: .ask))
    checkEqual(move.undoPredecessors?.map(\.receiptID), [copy.id])
    let restarted = try FileOperations(journalDirectory: engine.journalDirectory)
    restarted.trashHandler = engine.trashHandler
    try restarted.undo(move)
    let refreshed = try unwrap(restarted.storedReceipt(copy.id))
    checkEqual(refreshed.identity, try FileIdentity(copied))
    checkEqual(refreshed.signature, try restarted.digest(copied, metadata: true))
    let restartedAgain = try FileOperations(journalDirectory: engine.journalDirectory)
    restartedAgain.trashHandler = engine.trashHandler
    try restartedAgain.undo(copy)
    checkFalse(FileOperations.exists(copied))
    checkFalse(FileOperations.exists(moved))
    checkEqual(try text(source), "original")
  }

  func testUndoChainRefusesExternalChanges() throws {
    let mutations: [(String, (URL) throws -> Void)] = [
      ("content", { try Data("external edit".utf8).write(to: $0) }),
      (
        "permissions",
        { try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: $0.path) }
      ),
      (
        "xattr",
        { url in
          let value = Array("external metadata".utf8)
          let result = value.withUnsafeBytes {
            setxattr(
              url.path, "com.macfile.undo-test", $0.baseAddress, value.count, 0, XATTR_NOFOLLOW)
          }
          guard result == 0 else { throw POSIXError(.EIO) }
        }
      ),
      (
        "acl",
        { url in
          let permissions = Process()
          permissions.executableURL = URL(fileURLWithPath: "/bin/chmod")
          permissions.arguments = ["+a", "everyone allow read", url.path]
          try permissions.run()
          permissions.waitUntilExit()
          guard permissions.terminationStatus == 0 else { throw POSIXError(.EIO) }
        }
      ),
    ]
    for (name, mutate) in mutations {
      for phase in ["before-move", "after-move", "after-undo"] {
        let stem = name + "-" + phase
        let source = try file(stem + "/source", "original")
        let copied = source.deletingLastPathComponent().appendingPathComponent("copy")
        let moved = source.deletingLastPathComponent().appendingPathComponent("moved")
        let copy = try unwrap(engine.transfer(source, to: copied, kind: .copy, conflict: .ask))
        if phase == "before-move" { try mutate(copied) }
        let move = try unwrap(engine.transfer(copied, to: moved, kind: .move, conflict: .ask))
        if phase == "before-move" { checkTrue(move.undoPredecessors?.isEmpty ?? true) }
        if phase == "after-move" {
          try mutate(moved)
          checkThrowsError(try engine.undo(move))
          checkTrue(FileOperations.exists(moved))
        } else {
          try engine.undo(move)
          if phase == "after-undo" { try mutate(copied) }
          checkThrowsError(try engine.undo(copy))
          checkTrue(FileOperations.exists(copied))
        }
      }
    }
  }

  func testUndoChainDoesNotResignMetadataChangedDuringMove() throws {
    let source = try file("source", "original")
    let copied = root.appendingPathComponent("copy")
    let moved = root.appendingPathComponent("moved")
    let copy = try unwrap(engine.transfer(source, to: copied, kind: .copy, conflict: .ask))
    var changed = false
    engine.progress = { [root] message in
      if message.hasPrefix("验证"),
        let partial = try? FileManager.default.contentsOfDirectory(
          at: root!, includingPropertiesForKeys: nil
        ).first(where: { $0.pathExtension == "partial" })
      {
        do {
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o400], ofItemAtPath: partial.path)
          changed = true
        } catch {}
      }
    }
    let move = try unwrap(engine.transfer(copied, to: moved, kind: .move, conflict: .ask))
    engine.progress = nil
    checkTrue(changed)
    try engine.undo(move)
    checkEqual(try unwrap(engine.storedReceipt(copy.id)).signature, copy.signature)
    checkThrowsError(try engine.undo(copy))
    checkTrue(FileOperations.exists(copied))
  }

  func testUndoChainDirectorySymlinkAndTrash() throws {
    let source = try file("source/nested/file.txt", "nested").deletingLastPathComponent()
      .deletingLastPathComponent()
    let link = source.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(
      atPath: link.path, withDestinationPath: "nested/file.txt")
    for kind in ["directory", "symlink", "trash"] {
      let original = kind == "symlink" ? link : source
      let copied = root.appendingPathComponent("copy-" + kind)
      let copy = try unwrap(engine.transfer(original, to: copied, kind: .copy, conflict: .ask))
      let next: OperationReceipt
      if kind == "trash" {
        next = try engine.trash(copied)
      } else {
        next = try unwrap(
          engine.transfer(
            copied, to: root.appendingPathComponent("moved-" + kind), kind: .move, conflict: .ask))
      }
      checkEqual(next.undoPredecessors?.map(\.receiptID), [copy.id], kind)
      try engine.undo(next)
      try engine.undo(copy)
      checkFalse(FileOperations.exists(copied), kind)
    }
    checkEqual(try text(source.appendingPathComponent("nested/file.txt")), "nested")
  }

  func testUndoChainRenameCycleAndReplacement() throws {
    let originalA = try file("source-a", "A")
    let originalB = try file("source-b", "B")
    let a = root.appendingPathComponent("a")
    let b = root.appendingPathComponent("b")
    let copyA = try unwrap(engine.transfer(originalA, to: a, kind: .copy, conflict: .ask))
    let copyB = try unwrap(engine.transfer(originalB, to: b, kind: .copy, conflict: .ask))
    var renames: [OperationReceipt] = []
    try engine.renameBatch([(a, "b"), (b, "a")]) { renames.append($0) }
    try engine.undoRenames(renames)
    checkEqual(try text(a), "A")
    checkEqual(try text(b), "B")
    let replacement = try unwrap(engine.transfer(originalB, to: a, kind: .copy, conflict: .replace))
    try engine.undo(replacement)
    checkEqual(try text(a), "A")
    try engine.undo(copyA)
    try engine.undo(copyB)
    checkFalse(FileOperations.exists(a))
    checkFalse(FileOperations.exists(b))
  }

  func testCrossVolumeUndoChain() throws {
    guard let mount = ProcessInfo.processInfo.environment["MACFILE_TEST_VOLUME"] else {
      throw TestSkipped(reason: "MACFILE_TEST_VOLUME not set")
    }
    let destination = URL(fileURLWithPath: mount).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: destination) }
    let source = try file("original.txt", "cross-volume")
    let copied = root.appendingPathComponent("copy.txt")
    let target = destination.appendingPathComponent("moved.txt")
    checkTrue(try FileIdentity(source).device != FileIdentity(destination).device)
    let copy = try unwrap(engine.transfer(source, to: copied, kind: .copy, conflict: .ask))
    let move = try unwrap(engine.transfer(copied, to: target, kind: .move, conflict: .ask))
    try engine.undo(move)
    try engine.undo(copy)
    checkFalse(FileOperations.exists(copied))
    checkFalse(FileOperations.exists(target))
    checkEqual(try text(source), "cross-volume")
  }
}
