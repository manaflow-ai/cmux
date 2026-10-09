import CoreVideo

/// A decoded image. The decoder hands the buffer over and never writes it
/// again, so the handle may cross to the main actor.
struct BrowserDecodedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
}
