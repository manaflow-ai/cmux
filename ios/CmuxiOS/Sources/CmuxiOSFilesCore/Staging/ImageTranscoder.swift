import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// HEIC/HEIF -> JPEG for "save to Mac" (c4-files.md section 6): one
/// re-encode at `quality`, metadata and orientation kept, no downsample.
public struct ImageTranscoder: Sendable {
    public var quality: Double

    public init(quality: Double = 0.85) {
        self.quality = quality
    }

    public static func isHEIC(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .heic) || type.conforms(to: .heif)
    }

    /// Writes a JPEG next to `source` (same base name, `.jpg`) and returns it.
    public func jpeg(from source: URL) throws -> URL {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil) else { throw TranscodeError() }
        let target = source.deletingPathExtension().appendingPathExtension("jpg")
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw TranscodeError()
        }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImageFromSource(destination, image, 0, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw TranscodeError() }
        return target
    }

    public struct TranscodeError: Error, Hashable, Sendable {}
}
