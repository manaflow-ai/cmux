// Vision OCR for the pr-media privacy gate (scripts/ci/pr_media_privacy.py):
// prints the text recognized in one image, every distinct GIF frame, or one
// video frame per second plus the last. Multi-frame input prints an
// `@@frame N` line before each frame's text. Compiled ad hoc with `swiftc -O`
// by .github/workflows/pr-media-privacy.yml; dependency-free like
// scripts/e2e/ocr.swift, whose recognition settings it shares.
import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Vision

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pr-media-ocr: \(message)\n".utf8))
    exit(2)
}

func recognize(_ image: CGImage) throws -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

/// Identical frames (a GIF holding still) are recognized once.
func fingerprint(_ image: CGImage) -> Data? {
    guard let bytes = image.dataProvider?.data as Data? else { return nil }
    var hasher = SHA256()
    hasher.update(data: bytes)
    withUnsafeBytes(of: (image.width, image.height, image.bytesPerRow)) { hasher.update(bufferPointer: $0) }
    return Data(hasher.finalize())
}

/// Prints each distinct frame's text after an `@@frame N` line.
struct FramePrinter {
    var seen = Set<Data>()

    mutating func print(_ image: CGImage, index: Int) throws {
        if let key = fingerprint(image) {
            if seen.contains(key) { return }
            seen.insert(key)
        }
        Swift.print("@@frame \(index)")
        for line in try recognize(image) { Swift.print(line) }
    }
}

/// One frame per second plus the last, decoded one at a time.
func printVideo(_ url: URL) async throws {
    let asset = AVURLAsset(url: url)
    let seconds = try await asset.load(.duration).seconds
    guard seconds.isFinite, seconds > 0 else { fail("no duration in \(url.lastPathComponent)") }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
    generator.requestedTimeToleranceBefore = tolerance
    generator.requestedTimeToleranceAfter = tolerance
    var times = Array(stride(from: 0.0, to: seconds, by: 1.0))
    times.append(max(0, seconds - 0.05))
    var printer = FramePrinter()
    var read = 0
    for (index, time) in times.enumerated() {
        guard let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else {
            continue
        }
        read += 1
        try printer.print(frame, index: index)
    }
    if read == 0 { fail("no readable frames in \(url.lastPathComponent)") }
}

guard CommandLine.arguments.count == 2 else { fail("usage: pr-media-ocr <file>") }
let url = URL(fileURLWithPath: CommandLine.arguments[1])
switch url.pathExtension.lowercased() {
case "mp4", "mov":
    try await printVideo(url)
default:
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) > 0 else { fail("unreadable image \(url.path)") }
    let count = CGImageSourceGetCount(source)
    if count == 1 {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("unreadable image \(url.path)") }
        for line in try recognize(image) { print(line) }
    } else {
        // GIF and animated WebP: decode one frame at a time.
        var printer = FramePrinter()
        for index in 0..<count {
            if let image = CGImageSourceCreateImageAtIndex(source, index, nil) {
                try printer.print(image, index: index)
            }
        }
    }
}
