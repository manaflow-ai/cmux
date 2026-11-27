// Text sharpness for the screen stream eval: Vision OCR (accurate, no language correction) of the
// host's own screenshot and of the frame the viewer decoded, and the character error rate of the
// viewer's text against the host's: edit distance / host characters. Also each against the text
// the scene drew (TRUTH_TXT), which says how far the OCR itself is from the truth.
//
//   swiftc -O -o screen-eval-ocr ocr.swift
//   screen-eval-ocr HOST_IMAGE VIEWER_IMAGE TRUTH_TXT [--host-crop X,Y,W,H --viewer-crop X,Y,W,H
//     --calibration FILE --source-geometry FILE --readiness FILE]
// Crops use explicit top-left image pixels. A common-marker comparison needs
// a real-pair calibration bound to the current source and selected window.
//
// Prints one JSON object. Lines are compared in reading order with runs of spaces collapsed, since
// OCR does not keep a code file's indentation.

import AppKit
import Foundation
import Vision

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("screen-eval-ocr: \(message)\n".utf8))
    exit(2)
}

/// A binary PPM (P6, 8 bit) as a CGImage; ImageIO does not read PPM.
func ppm(_ data: Data) -> CGImage? {
    var fields: [String] = []
    var index = data.startIndex
    while fields.count < 4, index < data.endIndex {
        while index < data.endIndex, data[index] == 0x20 || data[index] == 0x0A || data[index] == 0x0D || data[index] == 0x09 { index += 1 }
        var field = ""
        while index < data.endIndex, !(data[index] == 0x20 || data[index] == 0x0A || data[index] == 0x0D || data[index] == 0x09) {
            field.append(Character(UnicodeScalar(data[index])))
            index += 1
        }
        fields.append(field)
    }
    index += 1 // the one whitespace byte before the pixels
    guard fields.count == 4, fields[0] == "P6", let width = Int(fields[1]), let height = Int(fields[2]), fields[3] == "255",
          data.endIndex - index >= width * height * 3
    else { return nil }
    let rgb = data.subdata(in: index ..< index + width * height * 3)
    guard let provider = CGDataProvider(data: rgb as CFData) else { return nil }
    return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: width * 3,
                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)
}

func image(_ path: String) -> CGImage {
    guard let data = FileManager.default.contents(atPath: path) else { fail("cannot read \(path)") }
    if data.starts(with: Array("P6".utf8)), let image = ppm(data) { return image }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { fail("not an image: \(path)") }
    return image
}

/// The recognized lines, top to bottom, then left to right.
func recognize(_ image: CGImage) -> [String] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { fail("OCR failed: \(error)") }
    let observations = (request.results ?? []).sorted {
        abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.004 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
    }
    return observations.compactMap { $0.topCandidates(1).first?.string }.map(normalize).filter { !$0.isEmpty }
}

func normalize(_ line: String) -> String {
    line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
}

/// Levenshtein distance over characters (two rows).
func distance(_ a: [Character], _ b: [Character]) -> Int {
    if a.isEmpty { return b.count }
    if b.isEmpty { return a.count }
    var previous = Array(0 ... b.count), current = [Int](repeating: 0, count: b.count + 1)
    for i in 1 ... a.count {
        current[0] = i
        for j in 1 ... b.count {
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
        }
        swap(&previous, &current)
    }
    return previous[b.count]
}

func cer(_ text: String, against reference: String) -> Double {
    reference.isEmpty ? 1 : Double(distance(Array(text), Array(reference))) / Double(reference.count)
}

struct PixelCrop {
    let values: [Int]
    init(_ value: String, image: CGImage) {
        let fields = value.split(separator: ",", omittingEmptySubsequences: false)
        let numbers = fields.compactMap { Int($0) }
        guard numbers.count == 4, numbers[0] >= 0, numbers[1] >= 0,
              numbers[2] > 0, numbers[3] > 0, numbers[0] < image.width, numbers[1] < image.height,
              numbers[2] <= image.width - numbers[0], numbers[3] <= image.height - numbers[1]
        else { fail("crop must be a positive in-bounds top-left pixel rect: \(value)") }
        values = numbers
    }
    var rect: CGRect { CGRect(x: CGFloat(values[0]), y: CGFloat(values[1]), width: CGFloat(values[2]), height: CGFloat(values[3])) }
}

func jsonObject(_ path: String?) -> [String: Any]? {
    guard let path else { return nil }
    guard let data = FileManager.default.contents(atPath: path),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { fail("cannot read JSON object: \(path)") }
    return object
}

func sameJSON(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs = lhs as? NSObject, let rhs = rhs as? NSObject else { return false }
    return lhs.isEqual(rhs)
}

let args = CommandLine.arguments
guard args.count >= 4, (args.count - 4) % 2 == 0 else { fail("usage: screen-eval-ocr HOST_IMAGE VIEWER_IMAGE TRUTH_TXT [--host-crop X,Y,W,H --viewer-crop X,Y,W,H --calibration FILE --source-geometry FILE --readiness FILE]") }
var options: [String: String] = [:]
for index in stride(from: 4, to: args.count, by: 2) {
    let key = args[index]
    guard ["--host-crop", "--viewer-crop", "--calibration", "--source-geometry", "--readiness"].contains(key), options[key] == nil else { fail("unknown or repeated option: \(key)") }
    options[key] = args[index + 1]
}
let hostImage = image(args[1]), viewerImage = image(args[2])
var hostInput = hostImage, viewerInput = viewerImage
var cropReceipt: [String: Any]?
var comparisonReady = true
if !options.isEmpty {
    guard let hostValue = options["--host-crop"], let viewerValue = options["--viewer-crop"] else { fail("explicit host and viewer crops must be supplied together") }
    let hostCrop = PixelCrop(hostValue, image: hostImage), viewerCrop = PixelCrop(viewerValue, image: viewerImage)
    guard let croppedHost = hostImage.cropping(to: hostCrop.rect), let croppedViewer = viewerImage.cropping(to: viewerCrop.rect) else { fail("cannot crop input images") }
    hostInput = croppedHost; viewerInput = croppedViewer
    let source = jsonObject(options["--source-geometry"])
    let readiness = jsonObject(options["--readiness"])
    let observer = readiness?["observer"] as? [String: Any]
    let calibration = jsonObject(options["--calibration"])
    let binding: [String: Any] = [
        "host_image": ["width": hostImage.width, "height": hostImage.height],
        "viewer_image": ["width": viewerImage.width, "height": viewerImage.height],
        "host_crop": hostCrop.values, "viewer_crop": viewerCrop.values,
        "source_content_rect_points": source?["content_rect_points"] ?? NSNull(),
        "source_display_size_points": source?["display_size_points"] ?? NSNull(),
        "requested_host": readiness?["requested_host"] ?? NSNull(),
        "quality_profile": readiness?["quality_profile"] ?? NSNull(),
        "pid": observer?["pid"] ?? NSNull(), "window": observer?["window"] ?? NSNull(),
        "window_geometry_points": observer?["window_geometry_points"] ?? NSNull(),
    ]
    let nonce = source?["nonce"] as? String ?? ""
    let evidence = calibration?["evidence"] as? String ?? ""
    comparisonReady = calibration?["schema"] as? String == "cmux.screen-ocr-calibration/1"
        && calibration?["verified"] as? Bool == true && !evidence.isEmpty
        && source?["schema"] as? String == "cmux.source-scene/1"
        && nonce.count == 32 && nonce.allSatisfy({ "0123456789abcdef".contains($0) })
        && readiness?["expected_nonce"] as? String == nonce && observer?["expected_nonce"] as? String == nonce
        && observer?["schema"] as? String == "cmux.presented-marker-series/2"
        && observer?["complete"] as? Bool == true && observer?["host_identity_verified"] as? Bool == true
        && observer?["nonce_observed"] as? Bool == true
        && binding.allSatisfy { !($0.value is NSNull) && sameJSON(calibration?[$0.key], $0.value) }
    cropReceipt = binding
    cropReceipt?["coordinate_space"] = "top-left pixels of each actual image, independently calibrated"
    cropReceipt?["viewer_pixels_per_host_pixel"] = [Double(viewerInput.width) / Double(hostInput.width), Double(viewerInput.height) / Double(hostInput.height)]
    cropReceipt?["host_crop_image"] = ["width": hostInput.width, "height": hostInput.height]
    cropReceipt?["viewer_crop_image"] = ["width": viewerInput.width, "height": viewerInput.height]
    cropReceipt?["current_source_nonce"] = nonce
    cropReceipt?["calibration"] = calibration ?? [:]
    cropReceipt?["comparison_ready"] = comparisonReady
    if !comparisonReady {
        cropReceipt?["reason"] = "missing or mismatched real-pair calibration, source geometry, or current selected-window readiness"
    }
}
let host = comparisonReady ? recognize(hostInput).joined(separator: "\n") : ""
let viewer = comparisonReady ? recognize(viewerInput).joined(separator: "\n") : ""
let truth = (try? String(contentsOfFile: args[3], encoding: .utf8))?
    .split(separator: "\n", omittingEmptySubsequences: false).map { normalize(String($0)) }.filter { !$0.isEmpty }
    .joined(separator: "\n") ?? ""
var report: [String: Any] = [
    "cer": comparisonReady ? cer(viewer, against: host) as Any : NSNull(),
    "host_chars": comparisonReady ? host.count as Any : NSNull(),
    "viewer_chars": comparisonReady ? viewer.count as Any : NSNull(),
    "host_cer_vs_truth": comparisonReady ? cer(host, against: truth) as Any : NSNull(),
    "viewer_cer_vs_truth": comparisonReady ? cer(viewer, against: truth) as Any : NSNull(),
    "truth_chars": truth.count,
    "host_image": ["width": hostImage.width, "height": hostImage.height],
    "viewer_image": ["width": viewerImage.width, "height": viewerImage.height],
]
if let cropReceipt {
    report["crops"] = cropReceipt
    report["comparison_ready"] = comparisonReady
}
let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
