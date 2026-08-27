import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Notification hook cache")
struct CmuxNotificationHookCacheTests {
    @Test func cachesLayeredHooksAndInvalidatesChangedAndNewConfigFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-notification-hook-cache-\(UUID().uuidString)",
            isDirectory: true
        )
        let globalDirectory = root.appendingPathComponent("global", isDirectory: true)
        let projectDirectory = root.appendingPathComponent("project", isDirectory: true)
        let childDirectory = projectDirectory.appendingPathComponent("child", isDirectory: true)
        let childConfigDirectory = childDirectory.appendingPathComponent(".cmux", isDirectory: true)
        try FileManager.default.createDirectory(at: globalDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: childConfigDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let globalConfig = globalDirectory.appendingPathComponent("cmux.json")
        let projectConfig = projectDirectory.appendingPathComponent("cmux.json")
        let childConfig = childConfigDirectory.appendingPathComponent("cmux.json")
        try writeHook(id: "global", to: globalConfig)
        try writeHook(id: "child", to: childConfig)

        let cache = CmuxNotificationHookCache()
        let first = await cache.hooks(
            startingFrom: childDirectory.path,
            globalConfigPath: globalConfig.path
        )
        let parseCountAfterFirst = await cache.parseCount
        let hitCountAfterFirst = await cache.hitCount
        let repeated = await cache.hooks(
            startingFrom: childDirectory.path,
            globalConfigPath: globalConfig.path
        )
        let parseCountAfterRepeated = await cache.parseCount
        let hitCountAfterRepeated = await cache.hitCount

        #expect(first.map(\.id) == ["global", "child"])
        #expect(repeated == first)
        #expect(parseCountAfterRepeated == parseCountAfterFirst)
        #expect(hitCountAfterRepeated == hitCountAfterFirst + 1)

        try writeHook(id: "child-updated-longer", to: childConfig)
        let changed = await cache.hooks(
            startingFrom: childDirectory.path,
            globalConfigPath: globalConfig.path
        )
        #expect(changed.map(\.id) == ["global", "child-updated-longer"])

        let changedAttributes = try FileManager.default.attributesOfItem(atPath: childConfig.path)
        let changedModificationDate = try #require(changedAttributes[.modificationDate] as? Date)
        try writeHook(id: "child-updated-longeR", to: childConfig)
        try FileManager.default.setAttributes(
            [.modificationDate: changedModificationDate],
            ofItemAtPath: childConfig.path
        )
        let atomicallyReplaced = await cache.hooks(
            startingFrom: childDirectory.path,
            globalConfigPath: globalConfig.path
        )
        #expect(atomicallyReplaced.map(\.id) == ["global", "child-updated-longeR"])

        let stableAttributes = try FileManager.default.attributesOfItem(atPath: childConfig.path)
        let stableSize = try #require((stableAttributes[.size] as? NSNumber)?.uint64Value)
        let stableFileIdentifier = try #require(
            (stableAttributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
        let stableModificationDate = try #require(stableAttributes[.modificationDate] as? Date)
        try writeHook(id: "child-updated-longeS", to: childConfig, atomically: false)
        try FileManager.default.setAttributes(
            [.modificationDate: stableModificationDate],
            ofItemAtPath: childConfig.path
        )
        let restoredAttributes = try FileManager.default.attributesOfItem(atPath: childConfig.path)
        #expect((restoredAttributes[.size] as? NSNumber)?.uint64Value == stableSize)
        #expect(
            (restoredAttributes[.systemFileNumber] as? NSNumber)?.uint64Value
                == stableFileIdentifier
        )
        #expect(restoredAttributes[.modificationDate] as? Date == stableModificationDate)

        let rewrittenInPlace = await cache.hooks(
            startingFrom: childDirectory.path,
            globalConfigPath: globalConfig.path
        )
        #expect(rewrittenInPlace.map(\.id) == ["global", "child-updated-longeS"])

        try writeHook(id: "project", to: projectConfig)
        let added = await cache.hooks(
            startingFrom: childDirectory.path,
            globalConfigPath: globalConfig.path
        )
        #expect(added.map(\.id) == ["global", "project", "child-updated-longeS"])
    }

    @Test func leastRecentlyUsedDirectoryEntriesAreEvicted() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-notification-hook-cache-lru-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let globalConfig = root.appendingPathComponent("cmux.json")
        try writeHook(id: "global", to: globalConfig)
        let directories = (1...3).map { root.appendingPathComponent("project-\($0)", isDirectory: true) }
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let cache = CmuxNotificationHookCache(maximumEntryCount: 2)
        _ = await cache.hooks(startingFrom: directories[0].path, globalConfigPath: globalConfig.path)
        _ = await cache.hooks(startingFrom: directories[1].path, globalConfigPath: globalConfig.path)
        _ = await cache.hooks(startingFrom: directories[0].path, globalConfigPath: globalConfig.path)
        let hitsAfterTouchingFirst = await cache.hitCount
        _ = await cache.hooks(startingFrom: directories[2].path, globalConfigPath: globalConfig.path)
        _ = await cache.hooks(startingFrom: directories[0].path, globalConfigPath: globalConfig.path)
        let hitsAfterReusingFirst = await cache.hitCount
        _ = await cache.hooks(startingFrom: directories[1].path, globalConfigPath: globalConfig.path)
        let finalHitCount = await cache.hitCount

        #expect(hitsAfterReusingFirst == hitsAfterTouchingFirst + 1)
        #expect(finalHitCount == hitsAfterReusingFirst)
    }

    private func writeHook(id: String, to url: URL, atomically: Bool = true) throws {
        try """
        {
          // JSONC is supported by cmux config files.
          "notifications": {
            "hooks": [{ "id": "\(id)", "command": "cat" }],
          },
        }
        """.write(to: url, atomically: atomically, encoding: .utf8)
    }
}
