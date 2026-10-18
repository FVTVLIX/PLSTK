// swift-tools-version: 6.0
// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 FVTVLIX and PLSTK contributors.

import PackageDescription

let package = Package(
    name: "PLSTK",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PLSTK", targets: ["LocalVideoEditor"]),
        .executable(name: "local-video", targets: ["LocalVideoCLI"])
    ],
    targets: [
        .target(name: "LocalVideoCore"),
        .executableTarget(name: "LocalVideoEditor", dependencies: ["LocalVideoCore"]),
        .executableTarget(name: "LocalVideoCLI", dependencies: ["LocalVideoCore"]),
        .testTarget(name: "LocalVideoCoreTests", dependencies: ["LocalVideoCore"]),
        .testTarget(name: "LocalVideoEditorTests", dependencies: ["LocalVideoEditor", "LocalVideoCore"])
    ],
    swiftLanguageModes: [.v5]
)
