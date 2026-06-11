import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

import CmuxProjectIdentity

// MARK: - SidebarWorkspaceDisplayName

/// The sidebar row's primary name defaults to the project folder name and is
/// overridden by a user rename (custom title), falling back to the legacy
/// workspace title only when neither is available.
@Test func displayNameUsesFolderNameWhenNoCustomTitle() {
    #expect(
        SidebarWorkspaceDisplayName.resolve(
            customTitle: nil, folderName: "my-project", fallbackTitle: "zsh"
        ) == "my-project")
}

@Test func displayNamePrefersCustomTitleOverFolderName() {
    #expect(
        SidebarWorkspaceDisplayName.resolve(
            customTitle: "Renamed", folderName: "my-project", fallbackTitle: "zsh"
        ) == "Renamed")
}

@Test func displayNameTreatsBlankCustomTitleAsAbsent() {
    #expect(
        SidebarWorkspaceDisplayName.resolve(
            customTitle: "   ", folderName: "my-project", fallbackTitle: "zsh"
        ) == "my-project")
}

@Test func displayNameFallsBackToTitleWhenNoFolderName() {
    #expect(
        SidebarWorkspaceDisplayName.resolve(
            customTitle: nil, folderName: nil, fallbackTitle: "zsh"
        ) == "zsh")
}

@MainActor
@Test func resolvedIdentityResolvesAndStoresIdentity() async throws {
    let root = try makeRootWithRedIcon(named: "cmux")
    defer { cleanupProjectIdentityFixture(root) }

    let cache = SidebarProjectIdentityCache(
        resolver: ProjectIdentityResolver(fileManager: .default))

    // Await the test-seam helper: resolves and stores synchronously.
    let identity = await cache.resolvedIdentity(forProjectRoot: root.path)
    #expect(identity.projectName == "cmux")

    // After resolution, the pure accessor should return the cached value.
    #expect(cache.cachedIdentity(forProjectRoot: root.path)?.projectName == "cmux")
}

/// `cachedIdentity(forProjectRoot:)` is a pure read: it returns `nil` on a miss
/// and must NOT schedule any resolution (so it is safe to call from a SwiftUI
/// `body`). We assert nothing ever lands after a quiet period.
@MainActor
@Test func cachedIdentityIsPureReadAndDoesNotResolve() async throws {
    let root = try makeRootWithRedIcon(named: "cmux")
    defer { cleanupProjectIdentityFixture(root) }

    let cache = SidebarProjectIdentityCache(
        resolver: ProjectIdentityResolver(fileManager: .default))

    #expect(cache.cachedIdentity(forProjectRoot: root.path) == nil)
    // Give any (erroneously) scheduled resolve time to land.
    try await Task.sleep(nanoseconds: 50_000_000)
    #expect(cache.cachedIdentity(forProjectRoot: root.path) == nil)
}

/// `requestIdentity(forProjectRoot:)` schedules off-main resolution; afterwards
/// the pure accessor returns the stored value.
@MainActor
@Test func requestIdentityResolvesAndPopulatesCache() async throws {
    let root = try makeRootWithRedIcon(named: "cmux")
    defer { cleanupProjectIdentityFixture(root) }

    let cache = SidebarProjectIdentityCache(
        resolver: ProjectIdentityResolver(fileManager: .default))

    cache.requestIdentity(forProjectRoot: root.path)

    var identity = cache.cachedIdentity(forProjectRoot: root.path)
    var tries = 0
    while identity == nil && tries < 200 {
        try await Task.sleep(nanoseconds: 5_000_000)
        identity = cache.cachedIdentity(forProjectRoot: root.path)
        tries += 1
    }
    #expect(identity?.projectName == "cmux")
}
