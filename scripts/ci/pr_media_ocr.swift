// Vision OCR for the pr-media privacy gate (scripts/ci/pr_media_privacy.py)
// and the journeys' frame checks (scripts/journeys/driver.py): prints the
// text recognized in one image, every distinct GIF frame, or one video frame
// per second plus the last. Multi-frame input prints an `@@frame N` line
// before each frame's text. Compiled ad hoc with `swiftc -O` by
// .github/workflows/pr-media-privacy.yml and scripts/journeys/run.py;
// dependency-free like scripts/e2e/ocr.swift, whose recognition settings it
// shares. An image in which Vision finds no text at all is read again in
// horizontal bands (`recognize`). Tests: scripts/ci/pr-media-ocr-tests (a
// fleet step: see its Package.swift).
import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Vision

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("pr-media-ocr: \(message)\n".utf8))
    exit(2)
}

/// What Vision recognizes in `image`: accurate, US English, no language correction.
func observations(_ image: CGImage) throws -> [VNRecognizedTextObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return request.results ?? []
}

/// The text lines of `image`, in Vision's order. When Vision finds no text at
/// all in the whole image, the lines of its 4 horizontal bands
/// (`bandedLines`). Vision's accurate recognizer gives no observation for some
/// window images that show plenty of text, the same on every try, and reads
/// each band of them: on 2026-11-04 frames of a terminal in the journey
/// r3-after-switch read 0 lines on every one of 44 tries on the capture minis
/// (macOS 27; a nonce digit or the cursor's blink decided between 23 lines and
/// none), so four dogfood builds had no judgment of that journey; in 4 bands
/// each of those frames read 16 to 26 lines. An image whose whole read finds
/// text is never read in bands, so its lines do not change.
func recognize(_ image: CGImage) throws -> [String] {
    let whole = try observations(image).compactMap { $0.topCandidates(1).first?.string }
    if !whole.isEmpty { return whole }
    let banded = try bandedLines(image, bands: 4)
    if !banded.isEmpty {
        FileHandle.standardError.write(Data("pr-media-ocr: no text in the whole image; \(banded.count) lines in 4 bands\n".utf8))
    }
    return banded
}

/// The lines of `image` read as `bands` horizontal bands, top band first,
/// each band's lines in Vision's order. Each band is one part of the height
/// (`bands` equal parts) and reaches past it by a quarter of a part, at least
/// 32 pixels, above and below. A band claims the lines whose middle row is in
/// its part or less than a third of its reach from it, so every line is whole
/// in a band that claims it, even where a part's edge cuts the line. A line
/// near a part's edge is claimed by both bands there (Vision measures it a
/// pixel or two apart in each): it comes back once, from the band in which it
/// sits farthest from a cut edge, where the cut can least spoil the read. Two
/// claims are the same line when their boxes overlap by more than half of the
/// smaller one; claims within one band are kept as Vision gives them.
func bandedLines(_ image: CGImage, bands: Int) throws -> [String] {
    let width = CGFloat(image.width), height = image.height
    let part = (height + bands - 1) / bands
    guard part >= 16 else { return [] }
    let reach = max(32, part / 4), slack = reach / 3
    var claims: [(band: Int, line: String, box: CGRect, margin: CGFloat)] = []
    for index in 0..<bands {
        let top = index * part, bottom = min(height, top + part)
        guard top < bottom else { break }
        let from = max(0, top - reach), to = min(height, bottom + reach)
        guard let band = image.cropping(to: CGRect(x: 0, y: from, width: image.width, height: to - from)) else { continue }
        for observation in try observations(band) {
            guard let line = observation.topCandidates(1).first?.string else { continue }
            // Vision's box is normalized with its origin at the bottom left; image rows count from the top.
            let normalized = observation.boundingBox, rows = CGFloat(to - from)
            let box = CGRect(x: normalized.minX * width, y: CGFloat(from) + (1 - normalized.maxY) * rows,
                             width: normalized.width * width, height: normalized.height * rows)
            guard box.midY >= CGFloat(top - slack), box.midY < CGFloat(bottom + slack) else { continue }
            // How far the line's middle is from the band's nearer cut edge (the image's own edges cut nothing).
            let above = from == 0 ? CGFloat.infinity : box.midY - CGFloat(from)
            let below = to == height ? CGFloat.infinity : CGFloat(to) - box.midY
            claims.append((index, line, box, min(above, below)))
        }
    }
    let farthestFirst = claims.indices.sorted { a, b in
        claims[a].margin != claims[b].margin ? claims[a].margin > claims[b].margin : a < b
    }
    var kept: [Int] = []
    for index in farthestFirst {
        let claim = claims[index]
        if kept.contains(where: { claims[$0].band != claim.band && mostlyCovers(claims[$0].box, claim.box) }) { continue }
        kept.append(index)
    }
    return kept.sorted().map { claims[$0].line }
}

/// Whether `a` and `b` overlap by more than half of the smaller one's area.
func mostlyCovers(_ a: CGRect, _ b: CGRect) -> Bool {
    let overlap = a.intersection(b)
    guard !overlap.isNull else { return false }
    let smaller = min(a.width * a.height, b.width * b.height)
    return smaller > 0 && overlap.width * overlap.height > smaller / 2
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
