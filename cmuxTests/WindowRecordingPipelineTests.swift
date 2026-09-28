import AVFoundation
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

    private static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int)? {
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
        return (r: Int(bytes[2]), g: Int(bytes[1]), b: Int(bytes[0]))
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
        let duration = try await asset.load(.duration).seconds
        #expect(duration > 0.4)
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

        let asset = AVURLAsset(url: url)
        #expect(try await asset.load(.duration).seconds > 0)
    }

    @Test func anMP4WithNoFramesFailsInsteadOfLeavingAnEmptyFile() async throws {
        let url = Self.temporaryURL(extension: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WindowRecordingMP4Writer(url: url, width: 64, height: 64, framesPerSecond: 12)

        await #expect(throws: WindowRecordingWriterError.noFrames) {
            try await writer.finish()
        }
    }

    // MARK: gif

    @Test func aGIFHoldsEveryFrameAndItsMeasuredDelay() async throws {
        let url = Self.temporaryURL(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WindowRecordingGIFWriter(url: url, frameBudget: 3, framesPerSecond: 4)

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

    @Test func aGIFDelayStaysInThePlayableRange() async throws {
        let url = Self.temporaryURL(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WindowRecordingGIFWriter(url: url, frameBudget: 2, framesPerSecond: 8)

        try await writer.append(Self.image(width: 40, height: 40), atOffsetSeconds: 0)
        // A 40 second gap would stall a viewer; a zero gap would be dropped.
        try await writer.append(Self.image(width: 40, height: 40, gray: 0), atOffsetSeconds: 40)
        try await writer.finish()

        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        #expect(Self.gifDelay(source, at: 0) == 10)
    }

    @Test func aGIFWithNoFramesFails() async throws {
        let url = Self.temporaryURL(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WindowRecordingGIFWriter(url: url, frameBudget: 1, framesPerSecond: 8)

        await #expect(throws: WindowRecordingWriterError.noFrames) {
            try await writer.finish()
        }
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
