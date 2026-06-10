@preconcurrency import XCTest
import CmuxSettings
import CmuxSocketControl
import AppKit
import Combine
import CoreText
import WebKit
import Darwin
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif


// MARK: - Ghostty resources environment for launched surfaces
extension GhosttyConfigTests {
    func testLaunchGhosttyResourcesPreferCurrentBundleOverInheritedEnvironment() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-launch-resources-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let inheritedResources = root.appendingPathComponent("inherited/ghostty", isDirectory: true)
        let bundleResources = root.appendingPathComponent("BundleResources", isDirectory: true)
        let bundledGhostty = bundleResources.appendingPathComponent("ghostty", isDirectory: true)
        try fileManager.createDirectory(
            at: inheritedResources.appendingPathComponent("themes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: bundledGhostty.appendingPathComponent("themes", isDirectory: true),
            withIntermediateDirectories: true
        )

        let resolved = cmuxApp.resolvedGhosttyResourcesDirectory(
            currentValue: inheritedResources.path,
            bundleResourceURL: bundleResources,
            ghosttyAppResources: root.appendingPathComponent("missing", isDirectory: true).path,
            fileManager: fileManager
        )

        XCTAssertEqual(resolved, bundledGhostty.path)
    }

    func testLaunchGhosttyResourcesKeepInheritedEnvironmentWhenBundleHasNoResources() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-launch-resource-fallback-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let inheritedResources = root.appendingPathComponent("inherited/ghostty", isDirectory: true)
        let emptyBundleResources = root.appendingPathComponent("BundleResources", isDirectory: true)
        try fileManager.createDirectory(at: inheritedResources, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: emptyBundleResources, withIntermediateDirectories: true)

        let resolved = cmuxApp.resolvedGhosttyResourcesDirectory(
            currentValue: inheritedResources.path,
            bundleResourceURL: emptyBundleResources,
            ghosttyAppResources: root.appendingPathComponent("missing", isDirectory: true).path,
            fileManager: fileManager
        )

        XCTAssertEqual(resolved, inheritedResources.path)
    }

    func testLaunchGhosttyResourcesKeepInheritedEnvironmentWhenBundleLacksThemes() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-launch-incomplete-resource-fallback-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let inheritedResources = root.appendingPathComponent("inherited/ghostty", isDirectory: true)
        let bundleResources = root.appendingPathComponent("BundleResources", isDirectory: true)
        let bundledGhostty = bundleResources.appendingPathComponent("ghostty", isDirectory: true)
        try fileManager.createDirectory(
            at: inheritedResources.appendingPathComponent("themes", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(at: bundledGhostty, withIntermediateDirectories: true)

        let resolved = cmuxApp.resolvedGhosttyResourcesDirectory(
            currentValue: inheritedResources.path,
            bundleResourceURL: bundleResources,
            ghosttyAppResources: root.appendingPathComponent("missing", isDirectory: true).path,
            fileManager: fileManager
        )

        XCTAssertEqual(resolved, inheritedResources.path)
    }

    func testLaunchGhosttyResourcesUseIncompleteBundleOnlyAsLastFallback() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-ghostty-launch-incomplete-resource-last-fallback-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let bundleResources = root.appendingPathComponent("BundleResources", isDirectory: true)
        let bundledGhostty = bundleResources.appendingPathComponent("ghostty", isDirectory: true)
        try fileManager.createDirectory(at: bundledGhostty, withIntermediateDirectories: true)

        let resolved = cmuxApp.resolvedGhosttyResourcesDirectory(
            currentValue: root.appendingPathComponent("missing-inherited", isDirectory: true).path,
            bundleResourceURL: bundleResources,
            ghosttyAppResources: root.appendingPathComponent("missing-app", isDirectory: true).path,
            fileManager: fileManager
        )

        XCTAssertEqual(resolved, bundledGhostty.path)
    }

}
