import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the on-disk per-workspace picture (avatar) store: encode
/// contract, set/get/remove round-trip, hash gating, restore re-derivation, and
/// the restore-time id migration.
@MainActor
@Suite struct WorkspacePictureStoreTests {
    private func makeTemporaryDirectory() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspacePictureStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func makeStore(appSupport: URL) -> WorkspacePictureStore {
        WorkspacePictureStore(
            bundleIdentifier: "com.cmuxterm.tests",
            appSupportDirectory: appSupport
        )
    }

    /// A solid-color bitmap-backed NSImage that renders in headless CI.
    private func makeImage(width: Int, height: Int, color: NSColor) throws -> NSImage {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        color.setFill()
        NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }

    @Test func setPictureRoundTripsThroughHashGatedRead() throws {
        let appSupport = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let store = makeStore(appSupport: appSupport)
        let workspaceID = UUID()

        let image = try makeImage(width: 640, height: 480, color: .systemTeal)
        let hash = try #require(store.setPicture(image, for: workspaceID))

        #expect(store.pictureHash(for: workspaceID) == hash)
        let data = try #require(store.pictureData(for: workspaceID, matchingHash: hash))
        #expect(WorkspacePictureStore.contentHash(of: data) == hash)
        // Hash gating: a stale/wrong hash never serves bytes.
        #expect(store.pictureData(for: workspaceID, matchingHash: "0000000000000000") == nil)
    }

    @Test func freshStoreRederivesHashFromDisk() throws {
        let appSupport = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let workspaceID = UUID()

        let image = try makeImage(width: 100, height: 100, color: .systemRed)
        let hash = try #require(makeStore(appSupport: appSupport).setPicture(image, for: workspaceID))

        // A cold store (restore path) must re-derive the same hash from the file.
        let coldStore = makeStore(appSupport: appSupport)
        #expect(coldStore.pictureHash(for: workspaceID) == hash)
        #expect(coldStore.pictureData(for: workspaceID, matchingHash: hash) != nil)
    }

    @Test func removePictureClearsDiskAndReads() throws {
        let appSupport = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let store = makeStore(appSupport: appSupport)
        let workspaceID = UUID()

        let image = try makeImage(width: 64, height: 64, color: .systemBlue)
        let hash = try #require(store.setPicture(image, for: workspaceID))
        store.removePicture(for: workspaceID)

        #expect(store.pictureHash(for: workspaceID) == nil)
        #expect(store.pictureData(for: workspaceID, matchingHash: hash) == nil)
        // Cold read confirms the file is gone, not just the cache.
        #expect(makeStore(appSupport: appSupport).pictureHash(for: workspaceID) == nil)
    }

    @Test func changingPictureChangesHash() throws {
        let appSupport = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let store = makeStore(appSupport: appSupport)
        let workspaceID = UUID()

        let first = try #require(store.setPicture(
            try makeImage(width: 64, height: 64, color: .systemGreen),
            for: workspaceID
        ))
        let second = try #require(store.setPicture(
            try makeImage(width: 64, height: 64, color: .systemOrange),
            for: workspaceID
        ))
        #expect(first != second)
        #expect(store.pictureHash(for: workspaceID) == second)
        // The old hash no longer matches, so the stale fetch yields nil.
        #expect(store.pictureData(for: workspaceID, matchingHash: first) == nil)
    }

    @Test func migratePictureRehomesFileOntoNewWorkspaceID() throws {
        let appSupport = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let store = makeStore(appSupport: appSupport)
        let originalID = UUID()
        let restoredID = UUID()

        let image = try makeImage(width: 64, height: 64, color: .systemPurple)
        let hash = try #require(store.setPicture(image, for: originalID))

        let migratedHash = store.migratePicture(from: originalID, to: restoredID)
        #expect(migratedHash == hash)
        #expect(store.pictureHash(for: restoredID) == hash)
        #expect(store.pictureHash(for: originalID) == nil)
        #expect(store.pictureData(for: restoredID, matchingHash: hash) != nil)
    }

    @Test func migratePictureWithoutSourceReturnsNil() throws {
        let appSupport = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let store = makeStore(appSupport: appSupport)
        #expect(store.migratePicture(from: UUID(), to: UUID()) == nil)
    }

    @Test func normalizedAvatarPNGDownscalesToSquareAvatarSize() throws {
        let image = try makeImage(width: 1200, height: 800, color: .systemIndigo)
        let png = try #require(WorkspacePictureStore.normalizedAvatarPNG(from: image))
        let rep = try #require(NSBitmapImageRep(data: png))
        #expect(rep.pixelsWide == WorkspacePictureStore.avatarPixelSize)
        #expect(rep.pixelsHigh == WorkspacePictureStore.avatarPixelSize)
        #expect(png.count <= WorkspacePictureStore.maxStoredPictureBytes)
    }

    @Test func normalizedAvatarPNGRejectsEmptyImage() {
        #expect(WorkspacePictureStore.normalizedAvatarPNG(from: NSImage()) == nil)
    }

    @Test func setPictureDataRejectsEmptyAndOversizedBlobs() throws {
        let appSupport = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let store = makeStore(appSupport: appSupport)
        let workspaceID = UUID()

        #expect(store.setPictureData(Data(), for: workspaceID) == nil)
        let oversized = Data(count: WorkspacePictureStore.maxStoredPictureBytes + 1)
        #expect(store.setPictureData(oversized, for: workspaceID) == nil)
        #expect(store.pictureHash(for: workspaceID) == nil)
    }

    @Test func contentHashIsStableAndCompact() {
        let data = Data("avatar-bytes".utf8)
        let hash = WorkspacePictureStore.contentHash(of: data)
        #expect(hash.count == 16)
        #expect(hash == WorkspacePictureStore.contentHash(of: data))
        #expect(hash != WorkspacePictureStore.contentHash(of: Data("other".utf8)))
    }
}
