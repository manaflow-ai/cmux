#!/usr/bin/env swift
// Regenerates the checked-in Computer Use helper icon and SVG.
//
// The artwork geometry lives in the CmuxComputerUseVisuals SwiftPM target,
// which is also imported by the app renderer. This wrapper keeps the historic
// script entry point while delegating generation to that shared contract.

import Foundation

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let packageRoot = repoRoot
    .appendingPathComponent("Packages/macOS/CmuxComputerUseVisuals", isDirectory: true)
let iconURL = repoRoot.appendingPathComponent(
    "Resources/ComputerUseHelperIcon.icns",
    isDirectory: false
)
let svgURL = repoRoot.appendingPathComponent(
    "Resources/ComputerUseHelperIcon.svg",
    isDirectory: false
)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
process.arguments = [
    "swift",
    "run",
    "--package-path",
    packageRoot.path,
    "GenerateComputerUseHelperIcon",
    "--output",
    iconURL.path,
    "--svg-output",
    svgURL.path,
]
process.currentDirectoryURL = packageRoot

do {
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        exit(process.terminationStatus)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}
