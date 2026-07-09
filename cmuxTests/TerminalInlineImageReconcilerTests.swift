import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TerminalInlineImageReconcilerTests {
    private let reconciler = TerminalInlineImageReconciler()
    private let scanner = TerminalTranscriptImagePathScanner()

    @Test
    func keepsStableIdentityForSameAbsoluteRowAndPath() {
        let detected = [
            DetectedImagePath(rowIndex: 2, path: "/tmp/a.png", resolvedPath: "/tmp/a.png")
        ]
        let first = reconciler.reconcile(
            existing: [],
            detectedPaths: detected,
            viewport: TerminalInlineImageViewport(rowOffset: 10)
        )
        let second = reconciler.reconcile(
            existing: first,
            detectedPaths: detected,
            viewport: TerminalInlineImageViewport(rowOffset: 10)
        )

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(second[0].id == first[0].id)
        #expect(second[0].absoluteRow == 12)
    }

    @Test
    func dropsAnnotationsWhenRowNoLongerContainsPath() {
        let first = reconciler.reconcile(
            existing: [],
            detectedPaths: [
                DetectedImagePath(rowIndex: 1, path: "/tmp/a.png", resolvedPath: "/tmp/a.png")
            ],
            viewport: TerminalInlineImageViewport(rowOffset: 0)
        )
        let second = reconciler.reconcile(
            existing: first,
            detectedPaths: [],
            viewport: TerminalInlineImageViewport(rowOffset: 0)
        )

        #expect(first.count == 1)
        #expect(second.isEmpty)
    }

    @Test
    func keysByAbsoluteRowSoScrollDoesNotDuplicateIdentity() {
        let detected = [
            DetectedImagePath(rowIndex: 0, path: "/tmp/a.png", resolvedPath: "/tmp/a.png")
        ]
        let first = reconciler.reconcile(
            existing: [],
            detectedPaths: detected,
            viewport: TerminalInlineImageViewport(rowOffset: 10)
        )
        let second = reconciler.reconcile(
            existing: first,
            detectedPaths: detected,
            viewport: TerminalInlineImageViewport(rowOffset: 11)
        )

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(second[0].absoluteRow == 11)
        #expect(second[0].id != first[0].id)
    }

    @Test
    func capsViewportAnnotationsWithMostRecentRowsWinning() {
        let detected = (0..<5).map {
            DetectedImagePath(rowIndex: $0, path: "/tmp/\($0).png", resolvedPath: "/tmp/\($0).png")
        }
        let annotations = reconciler.reconcile(
            existing: [],
            detectedPaths: detected,
            viewport: TerminalInlineImageViewport(rowOffset: 0, maximumAnnotations: 3)
        )

        #expect(annotations.map(\.rowIndex) == [2, 3, 4])
    }

    @Test
    func preservesMultiplePathsOnOneRow() {
        let annotations = reconciler.reconcile(
            existing: [],
            detectedPaths: [
                DetectedImagePath(rowIndex: 3, path: "/tmp/b.png", resolvedPath: "/tmp/b.png"),
                DetectedImagePath(rowIndex: 3, path: "/tmp/a.png", resolvedPath: "/tmp/a.png"),
            ],
            viewport: TerminalInlineImageViewport(rowOffset: 4)
        )

        #expect(annotations.map(\.absoluteRow) == [7, 7])
        #expect(annotations.map(\.path) == ["/tmp/a.png", "/tmp/b.png"])
    }

    @Test
    func rawDuplicateDetectedPathsCollapseToOneAnnotationAcrossPasses() {
        let detected = [
            DetectedImagePath(rowIndex: 5, path: "~/a/shot.png", resolvedPath: "/Users/me/a/shot.png"),
            DetectedImagePath(rowIndex: 5, path: "/Users/me/a/shot.png", resolvedPath: "/Users/me/a/shot.png"),
        ]
        let first = reconciler.reconcile(
            existing: [],
            detectedPaths: detected,
            viewport: TerminalInlineImageViewport(rowOffset: 3)
        )
        let second = reconciler.reconcile(
            existing: first,
            detectedPaths: detected,
            viewport: TerminalInlineImageViewport(rowOffset: 3)
        )

        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(second[0].id == first[0].id)
        #expect(second[0].absoluteRow == 8)
    }

    @Test
    func duplicateResolvedPathDoesNotCrashAcrossReconcilePasses() {
        let detected = scanner.scan(
            rows: ["opened ~/a/shot.png and /Users/me/a/shot.png"],
            context: .init(homeDirectory: "/Users/me")
        )
        let first = reconciler.reconcile(
            existing: [],
            detectedPaths: detected,
            viewport: TerminalInlineImageViewport(rowOffset: 0)
        )
        let second = reconciler.reconcile(
            existing: first,
            detectedPaths: detected,
            viewport: TerminalInlineImageViewport(rowOffset: 0)
        )

        #expect(detected.count == 1)
        #expect(first.count == 1)
        #expect(second.count == 1)
        #expect(second[0].id == first[0].id)
        #expect(second[0].resolvedPath == "/Users/me/a/shot.png")
    }
}

@Suite
@MainActor
struct TerminalInlineImageSettingsObserverTests {
    @Test
    func firesOnToggleAndDedupesUnchangedWrites() async throws {
        let suiteName = "TerminalInlineImageSettingsObserverTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: TerminalInlineImageSettings.inlineImageThumbnailsKey)

        var delivered: [Bool] = []
        await confirmation("inline image setting changes", expectedCount: 2) { confirm in
            let observer = TerminalInlineImageSettingsObserver(defaults: defaults) { enabled in
                delivered.append(enabled)
                confirm()
            }
            observer.start()
            defaults.set(false, forKey: TerminalInlineImageSettings.inlineImageThumbnailsKey)
            await Task.yield()
            await Task.yield()
            defaults.set(false, forKey: TerminalInlineImageSettings.inlineImageThumbnailsKey)
            defaults.set("ignored", forKey: "terminal.inlineImageThumbnails.unrelated")
            await Task.yield()
            await Task.yield()
            defaults.set(true, forKey: TerminalInlineImageSettings.inlineImageThumbnailsKey)
            await Task.yield()
            await Task.yield()
            observer.stop()
        }

        #expect(delivered == [false, true])
        defaults.removePersistentDomain(forName: suiteName)
    }
}
