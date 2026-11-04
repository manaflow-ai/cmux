import CoreGraphics
import Foundation
import ImageIO
import Testing
import Vision

// R-HARNESS probe (never merge, cmux-ad m10 1): the journeys' text reader (scripts/ci/pr_media_ocr.swift)
// read no text at all in r3-after-switch frames that show text, 3 builds in a row. This reads the stored
// frames (Fixtures: pairs that differ only by a nonce or the cursor, one read and one empty on the mini)
// with the reader's settings and with each alternative, three times, and prints one OCRPROBE line per read.

struct ProbeRead: Codable {
    var image: String
    var variant: String
    var rep: Int
    var lines: Int
    var observations: Int
    var ms: Int
    var error: String?
    var head: [String]
    var tail: [String]
}

enum ProbeError: Error {
    case unreadable(String)
    case noContext
}

func packageDir() -> URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

func fixture(_ name: String) throws -> (CGImage, URL) {
    let url = packageDir().appendingPathComponent("Tests/OCRProbeTests/Fixtures/\(name).png")
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ProbeError.unreadable(url.path) }
    return (image, url)
}

func textRequest(_ level: VNRequestTextRecognitionLevel = .accurate, languages: [String]? = ["en-US"],
                 correction: Bool = false) -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = level
    if let languages { request.recognitionLanguages = languages }
    request.usesLanguageCorrection = correction
    return request
}

func strings(_ request: VNRecognizeTextRequest) -> ([String], Int) {
    let observations = request.results ?? []
    return (observations.compactMap { $0.topCandidates(1).first?.string }, observations.count)
}

func read(_ request: VNRecognizeTextRequest, _ image: CGImage) throws -> ([String], Int) {
    try VNImageRequestHandler(cgImage: image).perform([request])
    return strings(request)
}

/// `image` redrawn `scale` times as large, over `background` when given (no alpha left).
func redraw(_ image: CGImage, scale: CGFloat, background: CGColor?) throws -> CGImage {
    let width = Int(CGFloat(image.width) * scale), height = Int(CGFloat(image.height) * scale)
    let info = background == nil ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: info) else { throw ProbeError.noContext }
    context.interpolationQuality = .high
    if let background {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let made = context.makeImage() else { throw ProbeError.noContext }
    return made
}

/// The colour of the frame's middle pixel (the terminal's background).
func middleColor(_ image: CGImage) throws -> CGColor {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ProbeError.noContext }
    context.draw(image, in: CGRect(x: -image.width / 2, y: -image.height / 2, width: image.width, height: image.height))
    guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ProbeError.noContext }
    return CGColor(srgbRed: CGFloat(bytes[0]) / 255, green: CGFloat(bytes[1]) / 255, blue: CGFloat(bytes[2]) / 255, alpha: 1)
}

/// Horizontal bands of `count` (overlapping by `overlap` pixels), each read alone, top first.
func bands(_ image: CGImage, count: Int, overlap: Int) throws -> ([String], Int) {
    var lines: [String] = [], observations = 0
    let step = image.height / count
    for index in 0..<count {
        let top = max(0, index * step - overlap), bottom = min(image.height, (index + 1) * step + overlap)
        guard let band = image.cropping(to: CGRect(x: 0, y: top, width: image.width, height: bottom - top)) else { continue }
        let (got, seen) = try read(textRequest(), band)
        lines += got
        observations += seen
    }
    return (lines, observations)
}

@available(macOS 15.0, *)
func swiftAPI(_ image: CGImage) async throws -> ([String], Int) {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = [Locale.Language(identifier: "en-US")]
    request.usesLanguageCorrection = false
    let observations = try await request.perform(on: image)
    return (observations.compactMap { $0.topCandidates(1).first?.string }, observations.count)
}

func emit(_ row: ProbeRead) {
    guard let data = try? JSONEncoder().encode(row), let text = String(data: data, encoding: .utf8) else { return }
    print("OCRPROBE \(text)")
    let out = packageDir().appendingPathComponent("out")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let file = out.appendingPathComponent("probe.jsonl")
    if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
    if let handle = try? FileHandle(forWritingTo: file) {
        handle.seekToEndOfFile()
        handle.write(Data((text + "\n").utf8))
        try? handle.close()
    }
}

func probe(_ name: String) async throws {
    let (image, url) = try fixture(name)
    var variants: [(String, () async throws -> ([String], Int))] = []
    for rep in 1...3 { variants.append(("reader#\(rep)", { try read(textRequest(), image) })) }
    variants.append(("reader-url", {
        let request = textRequest()
        try VNImageRequestHandler(url: url).perform([request])
        return strings(request)
    }))
    variants.append(("correction-on", { try read(textRequest(correction: true), image) }))
    variants.append(("fast", { try read(textRequest(.fast), image) }))
    variants.append(("languages-default", { try read(textRequest(languages: nil), image) }))
    variants.append(("auto-language", {
        let request = textRequest(languages: nil)
        request.automaticallyDetectsLanguage = true
        return try read(request, image)
    }))
    variants.append(("min-height-0", {
        let request = textRequest()
        request.minimumTextHeight = 0
        return try read(request, image)
    }))
    variants.append(("min-height-0.005", {
        let request = textRequest()
        request.minimumTextHeight = 0.005
        return try read(request, image)
    }))
    variants.append(("opaque", { try read(textRequest(), redraw(image, scale: 1, background: middleColor(image))) }))
    variants.append(("redrawn-alpha", { try read(textRequest(), redraw(image, scale: 1, background: nil)) }))
    variants.append(("scale-2", { try read(textRequest(), redraw(image, scale: 2, background: nil)) }))
    variants.append(("scale-2-opaque", { try read(textRequest(), redraw(image, scale: 2, background: middleColor(image))) }))
    variants.append(("bands-4", { try bands(image, count: 4, overlap: 40) }))
    variants.append(("bands-8", { try bands(image, count: 8, overlap: 24) }))
    for revision in VNRecognizeTextRequest.supportedRevisions.sorted() {
        variants.append(("revision-\(revision)", {
            let request = textRequest()
            request.revision = revision
            return try read(request, image)
        }))
    }
    if #available(macOS 15.0, *) { variants.append(("swift-api", { try await swiftAPI(image) })) }
    for rep in 4...5 { variants.append(("reader#\(rep)", { try read(textRequest(), image) })) }
    for (label, run) in variants {
        let started = Date()
        var row = ProbeRead(image: name, variant: label, rep: 0, lines: 0, observations: 0, ms: 0, error: nil, head: [], tail: [])
        do {
            let (lines, observations) = try await run()
            row.lines = lines.count
            row.observations = observations
            row.head = Array(lines.prefix(3))
            row.tail = Array(lines.suffix(2))
        } catch {
            row.error = String(describing: error)
        }
        row.ms = Int(Date().timeIntervalSince(started) * 1000)
        emit(row)
    }
}

@Suite(.serialized)
struct OCRProbeTests {
    @Test func environment() throws {
        let languages = (try? textRequest().supportedRecognitionLanguages()) ?? []
        print("OCRPROBE-ENV os=\(ProcessInfo.processInfo.operatingSystemVersionString) "
              + "host=\(ProcessInfo.processInfo.hostName) current=\(VNRecognizeTextRequest.currentRevision) "
              + "default=\(VNRecognizeTextRequest.defaultRevision) supported=\(VNRecognizeTextRequest.supportedRevisions.sorted()) "
              + "languages=\(languages.prefix(6))")
    }

    @Test func a509Try1() async throws { try await probe("a-509-a2-c01-light-r3fg-try1") }
    @Test func a509Pass() async throws { try await probe("a-509-a2-c02-light-r3fg-pass") }
    @Test func b04Fail2() async throws { try await probe("b-b04-a1-c02-dark-r3fc-fail") }
    @Test func b04Fail3() async throws { try await probe("b-b04-a1-c03-dark-r3fc-fail") }
    @Test func b3a4Pass() async throws { try await probe("b-3a4-a1-c02-dark-r3fc-pass") }
    @Test func c8e8Fail() async throws { try await probe("c-8e8-a1-c45-light-r3fc-fail") }
    @Test func c8e1Pass() async throws { try await probe("c-8e1-a2-c02-light-r3fc-pass") }
    @Test func d15aFail() async throws { try await probe("d-15a-a1-c44-light-r3fg-fail") }
    @Test func d15aPass() async throws { try await probe("d-15a-a2-c01-light-r3fg-pass") }
    @Test func e04Pass() async throws { try await probe("e-b04-a1-c01-dark-r3fg-pass") }
}
