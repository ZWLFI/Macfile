import Foundation
import MacfileCore

final class CoreTests {
  var root: URL!
  var engine: FileOperations!
  func setUpWithError() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Macfile-test-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    engine = try FileOperations(journalDirectory: root.appendingPathComponent("journal"))
    engine.trashHandler = { [root] url in
      let trash = root!.appendingPathComponent("test-trash")
      try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
      let target = FileOperations.uniqueURL(trash.appendingPathComponent(url.lastPathComponent))
      try FileManager.default.moveItem(at: url, to: target)
      return target
    }
  }
  func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
  func file(_ name: String, _ content: String = "data") throws -> URL {
    let u = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(content.utf8).write(to: u)
    return u
  }
  func text(_ url: URL) throws -> String { try String(contentsOf: url) }
  func testCopyPreservesSourceAndVerifiesContent() throws {
    let source = try file("in/a.txt", "original")
    let dest = root.appendingPathComponent("out.txt")
    let receipt = try unwrap(engine.transfer(source, to: dest, kind: .copy, conflict: .ask))
    checkEqual(try text(source), "original")
    checkEqual(try text(dest), "original")
    checkTrue(engine.pending().isEmpty)
    try engine.undo(receipt)
    checkFalse(FileOperations.exists(dest))
    checkTrue(FileOperations.exists(source))
  }
  func testMoveThenUndo() throws {
    let source = try file("move.txt")
    let dest = root.appendingPathComponent("moved.txt")
    let receipt = try unwrap(engine.transfer(source, to: dest, kind: .move, conflict: .ask))
    checkFalse(FileOperations.exists(source))
    try engine.undo(receipt)
    checkTrue(FileOperations.exists(source))
    checkFalse(FileOperations.exists(dest))
  }
  func testDuplicateInSameFolder() throws {
    let source = try file("duplicate.txt", "original")
    checkThrowsError(try engine.transfer(source, to: source, kind: .copy, conflict: .replace))
    let receipt = try unwrap(engine.transfer(source, to: source, kind: .copy, conflict: .keepBoth))
    checkEqual(URL(fileURLWithPath: receipt.destination).lastPathComponent, "duplicate (2).txt")
    checkEqual(try text(source), "original")
    checkEqual(try text(URL(fileURLWithPath: receipt.destination)), "original")
    try engine.undo(receipt)
    checkTrue(FileOperations.exists(source))
  }
  func testReplaceKeepsOriginalAndUndoRestoresBoth() throws {
    let source = try file("src.txt", "new")
    let target = try file("dst.txt", "old")
    let receipt = try unwrap(engine.transfer(source, to: target, kind: .copy, conflict: .replace))
    checkEqual(try text(target), "new")
    checkEqual(try text(URL(fileURLWithPath: unwrap(receipt.backup))), "old")
    try engine.undo(receipt)
    checkEqual(try text(target), "old")
    checkEqual(try text(source), "new")
  }
  func testConflictPolicies() throws {
    let source = try file("in/a.txt", "new")
    let target = try file("a.txt", "old")
    checkThrowsError(try engine.transfer(source, to: target, kind: .copy, conflict: .ask))
    checkNil(try engine.transfer(source, to: target, kind: .copy, conflict: .skip))
    let receipt = try unwrap(engine.transfer(source, to: target, kind: .copy, conflict: .keepBoth))
    checkEqual(URL(fileURLWithPath: receipt.destination).lastPathComponent, "a (2).txt")
    checkEqual(try text(target), "old")
  }
  func testUndoRefusesExternalContentChange() throws {
    let source = try file("a.txt")
    let target = root.appendingPathComponent("b.txt")
    let receipt = try unwrap(engine.transfer(source, to: target, kind: .copy, conflict: .ask))
    try Data("edited".utf8).write(to: target)
    checkThrowsError(try engine.undo(receipt))
    checkEqual(try text(target), "edited")
  }
  func testUndoRefusesRecreatedFileAtSamePath() throws {
    let source = try file("a.txt")
    let target = root.appendingPathComponent("b.txt")
    let receipt = try unwrap(engine.transfer(source, to: target, kind: .copy, conflict: .ask))
    try FileManager.default.moveItem(at: target, to: root.appendingPathComponent("old-b.txt"))
    _ = try file("b.txt")
    checkThrowsError(try engine.undo(receipt))
    checkTrue(FileOperations.exists(target))
  }
  func testRejectsSelfAndDescendantIncludingSymlinkParent() throws {
    let source = try file("folder/a.txt").deletingLastPathComponent()
    checkThrowsError(try engine.transfer(source, to: source, kind: .move, conflict: .replace))
    checkThrowsError(
      try engine.transfer(
        source, to: source.appendingPathComponent("nested"), kind: .copy, conflict: .ask))
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
    checkThrowsError(
      try engine.transfer(
        source, to: alias.appendingPathComponent("nested"), kind: .move, conflict: .ask))
    checkEqual(try text(source.appendingPathComponent("a.txt")), "data")
  }
  func testCopiesSymlinkWithoutFollowingIt() throws {
    let source = root.appendingPathComponent("link")
    let target = root.appendingPathComponent("link-copy")
    try FileManager.default.createSymbolicLink(
      atPath: source.path, withDestinationPath: "does-not-exist")
    _ = try engine.transfer(source, to: target, kind: .copy, conflict: .ask)
    checkEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: target.path), "does-not-exist")
  }
  func testDirectoryCopyPreservesNestedData() throws {
    _ = try file("source/nested/a.txt", "content")
    _ = try file("source/.hidden", "hidden")
    let source = root.appendingPathComponent("source")
    let target = root.appendingPathComponent("copy")
    _ = try engine.transfer(source, to: target, kind: .copy, conflict: .ask)
    checkEqual(try engine.digest(source), try engine.digest(target))
    checkEqual(try text(target.appendingPathComponent(".hidden")), "hidden")
  }
  func testCancellationRollsBackStagingAndPreservesSource() throws {
    let source = try file("source.txt", String(repeating: "data", count: 100))
    let target = root.appendingPathComponent("target.txt")
    var checks = 0
    engine.checkpoint = {
      checks += 1
      if checks >= 6 { throw FileOperationError.cancelled }
    }
    checkThrowsError(try engine.transfer(source, to: target, kind: .move, conflict: .ask))
    checkTrue(FileOperations.exists(source))
    checkFalse(FileOperations.exists(target))
    checkTrue(engine.pending().isEmpty)
  }
  func testRenameSwapAndCycle() throws {
    let a = try file("a.txt", "A")
    let b = try file("b.txt", "B")
    let c = try file("c.txt", "C")
    var receipts: [OperationReceipt] = []
    try engine.renameBatch([(a, "b.txt"), (b, "c.txt"), (c, "a.txt")]) { receipts.append($0) }
    checkEqual(try text(a), "C")
    checkEqual(try text(b), "A")
    checkEqual(try text(c), "B")
    checkEqual(receipts.count, 3)
  }
  func testRenameCollisionMakesNoChanges() throws {
    let a = try file("a.txt", "A")
    let b = try file("b.txt", "B")
    checkThrowsError(
      try engine.renameBatch([(a, "same.txt"), (b, "same.txt")], didComplete: { _ in }))
    checkEqual(try text(a), "A")
    checkEqual(try text(b), "B")
  }
  func testCaseOnlyRename() throws {
    let a = try file("lower.txt")
    try engine.renameBatch([(a, "LOWER.txt")], didComplete: { _ in })
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    checkTrue(names.contains("LOWER.txt"))
    checkFalse(names.contains("lower.txt"))
  }
  func testRenameRulesAndInvalidNames() throws {
    var r = RenameRule()
    r.find = "IMG_"
    r.replacement = ""
    r.prefix = "Photo-"
    r.number = true
    r.digits = 2
    checkEqual(
      try r.result(for: URL(fileURLWithPath: "/IMG_summer.jpg"), index: 2), "Photo-summer03.jpg")
    r.prefix = "../"
    checkThrowsError(try r.result(for: URL(fileURLWithPath: "/a.txt"), index: 0))
    r.prefix = ""
    r.regex = true
    r.find = "["
    checkThrowsError(try r.result(for: URL(fileURLWithPath: "/a.txt"), index: 0))
  }
  func testTrashAndRestoreWithinFixture() throws {
    let source = try file("trash.txt", "saved")
    let receipt = try engine.trash(source)
    checkFalse(FileOperations.exists(source))
    try engine.undo(receipt)
    checkEqual(try text(source), "saved")
  }
  func testCreateFolderUndoRefusesNewContents() throws {
    let dir = root.appendingPathComponent("new")
    let receipt = try engine.createFolder(dir)
    _ = try file("new/added.txt")
    checkThrowsError(try engine.undo(receipt))
    checkTrue(FileOperations.exists(dir))
  }
  func testAllLayoutsCoverSpaceWithoutOverlapAndCanSplit() throws {
    checkGreaterThanOrEqual(LayoutPreset.all.count, 100)
    var unique = Set<String>()
    for p in LayoutPreset.all {
      let sum = p.rects.reduce(0.0) { $0 + $1.width * $1.height }
      checkEqual(sum, 1, accuracy: 0.00001, p.id)
      let ids = (0..<p.count).map { _ in UUID() }
      let tree = try unwrap(p.tree(ids: ids), p.id)
      checkEqual(Set(tree.leaves), Set(ids))
      let result = tree.rectangles(in: Rect(0, 0, 1, 1))
      for (id, rect) in zip(ids, p.rects) {
        let actual = try unwrap(result[id])
        checkEqual(actual.x, rect.x, accuracy: 0.00001, p.id)
        checkEqual(actual.y, rect.y, accuracy: 0.00001, p.id)
        checkEqual(actual.width, rect.width, accuracy: 0.00001, p.id)
        checkEqual(actual.height, rect.height, accuracy: 0.00001, p.id)
      }
      for i in p.rects.indices {
        let a = p.rects[i]
        checkGreaterThan(a.width, 0)
        checkGreaterThan(a.height, 0)
        for j in p.rects.indices where j > i {
          let b = p.rects[j]
          let overlap =
            max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
            * max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
          checkLessThan(overlap, 0.000001, p.id)
        }
      }
      checkTrue(unique.insert(p.id).inserted)
    }
  }
  func testSplitAddRemoveAndStateRoundTrip() throws {
    var state = AppState(home: root)
    let first = state.session.panes[0].id
    let second = state.session.panes[1].id
    state.session.tree = SplitNode.leaf(first).splitting(first, adding: second, horizontal: true)
    state.session.arrangement = .split
    let new = UUID()
    let tree = state.session.tree!.splitting(second, adding: new, horizontal: false)
    checkEqual(tree.leaves.count, 3)
    checkEqual(Set(tree.removing(new)!.leaves), Set([first, second]))
    state.bookmarks = [Bookmark(name: "中文资料", path: root.path)]
    state.basket = ["/some/file"]
    let store = StateStore(url: root.appendingPathComponent("state.json"))
    try store.save(state)
    let restored = try store.load()
    checkEqual(restored.session, state.session)
    checkEqual(restored.bookmarks, state.bookmarks)
    checkEqual(restored.basket, state.basket)
  }
  func testThirtyTwoPaneStateNoHardLimit() throws {
    var workspace = Workspace(name: "32 panes", paths: [root.path])
    for _ in 1..<32 { workspace.panes.append(PaneState(path: root.path)) }
    workspace.normalize()
    checkEqual(workspace.panes.count, 32)
  }
  func testUndoJournalSurvivesRestart() throws {
    let source = try file("source.txt")
    let target = root.appendingPathComponent("target.txt")
    let receipt = try unwrap(engine.transfer(source, to: target, kind: .copy, conflict: .ask))
    try engine.undo(receipt)
    let stored = try JSONDecoder().decode(
      OperationReceipt.self,
      from: Data(
        contentsOf: engine.journalDirectory.appendingPathComponent(
          receipt.id.uuidString + ".receipt")))
    checkTrue(stored.undone)
  }
  func testCopyPreservesPermissionsAndExtendedAttributes() throws {
    let source = try file("meta.txt")
    let target = root.appendingPathComponent("meta-copy.txt")
    try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: source.path)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
    p.arguments = ["-w", "com.macfile.test", "metadata-test", source.path]
    try p.run()
    p.waitUntilExit()
    checkEqual(p.terminationStatus, 0)
    _ = try engine.transfer(source, to: target, kind: .copy, conflict: .ask)
    let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
    checkEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o640)
    let check = Process()
    let pipe = Pipe()
    check.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
    check.arguments = ["-p", "com.macfile.test", target.path]
    check.standardOutput = pipe
    try check.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    check.waitUntilExit()
    checkEqual(
      String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
      "metadata-test")
  }
  func testSourceMutationIsDetectedWithoutDeletingSource() throws {
    let source = try file("changing.txt", "before")
    let target = root.appendingPathComponent("out.txt")
    engine.progress = { message in
      if message.hasPrefix("复制") { try? Data("after".utf8).write(to: source) }
    }
    checkThrowsError(try engine.transfer(source, to: target, kind: .copy, conflict: .ask))
    checkEqual(try text(source), "after")
    checkFalse(FileOperations.exists(target))
  }
  func testCrossVolumeMoveAndUndo() throws {
    guard let mount = ProcessInfo.processInfo.environment["MACFILE_TEST_VOLUME"] else {
      throw TestSkipped(reason: "MACFILE_TEST_VOLUME not set")
    }
    let destDir = URL(fileURLWithPath: mount).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: destDir) }
    let source = try file("cross/a.txt", String(repeating: "验证内容", count: 5000))
      .deletingLastPathComponent()
    checkTrue(try FileIdentity(source).device != FileIdentity(destDir).device)
    let target = destDir.appendingPathComponent("copied")
    let before = try engine.digest(source)
    let receipt = try unwrap(engine.transfer(source, to: target, kind: .move, conflict: .ask))
    checkFalse(FileOperations.exists(source))
    checkEqual(try engine.digest(target), before)
    try engine.undo(receipt)
    checkTrue(FileOperations.exists(source))
    checkFalse(FileOperations.exists(target))
    checkEqual(try engine.digest(source), before)
  }
  func testCrossVolumeMoveThroughSymlinkAndUndo() throws {
    guard let mount = ProcessInfo.processInfo.environment["MACFILE_TEST_VOLUME"] else {
      throw TestSkipped(reason: "MACFILE_TEST_VOLUME not set")
    }
    let destDir = URL(fileURLWithPath: mount).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: destDir) }
    let source = try file("source.txt", "移动前必须完成目标校验")
    let alias = root.appendingPathComponent("destination-link")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: destDir)
    checkEqual(try FileIdentity(source).device, try FileIdentity(alias).device)
    checkTrue(try FileIdentity(source).device != FileIdentity(destDir).device)
    let target = alias.appendingPathComponent("moved.txt")
    var sourcePresentDuringVerification = false
    engine.progress = { message in
      if message.hasPrefix("验证") {
        sourcePresentDuringVerification = FileOperations.exists(source)
      }
    }
    let receipt = try unwrap(engine.transfer(source, to: target, kind: .move, conflict: .ask))
    checkTrue(sourcePresentDuringVerification)
    checkFalse(FileOperations.exists(source))
    checkEqual(try text(target), "移动前必须完成目标校验")
    engine.progress = nil
    try engine.undo(receipt)
    checkTrue(FileOperations.exists(source))
    checkFalse(FileOperations.exists(target))
    checkEqual(try text(source), "移动前必须完成目标校验")
  }
}
