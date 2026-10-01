import AVFoundation
import CmuxFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Covers the two halves of `cmux record` that do not need a window on screen:
/// composing a captured image into an encoded frame, and writing frames out as
/// an mp4 or a gif.
@Suite struct WindowRecordingPipelineTests {
    // MARK: Fixtures

    private static func image(
        width: Int,
        height: Int,
        gray: Double = 1
    ) -> CGImage {
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

    /// An image with a known color in one quadrant, so a crop can be checked by
    /// reading a pixel rather than by trusting the rectangle arithmetic.
    private static func quadrantImage(width: Int, height: Int) -> CGImage {
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
        context.setFillColor(gray: 0.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        // Top-left quadrant in CGImage coordinates, which have y growing down.
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(
            x: 0,
            y: CGFloat(height) / 2,
            width: CGFloat(width) / 2,
            height: CGFloat(height) / 2
        ))
        return context.makeImage()!
    }

    /// Tuples are not `Equatable`, and the caption test compares pixels.
    private struct Pixel: Equatable {
        let r: Int
        let g: Int
        let b: Int
    }

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> Pixel? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        // 32BGRA little endian: bytes are B, G, R, then the skipped alpha.
        return Pixel(r: Int(bytes[2]), g: Int(bytes[1]), b: Int(bytes[0]))
    }

    private static func geometry(params: [String: Any] = [:], width: Int, height: Int) throws
        -> WindowRecordingFrameGeometry {
        try WindowRecordingFrameGeometry.plan(
            windowPixelWidth: width,
            windowPixelHeight: height,
            pointPixelScale: 1,
            request: try WindowRecordingRequest.make(params: params)
        )
    }

    private static func temporaryURL(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-recording-test-\(UUID().uuidString).\(pathExtension)"
        )
    }

    // MARK: Composer

    @Test func composedFramesAreTheEncodedFrameSize() throws {
        let geometry = try Self.geometry(params: ["scale": 0.5], width: 800, height: 600)

        let frame = try #require(WindowRecordingFrameComposer.compose(
            source: Self.image(width: 800, height: 600),
            geometry: geometry,
            caption: nil
        ))

        #expect(frame.width == geometry.outputWidth)
        #expect(frame.height == geometry.outputHeight)
    }

    @Test func aRegionCropKeepsOnlyTheRequestedPixels() throws {
        let source = Self.quadrantImage(width: 400, height: 400)
        // The red quadrant sits at the top-left of the image.
        let geometry = try Self.geometry(params: ["region": "0,0,200,200"], width: 400, height: 400)

        let frame = try #require(WindowRecordingFrameComposer.compose(
            source: source,
            geometry: geometry,
            caption: nil
        ))

        #expect(frame.width == 200)
        #expect(frame.height == 200)
        let center = try #require(Self.pixel(frame, x: 100, y: 100))
        #expect(center.r > 200)
        #expect(center.g < 60)
    }

    @Test func aWindowResizedMidClipIsLetterboxedRatherThanStretched() throws {
        // A clip that opened on a 400x400 window keeps that frame size; a
        // later 400x200 capture has to be centered inside it with black bars.
        let opening = try Self.geometry(width: 400, height: 400)
        let resized = try Self.geometry(width: 400, height: 200)

        let frame = try #require(WindowRecordingFrameComposer.compose(
            source: Self.image(width: 400, height: 200),
            geometry: opening.adoptingCrop(of: resized),
            caption: nil
        ))

        #expect(frame.width == 400)
        #expect(frame.height == 400)
        let top = try #require(Self.pixel(frame, x: 200, y: 4))
        let middle = try #require(Self.pixel(frame, x: 200, y: 200))
        #expect(top.r == 0)
        #expect(middle.r > 200)
    }

    @Test func aCaptionDarkensTheBottomLeftAndLeavesTheRestAlone() throws {
        let geometry = try Self.geometry(width: 600, height: 400)
        let source = Self.image(width: 600, height: 400)

        let plain = try #require(WindowRecordingFrameComposer.compose(
            source: source,
            geometry: geometry,
            caption: nil
        ))
        let captioned = try #require(WindowRecordingFrameComposer.compose(
            source: source,
            geometry: geometry,
            caption: "opened the command palette"
        ))

        // The caption box hugs the bottom-left corner, so its exact width
        // depends on the system font; assert on the band it occupies.
        let changedInBand = (2..<150).filter { step in
            Self.pixel(plain, x: step * 4, y: 380) != Self.pixel(captioned, x: step * 4, y: 380)
        }
        #expect(!changedInBand.isEmpty)
        let inBox = try #require(Self.pixel(captioned, x: 30, y: 380))
        #expect(inBox.r < 160)
        let untouched = try #require(Self.pixel(captioned, x: 300, y: 20))
        #expect(untouched == Self.pixel(plain, x: 300, y: 20))
    }

    @Test func fittingNeverUpscalesPastTheFrame() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)

        let wide = WindowRecordingFrameComposer.fit(CGSize(width: 800, height: 200), in: bounds)

        #expect(wide.width == 400)
        #expect(wide.height == 100)
        #expect(wide.minY == 150)

        // A window that shrank mid-clip keeps its own pixel size, centered,
        // rather than being blown up to fill the frame it opened with.
        let small = WindowRecordingFrameComposer.fit(CGSize(width: 200, height: 100), in: bounds)

        #expect(small.width == 200)
        #expect(small.height == 100)
        #expect(small.minX == 100)
        #expect(small.minY == 150)
    }

    // MARK: mp4

    @Test func anMP4CarriesTheFramesAndTheirElapsedTiming() async throws {
        let url = Self.temporaryURL(extension: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WindowRecordingMP4Writer(url: url, width: 160, height: 120, framesPerSecond: 10)
        let frame = Self.image(width: 160, height: 120)

        // Deliberately uneven gaps: a sampler that fell behind must not make
        // the clip play fast.
        for offset in [0.0, 0.1, 0.45, 0.5] {
            try await writer.append(frame, atOffsetSeconds: offset)
        }
        try await writer.finish()

        #expect(FileManager.default.fileExists(atPath: url.path))
        let asset = AVURLAsset(url: url)
        // The clip's encoded length, not a measured time: the frames above
        // are stamped up to 0.5 s, so a clip timed by capture spans past 0.4 s.
        let clipSeconds = try await asset.load(.duration).seconds
        #expect(clipSeconds > 0.4)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(Int(size.width) == 160)
        #expect(Int(size.height) == 120)
    }

    @Test func twoFramesInTheSameTickStillGetIncreasingTimes() async throws {
        let url = Self.temporaryURL(extension: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WindowRecordingMP4Writer(url: url, width: 64, height: 64, framesPerSecond: 12)
        let frame = Self.image(width: 64, height: 64)

        try await writer.append(frame, atOffsetSeconds: 0)
        try await writer.append(frame, atOffsetSeconds: 0)
        try await writer.finish()

        // Both frames have to survive, and the second one has to present later
        // than the first: an equal timestamp makes AVFoundation drop it, which
        // left a one-sample clip before the writer started nudging.
        //
        // The count is a floor, not an equality. How many samples a clip of two
        // frames a 1/600 second apart ends up with is the encoder's decision,
        // and the CI VMs, which have no hardware scaler, write more samples
        // than were appended. Dropping a frame still shows up here: the bug
        // this covers produced a single sample.
        let times = try await Self.presentationTimes(url: url)
        #expect(times.count >= 2, "presentation times: \(times)")
        #expect(times.first == 0, "presentation times: \(times)")
        #expect(
            zip(times, times.dropFirst()).allSatisfy { $0.0 < $0.1 },
            "presentation times: \(times)"
        )
        if times.count >= 2 {
            // The second sample is a timescale tick after the first, not a
            // whole frame interval: the writer nudged it by 1/600 second.
            #expect(times[1] - times[0] < 1.0 / 12, "presentation times: \(times)")
        }
    }

    @Test func anMP4WithNoFramesFailsInsteadOfLeavingAnEmptyFile() async throws {
        let url = Self.temporaryURL(extension: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WindowRecordingMP4Writer(url: url, width: 64, height: 64, framesPerSecond: 12)

        await #expect(throws: WindowRecordingWriterError.noFrames) {
            try await writer.finish()
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Reads back what the file really carries, rather than trusting the asset's
    /// rounded duration.
    private static func presentationTimes(url: URL) async throws -> [Double] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return []
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() {
            times.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        return times
    }

    // MARK: gif

    @Test func aGIFHoldsEveryFrameAndItsMeasuredDelay() async throws {
        let url = Self.temporaryURL(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WindowRecordingGIFWriter(url: url, framesPerSecond: 4)

        try await writer.append(Self.image(width: 80, height: 60, gray: 1), atOffsetSeconds: 0)
        try await writer.append(Self.image(width: 80, height: 60, gray: 0.5), atOffsetSeconds: 0.5)
        try await writer.append(Self.image(width: 80, height: 60, gray: 0), atOffsetSeconds: 0.75)
        try await writer.finish()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
        #expect(Self.gifDelay(source, at: 0) == 0.5)
        #expect(Self.gifDelay(source, at: 1) == 0.25)
        // The last frame has no successor, so it takes the nominal delay.
        #expect(Self.gifDelay(source, at: 2) == 0.25)
    }

    @Test func aGIFIsCreatedWithItsFinalFrameCountAndRemovesItsStagingFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-gif-count-test-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.gif")
        let writer = try WindowRecordingGIFWriter(url: url, framesPerSecond: 8)

        for step in 0..<4 {
            try await writer.append(
                Self.image(width: 24, height: 24, gray: Double(step) / 4),
                atOffsetSeconds: Double(step) * 0.125
            )
        }
        try await writer.finish()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 4)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["clip.gif"]
        )
    }

    @Test func aGIFDelayStaysInThePlayableRange() async throws {
        let url = Self.temporaryURL(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WindowRecordingGIFWriter(url: url, framesPerSecond: 8)

        try await writer.append(Self.image(width: 40, height: 40), atOffsetSeconds: 0)
        // A 40 second gap would stall a viewer; a zero gap would be dropped.
        try await writer.append(Self.image(width: 40, height: 40, gray: 0), atOffsetSeconds: 40)
        try await writer.append(Self.image(width: 40, height: 40, gray: 0.5), atOffsetSeconds: 40)
        try await writer.finish()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(Self.gifDelay(source, at: 0) == 10)
        #expect(Self.gifDelay(source, at: 1) == 0.02)
    }

    /// The normal flow: a clip with a 30 second budget that an agent stops after
    /// three frames still has to produce a gif.
    @Test func aGIFStoppedLongBeforeItsBudgetStillFinalizes() async throws {
        let url = Self.temporaryURL(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WindowRecordingGIFWriter(url: url, framesPerSecond: 8)

        for step in 0..<3 {
            try await writer.append(
                Self.image(width: 40, height: 40, gray: Double(step) / 3),
                atOffsetSeconds: Double(step) * 0.125
            )
        }
        try await writer.finish()

        #expect(FileManager.default.fileExists(atPath: url.path))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 3)
    }

    @Test func aGIFWithNoFramesFails() async throws {
        let url = Self.temporaryURL(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WindowRecordingGIFWriter(url: url, framesPerSecond: 8)

        await #expect(throws: WindowRecordingWriterError.noFrames) {
            try await writer.finish()
        }
    }

    @Test func gifStagingStopsAtItsCumulativeByteLimit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-gif-byte-limit-test-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.gif")

        var writer: WindowRecordingGIFWriter? = try WindowRecordingGIFWriter(
            url: url,
            framesPerSecond: 8,
            stagedByteLimit: 1
        )
        try await writer?.append(Self.image(width: 40, height: 40), atOffsetSeconds: 0)
        await #expect(throws: WindowRecordingWriterError.self) {
            try await writer?.append(
                Self.image(width: 40, height: 40, gray: 0),
                atOffsetSeconds: 0.125
            )
        }
        writer = nil

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    /// A gif that reaches its staging limit mid-clip keeps the frames it staged
    /// before the limit. The session's `fail(_:)` promises "whatever was
    /// captured before the failure", and that promise is only kept if
    /// `finish()` can drop the one frame it cannot stage.
    @Test func aGIFThatHitsItsStagingLimitStillFinalizesTheFramesBeforeIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-gif-limit-keeps-frames-test-\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("clip.gif")
        // Every frame is the same image, so every staged png is the same size:
        // the first one fits the limit exactly and the second cannot start.
        let frame = Self.image(width: 40, height: 40, gray: 0.25)
        let writer = try WindowRecordingGIFWriter(
            url: url,
            framesPerSecond: 8,
            stagedByteLimit: try Self.stagedPNGByteCount(of: frame)
        )

        try await writer.append(frame, atOffsetSeconds: 0)
        // Staging happens one frame behind, so this call is the one that stages
        // the first frame and the next is the one that runs out of room.
        try await writer.append(frame, atOffsetSeconds: 0.125)
        await #expect(throws: WindowRecordingWriterError.self) {
            try await writer.append(frame, atOffsetSeconds: 0.25)
        }

        try await writer.finish()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["clip.gif"]
        )
    }

    /// The size the writer will charge against its staging budget for one
    /// frame, measured the same way the writer stages it.
    private static func stagedPNGByteCount(of image: CGImage) throws -> Int64 {
        let url = Self.temporaryURL(extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        let size = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        )
        return size.int64Value
    }

    private static func gifDelay(_ source: CGImageSource, at index: Int) -> Double? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
            as NSDictionary?,
            let gif = properties[kCGImagePropertyGIFDictionary] as? NSDictionary else {
            return nil
        }
        return (gif[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
    }
}

/// Covers the bookkeeping `cmux record` needs without a window on screen: which
/// clip `stop`, `status` and `note` resolve to once a recording has ended.
@Suite struct WindowRecordingRegistryTests {
    private static func finished(id: String) -> WindowRecordingStatus {
        WindowRecordingStatus(
            id: id,
            state: .finished,
            format: .mp4,
            path: "/tmp/\(id).mp4",
            label: "",
            frames: 12,
            seconds: 1,
            width: 320,
            height: 200,
            notes: 0,
            requestedFramesPerSecond: 12,
            maximumSeconds: 15,
            error: nil
        )
    }

    /// A clip that reached its own `--max-seconds` limit is no longer active, so
    /// the `cmux record stop` an agent runs afterwards has to report that clip
    /// rather than claim nothing was recorded.
    @Test func stoppingAfterTheClipStoppedItselfReportsThatClip() async throws {
        let registry = WindowRecordingRegistry()
        await registry.remember(Self.finished(id: "a"))

        let stopped = try await registry.stop(id: nil)

        #expect(stopped.id == "a")
        #expect(stopped.state == .finished)
        #expect(stopped.path == "/tmp/a.mp4")
    }

    @Test func stoppingWithNothingEverRecordedSaysSo() async {
        let registry = WindowRecordingRegistry()

        await #expect(throws: WindowRecordingRegistry.Failure.self) {
            _ = try await registry.stop(id: nil)
        }
    }

    @Test func anUnknownIdIsNotAnsweredWithTheLatestClip() async {
        let registry = WindowRecordingRegistry()
        await registry.remember(Self.finished(id: "a"))

        await #expect(throws: WindowRecordingRegistry.Failure.self) {
            _ = try await registry.stop(id: "b")
        }
        await #expect(throws: WindowRecordingRegistry.Failure.self) {
            _ = try await registry.status(id: "b")
        }
    }

    @Test func aNoteForAStoppedClipIsRefused() async {
        let registry = WindowRecordingRegistry()
        await registry.remember(Self.finished(id: "a"))

        await #expect(throws: WindowRecordingRegistry.Failure.self) {
            _ = try await registry.note(text: "too late", id: "a")
        }
    }

    @Test func historyKeepsTheMostRecentClipsOnly() async {
        let registry = WindowRecordingRegistry()
        for index in 0..<12 {
            await registry.remember(Self.finished(id: "clip-\(index)"))
        }

        let recent = await registry.recentStatuses()

        #expect(recent.count == 8)
        #expect(recent.first?.id == "clip-4")
        #expect(recent.last?.id == "clip-11")
    }

    /// A timed-out `record start` whose call already ended must not reach into
    /// whatever is recorded now.
    @Test func abandoningAStartThatIsNoLongerRunningChangesNothing() async throws {
        let registry = WindowRecordingRegistry()
        await registry.remember(Self.finished(id: "a"))

        await registry.abandonStart(token: UUID())

        let status = try await registry.status(id: nil)
        #expect(status.id == "a")
        #expect(status.state == .finished)
    }

    /// The session a timed-out start opened ends as failed, with a reason the
    /// caller can read from `record status`, and a later stop keeps that verdict.
    @Test func anAbandonedSessionStopsRecordingAndStaysFailed() async throws {
        let session = WindowRecordingSession(
            id: "abandoned",
            request: try WindowRecordingRequest.make(params: [:]),
            outputURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-abandoned-\(UUID().uuidString).mp4"),
            windowID: 0,
            windowHandle: nil
        )

        await session.abandon(reason: "timed out")

        #expect(await session.isRecording == false)
        let stopped = await session.stop()
        #expect(stopped.state == .failed)
        #expect(stopped.error == "timed out")
    }
}
