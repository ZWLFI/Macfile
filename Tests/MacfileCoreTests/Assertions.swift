import Foundation

var failures = 0
struct TestSkipped: Error { let reason: String }
func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
  failures += 1
  print("FAIL \(file):\(line): \(message)")
}
func unwrap<T>(
  _ value: T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) throws -> T {
  if let value { return value }
  throw NSError(
    domain: "MacfileTests", code: 1,
    userInfo: [NSLocalizedDescriptionKey: "Missing value: \(message) at \(file):\(line)"])
}
func checkTrue(
  _ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath,
  line: UInt = #line
) {
  do { if try !value() { fail("Expected true. " + message, file: file, line: line) } } catch {
    fail(error.localizedDescription, file: file, line: line)
  }
}
func checkFalse(
  _ value: @autoclosure () throws -> Bool, _ message: String = "", file: StaticString = #filePath,
  line: UInt = #line
) {
  do { if try value() { fail("Expected false. " + message, file: file, line: line) } } catch {
    fail(error.localizedDescription, file: file, line: line)
  }
}
func checkEqual<T: Equatable>(
  _ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "",
  file: StaticString = #filePath, line: UInt = #line
) {
  do {
    let x = try a()
    let y = try b()
    if x != y { fail("\(x) != \(y) " + message, file: file, line: line) }
  } catch { fail(error.localizedDescription, file: file, line: line) }
}
func checkEqual(
  _ a: Double, _ b: Double, accuracy: Double, _ message: String = "",
  file: StaticString = #filePath, line: UInt = #line
) { if abs(a - b) > accuracy { fail("\(a) != \(b) " + message, file: file, line: line) } }
func checkGreaterThan<T: Comparable>(
  _ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) { if a <= b { fail("\(a) <= \(b) " + message, file: file, line: line) } }
func checkGreaterThanOrEqual<T: Comparable>(
  _ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) { if a < b { fail("\(a) < \(b) " + message, file: file, line: line) } }
func checkLessThan<T: Comparable>(
  _ a: T, _ b: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) { if a >= b { fail("\(a) >= \(b) " + message, file: file, line: line) } }
func checkThrowsError<T>(
  _ value: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line
) {
  do {
    _ = try value()
    fail("Expected error", file: file, line: line)
  } catch {}
}
func checkNil<T>(
  _ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line
) {
  do { if try value() != nil { fail("Expected nil", file: file, line: line) } } catch {
    fail(error.localizedDescription, file: file, line: line)
  }
}
