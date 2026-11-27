// swift-tools-version: 6.0
// Tuinstra Meatproxy (D45): native Apple apps that show your Claude and ChatGPT/Codex work, and your Dark Software
// Factories, as a campus and an orbit. Approved by a human. Reviewed by nobody.
// This package is the Mac app: the collector, the shared model and the two worlds, Office and Orbit (SpriteKit).
// The model, the collector and the command line (meatproxy-core) build on macOS, Linux and Windows; the worlds and
// the app only on macOS.
import PackageDescription

var products: [Product] = [
    .executable(name: "meatproxy-core", targets: ["meatproxy-core"]),
]
let dependencies: [Package.Dependency] = [
    // the terminal in the app (D57): a real VT100/xterm emulator with a local pseudo-terminal, MIT licensed.
    // Only the Mac app uses it, but it is named on every platform: a build on Linux would otherwise remove
    // Package.resolved, and with it the versions the Mac app is built from.
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.2"),
]
var targets: [Target] = [
    // The model and the world grammar, shared by every platform (D13, D24).
    .target(name: "FactoryCore"),
    // Reads the providers' own session files, on every platform (D8, D17).
    .target(name: "FactoryCollector", dependencies: ["FactoryCore"]),
    // Meatproxy without a window: what the collector sees, the costs, the ops tool and the heartbeat, on every platform.
    .executableTarget(name: "meatproxy-core", dependencies: ["FactoryCore", "FactoryCollector"], path: "Sources/MeatproxyCore"),
    .testTarget(name: "FactoryCollectorTests", dependencies: ["FactoryCollector", "FactoryCore"]),
    .testTarget(name: "FactoryCoreTests", dependencies: ["FactoryCore"]),
]

// SpriteKit, SwiftUI and AppKit only exist on Apple's platforms. The manifest runs on the machine that builds, so this
// asks where the build runs.
#if os(macOS)
products.append(.executable(name: "Meatproxy", targets: ["Meatproxy"]))
targets += [
    // The worlds, rendered with SpriteKit (D13). The model does not know about the renderer.
    .target(name: "FactoryScenes", dependencies: ["FactoryCore"], resources: [.copy("Art")]),
    // the Mac app; its brand assets (the app icon) ship as resources
    .executableTarget(name: "Meatproxy", dependencies: ["FactoryCore", "FactoryCollector", "FactoryScenes", .product(name: "SwiftTerm", package: "SwiftTerm")],
                      resources: [.copy("Brand")]),
    .testTarget(name: "FactoryScenesTests", dependencies: ["FactoryScenes", "FactoryCore"]),
]
#endif

let package = Package(
    name: "Meatproxy",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v5]
)
