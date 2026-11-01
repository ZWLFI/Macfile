import AppKit
import Darwin

guard CommandLine.arguments.count == 3 else {
  fputs("用法：prepare-install.swift <已签名的新应用> <安装目标>\n", stderr)
  exit(1)
}

let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.macfile.desktop")
  .filter { !$0.isTerminated }
if running.count > 1 {
  fputs("检测到多个 Macfile 实例，安装未开始。请先保留所需工作区并正常退出这些实例，避免旧实例覆盖新状态。\n", stderr)
  exit(1)
}

if !running.isEmpty {
  print("正在请求 Macfile 保存工作区并正常退出…")
  for application in running {
    guard application.terminate() else {
      fputs("Macfile 无法正常退出，本次安装已停止。请完成文件任务并退出后重试。\n", stderr)
      exit(1)
    }
  }
  let deadline = Date().addingTimeInterval(20)
  while running.contains(where: { !$0.isTerminated }), Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
  }
  guard running.allSatisfy(\.isTerminated) else {
    fputs("Macfile 仍在运行，本次安装已停止。请完成文件任务并正常退出后重试。\n", stderr)
    exit(1)
  }
}

// Hold the same lock as the app throughout the replacement, including for CLI-launched instances.
let fm = FileManager.default
let stateDirectory =
  ProcessInfo.processInfo.environment["MACFILE_STATE_DIR"].map {
    URL(fileURLWithPath: $0)
  }
  ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("Macfile")
do {
  try fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
  let descriptor = open(
    stateDirectory.appendingPathComponent(".instance.lock").path,
    O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
  guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  defer { close(descriptor) }
  guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
    fputs("工作区仍由其他 Macfile 进程使用，本次安装已停止。请正常退出该实例后重试。\n", stderr)
    exit(1)
  }
  defer { flock(descriptor, LOCK_UN) }
  let source = URL(fileURLWithPath: CommandLine.arguments[1])
  let destination = URL(fileURLWithPath: CommandLine.arguments[2])
  let backup = destination.deletingLastPathComponent().appendingPathComponent(
    "Macfile-backup-\(Int(Date().timeIntervalSince1970))-\(getpid()).app")
  let hadPrevious = fm.fileExists(atPath: destination.path)
  if hadPrevious { try fm.moveItem(at: destination, to: backup) }
  do {
    try fm.moveItem(at: source, to: destination)
  } catch {
    if hadPrevious { try fm.moveItem(at: backup, to: destination) }
    throw error
  }
} catch {
  fputs("安装失败：\(error.localizedDescription)\n", stderr)
  exit(1)
}
