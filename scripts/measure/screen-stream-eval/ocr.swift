// Text sharpness for the screen stream eval: Vision OCR (accurate, no language correction) of the
// host's own screenshot and of the frame the viewer decoded, and the character error rate of the
// viewer's text against the host's: edit distance / host characters. Also each against the text
// the scene drew (TRUTH_TXT), which says how far the OCR itself is from the truth.
//
//   swiftc -O -o screen-eval-ocr ocr.swift
//   screen-eval-ocr HOST_IMAGE VIEWER_IMAGE TRUTH_TXT    (PNG, or binary PPM from cmux-rd bench)
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

let args = CommandLine.arguments
guard args.count == 4 else { fail("usage: screen-eval-ocr HOST_IMAGE VIEWER_IMAGE TRUTH_TXT") }
let hostImage = image(args[1]), viewerImage = image(args[2])
let host = recognize(hostImage).joined(separator: "\n"), viewer = recognize(viewerImage).joined(separator: "\n")
let truth = (try? String(contentsOfFile: args[3], encoding: .utf8))?
    .split(separator: "\n", omittingEmptySubsequences: false).map { normalize(String($0)) }.filter { !$0.isEmpty }
    .joined(separator: "\n") ?? ""
let report: [String: Any] = [
    "cer": cer(viewer, against: host),
    "host_chars": host.count,
    "viewer_chars": viewer.count,
    "host_cer_vs_truth": cer(host, against: truth),
    "viewer_cer_vs_truth": cer(viewer, against: truth),
    "truth_chars": truth.count,
    "host_image": ["width": hostImage.width, "height": hostImage.height],
    "viewer_image": ["width": viewerImage.width, "height": viewerImage.height],
]
let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
