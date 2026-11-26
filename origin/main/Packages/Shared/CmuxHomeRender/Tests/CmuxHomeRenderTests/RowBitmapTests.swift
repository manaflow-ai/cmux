import CmuxHomeCore
import CoreGraphics
import Foundation
import Testing
@testable import CmuxHomeRender

/// Row bitmaps are drawn off the main actor: a miss never draws in the
/// caller, and the main actor only installs the finished image.
@MainActor
@Suite struct RowBitmapTests {
    @Test func aMissDrawsOffTheMainActorAndInstallsLater() async throws {
        let c = Fixtures.controller(width: 628, height: 900)
        c.update(items: Fixtures.items(Fixtures.conversation(12)), summary: Fixtures.summary(), typing: [], hasOlder: false)
        #expect(c.scene.bitmaps.isRendering, "visible rows started render jobs")
        #expect(c.scene.visible.values.allSatisfy { $0.bitmap.contents == nil }, "nothing was drawn synchronously")
        await c.scene.bitmaps.settled()
        #expect(!c.scene.bitmaps.isRendering)
        #expect(c.scene.visible.values.allSatisfy { $0.bitmap.contents != nil }, "every visible row got its bitmap")
    }

    @Test func equalContentSharesOneJobAndHitsTheCacheAfterwards() async throws {
        let bitmaps = RowBitmaps(palette: Fixtures.palette)
        let spec = RowSpec(key: "a", kind: .receipt("Read"), gap: 0, height: 14)
        var installed = 0
        let size = CGSize(width: 40, height: 62)
        #expect(bitmaps.image(for: spec, size: size) { _ in installed += 1 } == nil)
        var other = spec
        other.key = "b"
        #expect(bitmaps.image(for: other, size: size) { _ in installed += 1 } == nil)
        #expect(bitmaps.renderCount == 1, "one job per content key")
        await bitmaps.settled()
        #expect(installed == 2)
        #expect(bitmaps.image(for: spec, size: size) { _ in installed += 1 } != nil, "a hit returns at once")
        #expect(bitmaps.renderCount == 1)
    }

    @Test func aPaletteChangeDropsJobsInFlight() async throws {
        let bitmaps = RowBitmaps(palette: Fixtures.palette)
        let spec = RowSpec(key: "a", kind: .receipt("Read"), gap: 0, height: 14)
        var installed = 0
        _ = bitmaps.image(for: spec, size: CGSize(width: 40, height: 62)) { _ in installed += 1 }
        bitmaps.setPalette(HomePalette.themed(Fixtures.theme, active: false))
        #expect(!bitmaps.isRendering)
        await bitmaps.settled()
        // Let the cancelled job reach the main actor and be ignored.
        for _ in 0..<1000 { await Task.yield() }
        #expect(installed == 0, "an old palette's image is never installed")
    }
}
