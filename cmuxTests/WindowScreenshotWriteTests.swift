import CmuxFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

private actor NonCooperativeCaptureOperation {
    private var continuation: CheckedContinuation<Int, Never>?

    var hasStarted: Bool { continuation != nil }

    func run() async -> Int {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func complete(with value: Int) {
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(returning: value)
    }
}

/// Covers the half of `cmux shot` that does not need a window on screen:
/// encoding one image to a png or a jpeg, and the error code each failure comes
/// back to the caller as.
@Suite struct WindowScreenshotWriteTests {
    // MARK: Fixtures

    private static func image(width: Int, height: Int, gray: Double = 0.6) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        context.setFillColor(gray: gray, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        return context.makeImage()!
    }

    /// A flat fill compresses to almost nothing at any quality, so the jpeg
    /// quality test needs detail a lossy encoder can actually throw away.
    private static func detailedImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        var value = UInt32(20_260_928)
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                // A fixed linear congruential sequence: detailed, and the same
                // pixels on every run.
                value = value &* 1_664_525 &+ 1_013_904_223
                context.setFillColor(
                    red: CGFloat((value >> 16) & 0xFF) / 255,
                    green: CGFloat((value >> 8) & 0xFF) / 255,
                    blue: CGFloat(value & 0xFF) / 255,
                    alpha: 1
                )
                context.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 2, height: 2))
            }
        }
        return context.makeImage()!
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-screenshot-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Anything the writer leaves behind next to the output, so a test can say
    /// the working file is gone rather than only that the output arrived.
    private static func contents(of directory: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
    }

    /// Yields until `isReady` answers true, or the deadline passes.
    ///
    /// A deadline rather than a yield count: N yields is however long N
    /// reschedules take, so a counted loop tightens exactly when the runner is
    /// busy, which is when a passing test turns into a flake.
    private static func waitUntil(
        _ isReady: () async -> Bool,
        within duration: Duration = .seconds(5)
    ) async {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            if await isReady() { return }
            await Task.yield()
        }
    }

    private static func waitUntilStarted(_ operation: NonCooperativeCaptureOperation) async {
        await waitUntil { await operation.hasStarted }
    }

    private static func waitUntilIdle(_ gate: OwnWindowFrameCapture.OperationGate) async {
        await waitUntil { !(await gate.isClaimed) }
    }

    // MARK: Writer

    @Test func aPNGIsWrittenAtTheImageSizeWithNoLeftoverWorkingFile() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("shot.png")

        let written = try WindowStillImageWriter.write(
            Self.image(width: 320, height: 200),
            to: output,
            format: .png,
            quality: 0.8
        )

        #expect(written.url == output)
        #expect(written.width == 320)
        #expect(written.height == 200)
        #expect(written.byteCount > 0)
        #expect(Self.contents(of: directory) == ["shot.png"])
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
    }

    @Test func aJPEGIsWrittenAsAJPEG() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("shot.jpg")

        let written = try WindowStillImageWriter.write(
            Self.image(width: 64, height: 64),
            to: output,
            format: .jpeg,
            quality: 0.5
        )

        #expect(written.byteCount > 0)
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.jpeg")
    }

    /// Quality only means something for a lossy format, and a caller who asks
    /// for a smaller file has to actually get one.
    @Test func jpegQualityChangesTheFileSize() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = Self.detailedImage(width: 200, height: 200)

        let low = try WindowStillImageWriter.write(
            image,
            to: directory.appendingPathComponent("low.jpg"),
            format: .jpeg,
            quality: 0.1
        )
        let high = try WindowStillImageWriter.write(
            image,
            to: directory.appendingPathComponent("high.jpg"),
            format: .jpeg,
            quality: 1
        )

        #expect(low.byteCount < high.byteCount)
    }

    @Test func theOutputDirectoryIsCreated() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory
            .appendingPathComponent("nested/deeper")
            .appendingPathComponent("shot.png")

        _ = try WindowStillImageWriter.write(
            Self.image(width: 32, height: 32),
            to: output,
            format: .png,
            quality: 0.8
        )

        #expect(FileManager.default.fileExists(atPath: output.path))
    }

    @Test func anExistingFileIsReplaced() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("shot.png")
        try Data("not an image".utf8).write(to: output)

        let written = try WindowStillImageWriter.write(
            Self.image(width: 48, height: 24),
            to: output,
            format: .png,
            quality: 0.8
        )

        #expect(written.byteCount > "not an image".count)
        #expect(Self.contents(of: directory) == ["shot.png"])
        let source = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
    }

    @Test func anAbandonedPreparedScreenshotCannotOverwriteTheRequestedPath() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("shot.png")
        let original = Data("written after the caller timed out".utf8)

        let prepared = try WindowStillImageWriter.prepare(
            Self.image(width: 48, height: 24),
            to: output,
            format: .png,
            quality: 0.8
        )
        try original.write(to: output)

        // This is the timeout path: the socket worker never receives a result
        // to commit, so retiring the late result can only remove its partial.
        prepared.discard()

        #expect(try Data(contentsOf: output) == original)
        #expect(Self.contents(of: directory) == ["shot.png"])
        #expect(throws: WindowStillImageWriter.Failure.self) {
            try prepared.commit()
        }
    }

    /// `--out ~/Pictures` is a typo, not an instruction to delete a directory.
    @Test func aDirectoryIsNotSomethingAScreenshotMayReplace() throws {
        let directory = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: WindowStillImageWriter.Failure.self) {
            try WindowStillImageWriter.write(
                Self.image(width: 16, height: 16),
                to: directory,
                format: .png,
                quality: 0.8
            )
        }
        #expect(Self.contents(of: directory).isEmpty)
    }

    // MARK: Working file

    @Test func theWorkingFileIsAHiddenSiblingOfTheOutput() {
        let output = URL(fileURLWithPath: "/tmp/shots/shot.png")
        let working = WindowCaptureOutputFile.workingURL(for: output, discriminator: "abc")

        #expect(working.deletingLastPathComponent() == output.deletingLastPathComponent())
        #expect(working.lastPathComponent == ".shot.png.abc.partial")
    }

    @Test func promotionCannotReplaceADirectoryThatAppearsDuringCapture() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("clip.mp4")
        let working = WindowCaptureOutputFile.workingURL(for: output, discriminator: "recording")
        let child = output.appendingPathComponent("keep.txt")
        let payload = Data("finished capture".utf8)

        try payload.write(to: working)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        try Data("do not delete".utf8).write(to: child)

        #expect(throws: (any Error).self) {
            try WindowCaptureOutputFile.promote(from: working, to: output)
        }
        #expect(try Data(contentsOf: child) == Data("do not delete".utf8))
        #expect(try Data(contentsOf: working) == payload)
    }

    // MARK: Error codes

    @Test func successfulCaptureReleasesItsInFlightLeaseBeforeReturning() async throws {
        let gate = OwnWindowFrameCapture.OperationGate()
        let result = try await OwnWindowFrameCapture.withDeadline(
            timeoutNanoseconds: 1_000_000_000,
            gate: gate,
            operation: { 42 }
        )

        #expect(result == 42)
        #expect(!(await gate.isClaimed))
    }

    @Test func nonCooperativeCaptureTimesOutWithoutAllowingAnotherOperation() async throws {
        let gate = OwnWindowFrameCapture.OperationGate()
        let operation = NonCooperativeCaptureOperation()
        let capture = Task {
            try await OwnWindowFrameCapture.withDeadline(
                timeoutNanoseconds: 100_000_000,
                gate: gate,
                operation: { await operation.run() }
            )
        }

        await Self.waitUntilStarted(operation)
        #expect(await operation.hasStarted)
        await #expect(throws: OwnWindowFrameCapture.Failure.timedOut) {
            try await capture.value
        }

        #expect(await gate.isClaimed)
        await #expect(throws: OwnWindowFrameCapture.Failure.timedOut) {
            try await OwnWindowFrameCapture.withDeadline(
                timeoutNanoseconds: 1_000_000_000,
                gate: gate,
                operation: { 99 }
            )
        }

        await operation.complete(with: 42)
        await Self.waitUntilIdle(gate)
        #expect(!(await gate.isClaimed))
        let next = try await OwnWindowFrameCapture.withDeadline(
            timeoutNanoseconds: 1_000_000_000,
            gate: gate,
            operation: { 7 }
        )
        #expect(next == 7)
    }

    @Test func outerCancellationReturnsWhileKeepingTheNonCooperativeLease() async {
        let gate = OwnWindowFrameCapture.OperationGate()
        let operation = NonCooperativeCaptureOperation()
        let capture = Task {
            try await OwnWindowFrameCapture.withDeadline(
                timeoutNanoseconds: 10_000_000_000,
                gate: gate,
                operation: { await operation.run() }
            )
        }

        await Self.waitUntilStarted(operation)
        #expect(await operation.hasStarted)
        capture.cancel()
        await #expect(throws: CancellationError.self) {
            try await capture.value
        }
        #expect(await gate.isClaimed)

        await operation.complete(with: 42)
        await Self.waitUntilIdle(gate)
        #expect(!(await gate.isClaimed))
    }

    @Test func captureFailuresReportWhoseFaultTheyAre() {
        #expect(
            TerminalController.screenshotErrorCode(
                for: OwnWindowFrameCapture.Failure.timedOut
            ) == "timeout"
        )
        #expect(
            TerminalController.screenshotErrorCode(
                for: OwnWindowFrameCapture.Failure.unsupportedSystem
            ) == "unsupported"
        )
        #expect(
            TerminalController.screenshotErrorCode(
                for: OwnWindowFrameCapture.Failure.windowGone
            ) == "not_found"
        )
        #expect(
            TerminalController.screenshotErrorCode(
                for: OwnWindowFrameCapture.Failure.captureFailed("no window server")
            ) == "internal_error"
        )
    }

    @Test func anUnusableOutputPathIsTheCallersParameter() {
        #expect(
            TerminalController.screenshotErrorCode(
                for: WindowStillImageWriter.Failure.outputNotAFile("/tmp")
            ) == "invalid_params"
        )
        #expect(
            TerminalController.screenshotErrorCode(
                for: WindowStillImageWriter.Failure.encodeFailed("no destination")
            ) == "internal_error"
        )
    }

    @Test func geometryFailuresAreParameterFailures() {
        #expect(
            TerminalController.screenshotErrorCode(
                for: WindowRecordingFrameGeometry.Failure.regionOutsideWindow
            ) == "invalid_params"
        )
        #expect(
            TerminalController.screenshotErrorCode(
                for: WindowRecordingFrameGeometry.Failure.emptyWindow
            ) == "invalid_params"
        )
    }

    @Test func anUnrecognizedErrorStaysAnInternalError() {
        struct Surprise: Error {}
        #expect(TerminalController.screenshotErrorCode(for: Surprise()) == "internal_error")
    }
}
