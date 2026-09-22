// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "vdisplay",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "vdisplay", targets: ["vdisplay"])],
    targets: [
        .target(name: "VirtualDisplayBridge", cSettings: [.unsafeFlags(["-fobjc-arc"])],
                linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("CoreGraphics")]),
        .target(name: "DisplayCore"),
        .executableTarget(name: "vdisplay", dependencies: ["DisplayCore", "VirtualDisplayBridge"],
                          linkerSettings: [.linkedFramework("SystemConfiguration")]),
        .testTarget(name: "DisplayCoreTests", dependencies: ["DisplayCore"])
    ]
)
