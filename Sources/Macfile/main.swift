import AppKit
import MacfileCore

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let instanceLock: StateDirectoryLock
do {
  instanceLock = try StateDirectoryLock(directory: AppDelegate.stateDirectory)
} catch StateDirectoryLockError.alreadyRunning(let pid) {
  if let pid, let running = NSRunningApplication(processIdentifier: pid),
    running.bundleIdentifier == Bundle.main.bundleIdentifier
  {
    running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
  }
  fputs("Macfile 已在使用此工作区，请使用现有窗口。\n", stderr)
  exit(CommandLine.arguments.contains("--ui-test") ? 1 : 0)
} catch {
  let alert = NSAlert()
  alert.messageText = "无法安全打开工作区"
  alert.informativeText = "无法取得工作区锁。未读取或写入会话与任务记录。\n" + error.localizedDescription
  alert.runModal()
  exit(1)
}
let delegate = AppDelegate()
app.delegate = delegate
withExtendedLifetime(instanceLock) { app.run() }
