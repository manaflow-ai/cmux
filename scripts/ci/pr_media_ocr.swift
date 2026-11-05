// Vision OCR for the pr-media privacy gate (scripts/ci/pr_media_privacy.py)
// and the journeys' frame checks (scripts/journeys/driver.py): prints the
// text recognized in one image, every distinct GIF frame, or one video frame
// per second plus the last. Multi-frame input prints an `@@frame N` line
// before each frame's text. Compiled ad hoc with `swiftc -O` by
// scripts/ci/pr_media_privacy.py (ocr_binary) and scripts/journeys/run.py;
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
/// (`bandedLines`). Vision's accurate recognizer on macOS 27 gives no
/// observation for some window images that show plenty of text, the same on
/// every try: on 2026-11-04 frames of a terminal in the journey
/// r3-after-switch read 0 lines on every one of 35 to 48 tries on the capture
/// minis (a nonce digit or the cursor's blink decided between 23 lines and
/// none), so five dogfood builds had no judgment of that journey. In 4 bands
/// each of those 30 stored frames read 16 to 26 lines, but in 10 of them one
/// band still read nothing although it shows text (the bottom quarter, with a
/// card). So the band read is partial where a band that shows ink claims no
/// line: stderr names those bands ("...; no text in band 4"), and the
/// journeys' negative frame checks do not trust such a read
/// (scripts/journeys/driver.py `unread_bands`). A band that claims no line and
/// shows no ink at all (`hasInk`: empty terminal rows) holds no text: stderr
/// names it blank ("blank band 3"), and it does not make the read partial (in
/// the 53-frame corpus of review 2 of #35282, 36 of the 46 silent bands showed
/// no ink, and every band that read text showed ink). An image whose whole read
/// finds text is never read in bands, so its lines do not change.
/// `bandsOnly` skips the whole read (the tests' --bands-only).
func recognize(_ image: CGImage, bandsOnly: Bool = false) throws -> [String] {
    if !bandsOnly {
        let whole = try observations(image).compactMap { $0.topCandidates(1).first?.string }
        if !whole.isEmpty { return whole }
    }
    let (banded, silent) = try bandedLines(image, bands: 4)
    let blank = silent.filter { !hasInk(image, band: $0, of: 4) }, unread = silent.filter { !blank.contains($0) }
    var note = "pr-media-ocr: no text in the whole image; \(banded.count) lines in 4 bands"
    if !blank.isEmpty {
        note += "; blank band\(blank.count == 1 ? "" : "s") " + blank.map(String.init).joined(separator: ", ")
    }
    if !unread.isEmpty {
        note += "; no text in band\(unread.count == 1 ? "" : "s") " + unread.map(String.init).joined(separator: ", ")
    }
    FileHandle.standardError.write(Data((note + "\n").utf8))
    return banded
}

/// Whether band `band` (1 is the top) of `bands` equal parts of `image`'s height shows ink: a row in which at least 3
/// pairs of horizontally adjacent pixels differ by more than 48 in a channel, not counting the columns where such a
/// difference is in at least 90 percent of the part's rows (the vertical edges of panes and the sidebar). Measured on
/// the 53 stored window frames of review 2 of #35282: every band that read text has 14 or more such rows, every silent
/// band of empty terminal rows has none.
func hasInk(_ image: CGImage, band: Int, of bands: Int) -> Bool {
    let width = image.width, height = image.height
    let part = (height + bands - 1) / bands
    let top = (band - 1) * part, bottom = min(height, band * part)
    guard top < bottom, width > 1,
          let context = CGContext(data: nil, width: width, height: bottom - top, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
          let crop = image.cropping(to: CGRect(x: 0, y: top, width: width, height: bottom - top)) else { return true }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: bottom - top))
    guard let data = context.data else { return true }
    let px = data.bindMemory(to: UInt8.self, capacity: width * (bottom - top) * 4)
    let rows = bottom - top
    var edges = [Bool](repeating: false, count: rows * (width - 1)), perColumn = [Int](repeating: 0, count: width - 1)
    for y in 0..<rows {
        for x in 0..<(width - 1) {
            let a = (y * width + x) * 4, b = a + 4
            let differs = (0..<3).contains { abs(Int(px[a + $0]) - Int(px[b + $0])) > 48 }
            if differs { edges[y * (width - 1) + x] = true; perColumn[x] += 1 }
        }
    }
    let structural = perColumn.map { $0 * 10 >= rows * 9 }
    for y in 0..<rows {
        var count = 0
        for x in 0..<(width - 1) where edges[y * (width - 1) + x] && !structural[x] { count += 1 }
        if count >= 3 { return true }
    }
    return false
}

/// The lines of `image` read as `bands` horizontal bands, top band first,
/// each band's lines in Vision's order. Each band is one part of the height
/// (`bands` equal parts) and reaches past it by a quarter of a part, at least
/// 32 pixels, above and below. A band claims the lines whose middle row is in
/// its part or less than a third of its reach from it, so a line up to
/// 2 x (reach - slack) tall (44 pixels at the least reach) is whole in a band
/// that claims it, even where a part's edge cuts the line. A line near a
/// part's edge is claimed by both bands there (Vision measures it a pixel or
/// two apart in each): it comes back once, from the band in which it sits
/// farthest from a cut edge. Two claims are the same line when their boxes
/// overlap by more than half of the smaller one; claims within one band are
/// kept as Vision gives them. The slack (a line Vision places a pixel past a
/// part's edge in both bands is still claimed) and the margin rule are guards
/// that no stored frame needed: there the slack changed no read, and the
/// margin rule only chose between two whole copies of a line; no test holds
/// either. Also returns the bands (1 is the top) that claimed no line.
func bandedLines(_ image: CGImage, bands: Int) throws -> (lines: [String], silent: [Int]) {
    let width = CGFloat(image.width), height = image.height
    let part = (height + bands - 1) / bands
    // Too short for bands of 16 rows: no band read, and every band is silent (an inked one is unread, never read as
    // empty; review 2 of #35282, note 4).
    guard part >= 16 else { return ([], Array(1...bands)) }
    let reach = max(32, part / 4), slack = reach / 3
    var claims: [(band: Int, line: String, box: CGRect, margin: CGFloat)] = []
    var silent: [Int] = []
    for index in 0..<bands {
        let top = index * part, bottom = min(height, top + part)
        guard top < bottom else { break }
        let from = max(0, top - reach), to = min(height, bottom + reach)
        guard let band = image.cropping(to: CGRect(x: 0, y: from, width: image.width, height: to - from)) else {
            silent.append(index + 1)
            continue
        }
        let claimed = claims.count
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
        if claims.count == claimed { silent.append(index + 1) }
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
    return (kept.sorted().map { claims[$0].line }, silent)
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

let arguments = Array(CommandLine.arguments.dropFirst())
let bandsOnly = arguments.first == "--bands-only"
guard arguments.count == (bandsOnly ? 2 : 1), let path = arguments.last else {
    fail("usage: pr-media-ocr [--bands-only] <file>")
}
let url = URL(fileURLWithPath: path)
switch url.pathExtension.lowercased() {
case "mp4", "mov":
    try await printVideo(url)
default:
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetCount(source) > 0 else { fail("unreadable image \(url.path)") }
    let count = CGImageSourceGetCount(source)
    if count == 1 {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("unreadable image \(url.path)") }
        for line in try recognize(image, bandsOnly: bandsOnly) { print(line) }
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
