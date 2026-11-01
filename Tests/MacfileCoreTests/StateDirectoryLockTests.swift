import Foundation
import MacfileCore

func runStateLockProbeIfRequested() {
  guard CommandLine.arguments.count == 3,
    CommandLine.arguments[1] == "--probe-state-lock"
  else { return }
  do {
    let lock = try StateDirectoryLock(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
    withExtendedLifetime(lock) { exit(0) }
  } catch StateDirectoryLockError.alreadyRunning { exit(73) } catch { exit(74) }
}

extension CoreTests {
  private func probeStateLock(_ directory: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--probe-state-lock", directory.path]
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
  }

  func testStateDirectoryLockExcludesOtherProcesses() throws {
    let directory = root.appendingPathComponent("state")
    var lock: StateDirectoryLock? = try StateDirectoryLock(directory: directory)
    try withExtendedLifetime(lock) {
      checkEqual(try probeStateLock(directory), 73)
      let alias = root.appendingPathComponent("state-alias")
      try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: directory)
      checkEqual(try probeStateLock(alias), 73)
      checkEqual(try probeStateLock(root.appendingPathComponent("separate-state")), 0)
    }
    lock = nil
    checkEqual(try probeStateLock(directory), 0, "退出后遗留锁文件不应阻止下次启动")
  }

  func testStateDirectoryLockFailsSafely() throws {
    let occupied = try file("not-a-directory", "keep")
    checkThrowsError(try StateDirectoryLock(directory: occupied))
    checkEqual(try text(occupied), "keep")
    let target = try file("must-not-overwrite", "keep")
    let directory = root.appendingPathComponent("state")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      at: directory.appendingPathComponent(".instance.lock"), withDestinationURL: target)
    checkThrowsError(try StateDirectoryLock(directory: directory))
    checkEqual(try text(target), "keep")
  }
}
