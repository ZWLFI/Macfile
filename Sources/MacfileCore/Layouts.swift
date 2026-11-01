import Foundation

public struct LayoutPreset: Identifiable {
  public var id: String
  public var name: String
  public var count: Int
  public var rects: [Rect]
  public init(id: String, name: String, count: Int, rects: [Rect]) {
    self.id = id
    self.name = name
    self.count = count
    self.rects = rects
  }
  public static func grid(count: Int, columns: Int) -> [Rect] {
    let cols = max(1, min(count, columns))
    let rows = Int(ceil(Double(count) / Double(cols)))
    return (0..<count).map { i in
      let row = i / cols
      let rowCount = min(cols, count - row * cols)
      return Rect(
        Double(i % cols) / Double(rowCount), Double(row) / Double(rows), 1 / Double(rowCount),
        1 / Double(rows))
    }
  }
  public static let all: [LayoutPreset] = {
    var output: [LayoutPreset] = []
    for n in 2...12 {
      for cols in 1...n {
        output.append(
          LayoutPreset(
            id: "grid-\(n)-\(cols)", name: "\(n) 窗口 · \(cols) 列平铺", count: n,
            rects: grid(count: n, columns: cols)))
      }
      for side in 0..<4 {
        for portion in [0.4, 0.6, 0.7] {
          let rest = 1 - portion
          var rects: [Rect] = []
          if side < 2 {
            rects.append(Rect(side == 0 ? 0 : rest, 0, portion, 1))
            rects += (0..<n - 1).map {
              Rect(side == 0 ? portion : 0, Double($0) / Double(n - 1), rest, 1 / Double(n - 1))
            }
          } else {
            rects.append(Rect(0, side == 2 ? 0 : rest, 1, portion))
            rects += (0..<n - 1).map {
              Rect(Double($0) / Double(n - 1), side == 2 ? portion : 0, 1 / Double(n - 1), rest)
            }
          }
          output.append(
            LayoutPreset(
              id: "lead-\(n)-\(side)-\(portion)",
              name: "\(n) 窗口 · \(["左","右","上","下"][side])侧主区 \(Int(portion*100))%", count: n,
              rects: rects))
        }
      }
    }
    var seen = Set<String>()
    return output.filter { p in
      let key = p.rects.map {
        String(format: "%.3f,%.3f,%.3f,%.3f", $0.x, $0.y, $0.width, $0.height)
      }.sorted().joined(separator: ";")
      return seen.insert(key).inserted
    }
  }()
  public func tree(ids: [UUID]) -> SplitNode? {
    guard ids.count == rects.count else { return nil }
    func build(_ indexes: [Int], _ r: Rect) -> SplitNode? {
      if indexes.count == 1 { return .leaf(ids[indexes[0]]) }
      for horizontal in [true, false] {
        let cuts = Set(indexes.map { horizontal ? rects[$0].x : rects[$0].y }).sorted()
        for cut in cuts {
          let start = horizontal ? r.x : r.y
          let size = horizontal ? r.width : r.height
          guard cut > start + 0.0001 && cut < start + size - 0.0001 else { continue }
          let left = indexes.filter {
            horizontal
              ? rects[$0].x + rects[$0].width <= cut + 0.0001
              : rects[$0].y + rects[$0].height <= cut + 0.0001
          }
          let right = indexes.filter {
            horizontal ? rects[$0].x >= cut - 0.0001 : rects[$0].y >= cut - 0.0001
          }
          guard !left.isEmpty, !right.isEmpty, left.count + right.count == indexes.count else {
            continue
          }
          let f = (cut - start) / size
          let ra =
            horizontal ? Rect(r.x, r.y, size * f, r.height) : Rect(r.x, r.y, r.width, size * f)
          let rb =
            horizontal
            ? Rect(cut, r.y, size * (1 - f), r.height) : Rect(r.x, cut, r.width, size * (1 - f))
          if let a = build(left, ra), let b = build(right, rb) {
            return .split(horizontal: horizontal, fraction: f, first: a, second: b)
          }
        }
      }
      return nil
    }
    return build(Array(ids.indices), Rect(0, 0, 1, 1))
  }
}

public struct RenameRule: Codable, Equatable, Identifiable {
  public var id = UUID()
  public var name = "重命名规则"
  public var find = ""
  public var replacement = ""
  public var regex = false
  public var prefix = ""
  public var suffix = ""
  public var number = false
  public var start = 1
  public var digits = 3
  public var includeExtension = false
  public init() {}
  public func result(for url: URL, index: Int) throws -> String {
    let ext = url.pathExtension
    var stem =
      includeExtension || ext.isEmpty
      ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    if !find.isEmpty {
      if regex {
        let re = try NSRegularExpression(pattern: find)
        stem = re.stringByReplacingMatches(
          in: stem, range: NSRange(stem.startIndex..., in: stem), withTemplate: replacement)
      } else {
        stem = stem.replacingOccurrences(of: find, with: replacement)
      }
    }
    stem =
      prefix + stem + suffix
      + (number ? String(format: "%0*d", min(10, max(1, digits)), start + index) : "")
    let result = stem + (!includeExtension && !ext.isEmpty ? "." + ext : "")
    guard !result.isEmpty, result != ".", result != "..", !result.contains("/"),
      !result.contains(":"), !result.contains("\0"), result.utf8.count <= 255
    else { throw FileOperationError.invalidName(result) }
    return result
  }
}
