// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "LocalTranslate", platforms: [.macOS(.v14)], products: [.executable(name: "LocalTranslate", targets: ["LocalTranslate"])], targets: [.executableTarget(name: "LocalTranslate"), .testTarget(name: "LocalTranslateTests", dependencies: ["LocalTranslate"])], swiftLanguageModes: [.v5])
