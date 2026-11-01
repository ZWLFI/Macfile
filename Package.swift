// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Macfile",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "Macfile", targets: ["Macfile"])],
  targets: [
    .target(name: "MacfileCore"),
    .executableTarget(name: "Macfile", dependencies: ["MacfileCore"]),
    .executableTarget(
      name: "MacfileCoreTests", dependencies: ["MacfileCore"], path: "Tests/MacfileCoreTests"),
  ]
)
