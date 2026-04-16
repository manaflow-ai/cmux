// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

/// Absolute path so `swift build` can link `-lcef_dll_wrapper` for helper executables (relative `-L` breaks).
private let cefFrameworksDirectory: String = {
    let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    return packageDir.appendingPathComponent("Frameworks", isDirectory: true).path
}()

let package = Package(
    name: "CEFWebView",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "CEFWebView",
            targets: ["CEFWebView"]
        ),
        // Built by SPM for embedding in the host app bundle (see IMPLEMENTATION_GUIDE.md).
        .executable(name: "CEFHelper", targets: ["CEFHelper"]),
        .executable(name: "CEFHelperRenderer", targets: ["CEFHelperRenderer"]),
    ],
    targets: [
        // MARK: - CEFWrapper: ObjC++ bridge to CEF C++ API
        .target(
            name: "CEFWrapper",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../Frameworks/include"),
                .headerSearchPath("../../Frameworks"),
                .unsafeFlags(["-std=c++20"])
            ],
            linkerSettings: [
                .linkedLibrary("cef_dll_wrapper"),
                .linkedFramework("Chromium Embedded Framework")
                // -L for libcef_dll_wrapper.a: SwiftPM resolves when building the package; Xcode apps should
                // set LIBRARY_SEARCH_PATHS to the package Frameworks dir (see WebView/Configuration/Build.xcconfig).
                // Do not add -L../../Frameworks or -rpath here — Xcode forwards unsafeFlags to the app linker
                // with the wrong cwd and duplicates LD_RUNPATH on the app target.
            ]
        ),

        // MARK: - CEFWebView: Swift library target (public API)
        .target(
            name: "CEFWebView",
            dependencies: ["CEFWrapper"],
            swiftSettings: [
                .defaultIsolation(MainActor.self)
            ]
        ),

        // MARK: - CEF subprocess helpers (link CEFWrapper; copy into *.app under Contents/Frameworks/)
        // Helpers embed as …/Frameworks/WebView Helper*.app/Contents/MacOS/WebView Helper; CEF is
        // …/Frameworks/Chromium Embedded Framework.framework (sibling of the helper .app). @rpath
        // from build_cpp.sh points inside that framework — add @loader_path so dyld finds it at runtime.
        // Second rpath keeps `swift build` + run from .build/.../debug/CEFHelper working (Frameworks at repo root).
        .executableTarget(
            name: "CEFHelper",
            dependencies: ["CEFWrapper"],
            path: "Sources/CEFHelper",
            sources: ["main.mm"],
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .unsafeFlags([
                    "-L", cefFrameworksDirectory,
                    "-F", cefFrameworksDirectory,
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../..",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../Frameworks",
                ]),
            ]
        ),
        .executableTarget(
            name: "CEFHelperRenderer",
            dependencies: ["CEFWrapper"],
            path: "Sources/CEFHelperRenderer",
            sources: ["main.mm"],
            cxxSettings: [
                .unsafeFlags(["-std=c++20"]),
            ],
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("AppKit"),
                .unsafeFlags([
                    "-L", cefFrameworksDirectory,
                    "-F", cefFrameworksDirectory,
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../..",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../../Frameworks",
                ]),
            ]
        ),

    ],
    swiftLanguageModes: [.v6]
)
