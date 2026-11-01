import Darwin
import Foundation

public enum StateDirectoryLockError: Error {
  case alreadyRunning(pid: Int32?)
}

/// Held for the process lifetime, before either state or task history is loaded.
public final class StateDirectoryLock {
  private let descriptor: Int32

  public init(directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let path = directory.appendingPathComponent(".instance.lock").path
    let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var keepOpen = false
    defer { if !keepOpen { close(fd) } }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
      let code = errno
      if code == EWOULDBLOCK || code == EAGAIN {
        var bytes = [UInt8](repeating: 0, count: 32)
        let count = pread(fd, &bytes, bytes.count, 0)
        let pid =
          count > 0
          ? Int32(
            String(decoding: bytes.prefix(count), as: UTF8.self)
              .trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        throw StateDirectoryLockError.alreadyRunning(pid: pid)
      }
      throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
    }
    let pid = Array("\(getpid())\n".utf8)
    guard ftruncate(fd, 0) == 0, write(fd, pid, pid.count) == pid.count else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    descriptor = fd
    keepOpen = true
  }

  deinit {
    // Keep the file inode: unlinking would allow a second process to lock a replacement file.
    flock(descriptor, LOCK_UN)
    close(descriptor)
  }
}
