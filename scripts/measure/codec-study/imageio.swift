// The codec study's Apple path (README.md): ImageIO encode and decode on this Mac, which is where
// the hardware JPEG and HEVC (HEIC) encoders live, and every encoded file's ImageIO decode (what
// WebKit and iOS use to show it).
//
//   swiftc -O -o codec-study-imageio imageio.swift
//   codec-study-imageio types                         the ImageIO encode and decode types, as JSON
//   codec-study-imageio encode RUNS OUT_DIR IMAGE...  one JSON line per image and setting
//   codec-study-imageio decode RUNS FILE...           one JSON line per file: its ImageIO decode
//
// encode writes OUT_DIR/<image>/<setting>.<ext> and the decoded pixels beside it as
// <setting>.decoded.png (what the OCR reads). Times are milliseconds, the median of RUNS runs
// after one warm-up run, from an image already in memory to the encoded bytes (encode), and from
// the bytes to a decoded, cached image (decode). A setting whose warm-up takes over a second runs
// at most 3 times.

import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("codec-study-imageio: \(message)\n".utf8))
    exit(2)
}

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}

/// Times `body`: one warm-up run, then RUNS runs (3 when the warm-up took over a second).
func timed(_ runs: Int, _ body: () -> Bool) -> (ms: Double, runs: Int)? {
    let start = now()
    guard body() else { return nil }
    let warmup = Double(now() - start) / 1e6
    let count = warmup > 1000 ? min(runs, 3) : runs
    var samples: [Double] = []
    for _ in 0 ..< count {
        let t0 = now()
        guard body() else { return nil }
        samples.append(Double(now() - t0) / 1e6)
    }
    return (median(samples), count)
}

func load(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { fail("not an image: \(path)") }
    return image
}

func encode(_ image: CGImage, _ type: String, _ options: [CFString: Any]) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

/// Decodes fully: the image's pixels are decoded and cached, not deferred until drawn.
func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
}

func writePNG(_ image: CGImage, _ path: String) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

func emit(_ object: [String: Any]) {
    let json = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    print(String(decoding: json, as: UTF8.self))
    fflush(stdout)
}

let destinationTypes = (CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? []
let sourceTypes = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []

struct Setting {
    let id: String, codec: String, type: String, ext: String, options: [CFString: Any], note: String
}

/// The ImageIO settings this Mac can encode. JPEG q0.85 is the computer-use helper's re-encode.
func settings() -> [Setting] {
    var all: [Setting] = [
        Setting(id: "imageio-png", codec: "png", type: "public.png", ext: "png", options: [:], note: "ImageIO PNG"),
        Setting(id: "imageio-jpeg-q75", codec: "jpeg", type: "public.jpeg", ext: "jpg", options: [kCGImageDestinationLossyCompressionQuality: 0.75], note: "ImageIO JPEG"),
        Setting(id: "imageio-jpeg-q85", codec: "jpeg", type: "public.jpeg", ext: "jpg", options: [kCGImageDestinationLossyCompressionQuality: 0.85], note: "ImageIO JPEG, the computer-use helper's setting"),
        Setting(id: "imageio-jpeg-q92", codec: "jpeg", type: "public.jpeg", ext: "jpg", options: [kCGImageDestinationLossyCompressionQuality: 0.92], note: "ImageIO JPEG"),
        Setting(id: "imageio-heic-q75", codec: "heic", type: "public.heic", ext: "heic", options: [kCGImageDestinationLossyCompressionQuality: 0.75], note: "ImageIO HEIC (HEVC encoder)"),
        Setting(id: "imageio-heic-q85", codec: "heic", type: "public.heic", ext: "heic", options: [kCGImageDestinationLossyCompressionQuality: 0.85], note: "ImageIO HEIC (HEVC encoder)"),
        Setting(id: "imageio-avif-q85", codec: "avif", type: "public.avif", ext: "avif", options: [kCGImageDestinationLossyCompressionQuality: 0.85], note: "ImageIO AVIF"),
        Setting(id: "imageio-jxl-q85", codec: "jxl", type: "public.jpeg-xl", ext: "jxl", options: [kCGImageDestinationLossyCompressionQuality: 0.85], note: "ImageIO JPEG XL"),
        Setting(id: "imageio-jxl-q100", codec: "jxl", type: "public.jpeg-xl", ext: "jxl", options: [kCGImageDestinationLossyCompressionQuality: 1.0], note: "ImageIO JPEG XL at quality 1.0"),
        Setting(id: "imageio-webp-q85", codec: "webp", type: "org.webmproject.webp", ext: "webp", options: [kCGImageDestinationLossyCompressionQuality: 0.85], note: "ImageIO WebP"),
    ]
    all.removeAll { !destinationTypes.contains($0.type) }
    // CODEC_STUDY_ONLY (codec-study.sh only=): keep the setting ids that contain one of its tokens.
    let only = (ProcessInfo.processInfo.environment["CODEC_STUDY_ONLY"] ?? "").split(separator: ",").map(String.init)
    if !only.isEmpty { all.removeAll { setting in !only.contains { setting.id.contains($0) } } }
    return all
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "types":
    emit(["encode": destinationTypes.sorted(), "decode": sourceTypes.sorted(),
          "settings": settings().map(\.id)])
case "encode" where args.count >= 5:
    guard let runs = Int(args[2]), runs > 0 else { fail("RUNS is a number from 1") }
    let outDir = args[3]
    for path in args[4...] {
        let image = load(path)
        // OUT_DIR/<size folder>/<image>: the native and 1366 copies of an image share its name.
        let url = URL(fileURLWithPath: path)
        let dir = "\(outDir)/\(url.deletingLastPathComponent().lastPathComponent)/\(url.deletingPathExtension().lastPathComponent)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for setting in settings() {
            var record: [String: Any] = ["image": path, "setting": setting.id, "codec": setting.codec, "lib": "imageio", "note": setting.note,
                                         "width": image.width, "height": image.height]
            var encodedBytes: Data?
            guard let encodeTime = timed(runs, { encodedBytes = encode(image, setting.type, setting.options); return encodedBytes != nil }),
                  let bytes = encodedBytes else {
                record["error"] = "encode failed"
                emit(record)
                continue
            }
            var decodedImage: CGImage?
            guard let decodeTime = timed(runs, { decodedImage = decode(bytes); return decodedImage != nil }), let decoded = decodedImage else {
                record["error"] = "decode failed"
                emit(record)
                continue
            }
            let encoded = "\(dir)/\(setting.id).\(setting.ext)", decodedPath = "\(dir)/\(setting.id).decoded.png"
            FileManager.default.createFile(atPath: encoded, contents: bytes)
            guard writePNG(decoded, decodedPath) else { fail("cannot write \(decodedPath)") }
            record.merge(["bytes": bytes.count, "encode_ms": encodeTime.ms, "decode_ms": decodeTime.ms, "runs": encodeTime.runs,
                          "encoded": encoded, "decoded": decodedPath, "decoder": "imageio"]) { $1 }
            emit(record)
        }
    }
case "decode" where args.count >= 3:
    guard let runs = Int(args[2]), runs > 0 else { fail("RUNS is a number from 1") }
    for path in args[3...] {
        guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
        if let time = timed(runs, { decode(data) != nil }) {
            emit(["file": path, "imageio_decode_ms": time.ms, "runs": time.runs])
        } else {
            emit(["file": path, "imageio_decode_error": "ImageIO could not decode it"])
        }
    }
default:
    fail("usage: codec-study-imageio types | encode RUNS OUT_DIR IMAGE... | decode RUNS FILE...")
}
