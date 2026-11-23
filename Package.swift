// swift-tools-version: 6.0
import Foundation
import PackageDescription

let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".deps/native").path
let package = Package(
    name: "LocalCaption",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "LocalCaption", targets: ["LocalCaption"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .systemLibrary(name: "CInference"),
        .target(name: "CaptionCore", dependencies: ["CSQLite", "CInference"],
                resources: [.process("Resources")],
                linkerSettings: [.unsafeFlags(["-L", native,
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                    "-Xlinker", "-rpath", "-Xlinker", native])]),
        .executableTarget(name: "LocalCaption", dependencies: ["CaptionCore"]),
        .testTarget(name: "CaptionCoreTests", dependencies: ["CaptionCore"],
                    resources: [.process("Fixtures")]),
        .testTarget(name: "LocalCaptionTests", dependencies: ["LocalCaption", "CaptionCore"])
    ]
)
