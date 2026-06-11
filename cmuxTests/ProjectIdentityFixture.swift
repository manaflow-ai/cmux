import AppKit
import Foundation

/// Creates a temporary project root directory containing an `AppIcon.appiconset`
/// with a real PNG image and a matching `Contents.json`. Used by app-target tests
/// that need a well-formed project tree to exercise `SidebarProjectIdentityCache`
/// and related types.
///
/// Each helper is a free file-private function, matching the pattern used in
/// `AgentExecutableResolverTests.swift`.

/// Returns a temporary project root whose `lastPathComponent` equals `name` and
/// whose `App/Assets.xcassets/AppIcon.appiconset/` contains a solid-red PNG icon
/// and a corresponding `Contents.json`.
func makeRootWithRedIcon(named name: String) throws -> URL {
    let tempParent = FileManager.default.temporaryDirectory
        .appendingPathComponent("ProjectIdentityFixture-\(UUID().uuidString)", isDirectory: true)
    let root = tempParent.appendingPathComponent(name, isDirectory: true)
    let set = root.appendingPathComponent(
        "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

    // Write a real 32×32 red PNG so NSImage + AverageColor work end-to-end.
    let iconURL = set.appendingPathComponent("icon.png")
    try writeSolidColorPNG(.red, to: iconURL, side: 32)

    let contents = """
    {"images":[{"size":"1024x1024","scale":"1x","filename":"icon.png"}],"info":{"version":1,"author":"xcode"}}
    """
    try contents.write(
        to: set.appendingPathComponent("Contents.json"),
        atomically: true,
        encoding: .utf8)

    return root
}

/// Removes the temporary directory tree created by `makeRootWithRedIcon(named:)`.
/// Silently ignores errors (the directory may already have been removed).
func cleanupProjectIdentityFixture(_ root: URL) {
    // Remove the parent temp directory (one level above the named root).
    let parent = root.deletingLastPathComponent()
    try? FileManager.default.removeItem(at: parent)
}

// MARK: - Private helpers

private func writeSolidColorPNG(_ color: NSColor, to url: URL, side: Int) throws {
    let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
        color.setFill()
        rect.fill()
        return true
    }
    var rect = NSRect(x: 0, y: 0, width: side, height: side)
    guard
        let cgImage = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    else {
        throw FixtureError.cgImageUnavailable
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw FixtureError.pngRepresentationFailed
    }
    try pngData.write(to: url)
}

private enum FixtureError: Error {
    case cgImageUnavailable
    case pngRepresentationFailed
}
