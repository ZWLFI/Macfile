import Foundation

public enum ViewMode: String, Codable, CaseIterable {
  case list, icons, thumbnails, columns, gallery
  public var title: String {
    switch self {
    case .list: return "列表"
    case .icons: return "图标"
    case .thumbnails: return "缩略图"
    case .columns: return "分栏"
    case .gallery: return "画廊"
    }
  }
  public var symbol: String {
    switch self {
    case .list: return "list.bullet"
    case .icons: return "square.grid.2x2"
    case .thumbnails: return "photo.on.rectangle"
    case .columns: return "rectangle.split.3x1"
    case .gallery: return "rectangle.bottomthird.inset.filled"
    }
  }
}
public struct FileTab: Codable, Equatable, Identifiable {
  public var id = UUID()
  public var path: String
  public var mode: ViewMode = .list
  public var showHidden = false
  public var sort: FileSort = .name
  public var descending = false
  public init(path: String, mode: ViewMode = .list) {
    self.path = path
    self.mode = mode
  }
}
public enum FileSort: String, Codable, CaseIterable { case name, modified, size, kind }
public struct PaneState: Codable, Equatable, Identifiable {
  public var id = UUID()
  public var tabs: [FileTab]
  public var selectedTab: Int = 0
  public init(path: String) { tabs = [FileTab(path: path)] }
  public var current: FileTab { tabs[min(max(0, selectedTab), tabs.count - 1)] }
}
public struct Rect: Codable, Equatable {
  public var x: Double, y: Double, width: Double, height: Double
  public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}
public indirect enum SplitNode: Codable, Equatable {
  case leaf(UUID)
  case split(horizontal: Bool, fraction: Double, first: SplitNode, second: SplitNode)
  public var leaves: [UUID] {
    switch self {
    case .leaf(let id): return [id]
    case .split(_, _, let a, let b): return a.leaves + b.leaves
    }
  }
  public func splitting(_ id: UUID, adding: UUID, horizontal: Bool) -> SplitNode {
    switch self {
    case .leaf(let existing):
      return existing == id
        ? .split(horizontal: horizontal, fraction: 0.5, first: self, second: .leaf(adding)) : self
    case .split(let h, let f, let a, let b):
      return .split(
        horizontal: h, fraction: f, first: a.splitting(id, adding: adding, horizontal: horizontal),
        second: b.splitting(id, adding: adding, horizontal: horizontal))
    }
  }
  public func removing(_ id: UUID) -> SplitNode? {
    switch self {
    case .leaf(let i): return i == id ? nil : self
    case .split(let h, let f, let a, let b):
      let aa = a.removing(id)
      let bb = b.removing(id)
      if let aa, let bb { return .split(horizontal: h, fraction: f, first: aa, second: bb) }
      return aa ?? bb
    }
  }
  public func replacing(_ a: UUID, with b: UUID) -> SplitNode {
    switch self {
    case .leaf(let i): return .leaf(i == a ? b : i)
    case .split(let h, let f, let x, let y):
      return .split(
        horizontal: h, fraction: f, first: x.replacing(a, with: b), second: y.replacing(a, with: b))
    }
  }
  public func remapping(_ mapping: [UUID: UUID]) -> SplitNode {
    switch self {
    case .leaf(let id): return .leaf(mapping[id] ?? id)
    case .split(let h, let f, let a, let b):
      return .split(
        horizontal: h, fraction: f, first: a.remapping(mapping), second: b.remapping(mapping))
    }
  }
  public func rectangles(in rect: Rect) -> [UUID: Rect] {
    switch self {
    case .leaf(let id): return [id: rect]
    case .split(let h, let fraction, let a, let b):
      let f = min(0.98, max(0.02, fraction))
      let ra =
        h
        ? Rect(rect.x, rect.y, rect.width * f, rect.height)
        : Rect(rect.x, rect.y, rect.width, rect.height * f)
      let rb =
        h
        ? Rect(rect.x + rect.width * f, rect.y, rect.width * (1 - f), rect.height)
        : Rect(rect.x, rect.y + rect.height * f, rect.width, rect.height * (1 - f))
      return a.rectangles(in: ra).merging(b.rectangles(in: rb)) { a, _ in a }
    }
  }
}
public enum Arrangement: String, Codable { case tile, split, free }
public struct Workspace: Codable, Equatable, Identifiable {
  public var id = UUID()
  public var name: String
  public var panes: [PaneState]
  public var active: UUID
  public var arrangement: Arrangement = .tile
  public var columns = 2
  public var tree: SplitNode?
  public var frames: [UUID: Rect] = [:]
  public var locked = false
  public init(name: String, paths: [String]) {
    self.name = name
    panes = (paths.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser.path] : paths).map {
      PaneState(path: $0)
    }
    active = panes[0].id
  }
  public mutating func normalize() {
    if panes.isEmpty {
      panes = [PaneState(path: FileManager.default.homeDirectoryForCurrentUser.path)]
    }
    for i in panes.indices {
      if panes[i].tabs.isEmpty {
        panes[i].tabs = [FileTab(path: FileManager.default.homeDirectoryForCurrentUser.path)]
      }
      panes[i].selectedTab = min(max(0, panes[i].selectedTab), panes[i].tabs.count - 1)
    }
    if !panes.contains(where: { $0.id == active }) { active = panes[0].id }
    columns = max(1, columns)
    if let tree, Set(tree.leaves) != Set(panes.map(\.id)) {
      self.tree = nil
      arrangement = .tile
    }
  }
}
public struct Bookmark: Codable, Equatable, Identifiable {
  public var id = UUID()
  public var name: String
  public var path: String
  public var group: String
  public init(name: String, path: String, group: String = "常用书签") {
    self.name = name
    self.path = path
    self.group = group
  }
}
public struct SavedSearch: Codable, Equatable, Identifiable {
  public var id = UUID()
  public var name: String
  public var root: String
  public var query: String
  public var recursive: Bool
  public init(name: String, root: String, query: String, recursive: Bool) {
    self.name = name
    self.root = root
    self.query = query
    self.recursive = recursive
  }
}
public struct LayoutFavorite: Codable, Identifiable {
  public var id = UUID()
  public var name: String
  public var workspace: Workspace
  public init(name: String, workspace: Workspace) {
    self.name = name
    self.workspace = workspace
  }
}
public struct AppState: Codable {
  public var schema = 1
  public var session: Workspace
  public var sessions: [Workspace]?
  public var workspaces: [Workspace] = []
  public var bookmarks: [Bookmark] = []
  public var basket: [String] = []
  public var searches: [SavedSearch] = []
  public var favorites: [LayoutFavorite] = []
  public var renameRules: [RenameRule] = []
  public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
    session = Workspace(
      name: "我的工作台", paths: [home.path, home.appendingPathComponent("Downloads").path])
  }
}
public struct StateStore {
  public let url: URL
  public init(url: URL) { self.url = url }
  public func load() throws -> AppState {
    var state = try JSONDecoder().decode(AppState.self, from: Data(contentsOf: url))
    guard state.schema == 1 else { throw CocoaError(.fileReadCorruptFile) }
    state.session.normalize()
    return state
  }
  public func save(_ state: AppState) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(state).write(to: url, options: .atomic)
  }
}
public struct FileItem: Identifiable, Hashable {
  public var id: String { url.path }
  public let url: URL
  public let name: String
  public let isDirectory: Bool
  public let isPackage: Bool
  public let isSymlink: Bool
  public let size: Int64
  public let modified: Date
  public init(url: URL) throws {
    let r = try url.resourceValues(forKeys: [
      .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
    ])
    self.url = url
    name = url.lastPathComponent
    isDirectory = r.isDirectory == true
    isPackage = r.isPackage == true
    isSymlink = r.isSymbolicLink == true
    size = Int64(r.fileSize ?? 0)
    modified = r.contentModificationDate ?? .distantPast
  }
  public var isFolder: Bool { isDirectory && !isPackage && !isSymlink }
  public var kind: String {
    isSymlink
      ? "符号链接"
      : isDirectory
        ? (isPackage ? "应用／包" : "文件夹")
        : (url.pathExtension.isEmpty ? "文件" : url.pathExtension.uppercased())
  }
  public static func sorted(_ items: [FileItem], by sort: FileSort, descending: Bool) -> [FileItem]
  {
    items.sorted { a, b in
      if a.isFolder != b.isFolder { return a.isFolder }
      let order: ComparisonResult
      switch sort {
      case .name: order = a.name.localizedStandardCompare(b.name)
      case .kind:
        order =
          a.kind == b.kind
          ? a.name.localizedStandardCompare(b.name) : a.kind.localizedCompare(b.kind)
      case .size:
        order =
          a.size == b.size
          ? a.name.localizedStandardCompare(b.name)
          : a.size < b.size ? .orderedAscending : .orderedDescending
      case .modified:
        order =
          a.modified == b.modified
          ? a.name.localizedStandardCompare(b.name)
          : a.modified < b.modified ? .orderedAscending : .orderedDescending
      }
      return descending ? order == .orderedDescending : order == .orderedAscending
    }
  }
}
