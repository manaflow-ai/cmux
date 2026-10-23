// Text boxes for the nightly visual gate (scripts/cmux-next/visual-gate/visual_gate.py).
//
//     ocr_boxes IMAGE...
//
// Prints one JSON object keyed by IMAGE:
//
//   {"width": W, "height": H, "observations": [{
//       "text", "confidence", "box": [x, y, w, h],
//       "misspelled": [words the English spell checker does not know],
//       "reread": {"lines": [{"text", "box"}], "misspelled": [...]}   (lines of 8+ characters only)
//   }]}
//
// Boxes are in image pixels with the origin at the top left (Vision's are
// normalized, origin bottom left). Recognition settings match
// scripts/ci/pr_media_ocr.swift. Two pieces of text drawn over each other
// rarely come back as two overlapping boxes: Vision reads them as one line,
// taller than its neighbours and garbled. `reread` is the same line cut out,
// scaled up 3x and read again: two ordinary lines Vision ran together read
// cleanly there (as lines stacked one above the other), text drawn over
// text stays garbled or comes back as lines on top of each other. The gate
// decides; this only reports. Compiled ad hoc with `swiftc -O` on the Mac that took the
// stills; the gate runs anywhere on the JSON.
import AppKit
import Foundation
import ImageIO
import Vision

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ocr_boxes: \(message)\n".utf8))
    exit(2)
}

func recognize(_ image: CGImage) throws -> [VNRecognizedTextObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image).perform([request])
    return request.results ?? []
}

let speller = NSSpellChecker.shared
speller.setLanguage("en")

/// Runs of three or more letters (split at anything else: `filfOTES.md` is
/// checked as `filfOTES`) the English spell checker does not know.
func misspelled(_ text: String) -> [String] {
    text.split(whereSeparator: { !$0.isLetter }).map(String.init).filter { run in
        run.count >= 3 && speller.checkSpelling(of: run, startingAt: 0).location != NSNotFound
    }
}

/// `rect` (pixels, origin top left, padded) of `image`, scaled up `factor` times, and the
/// part of the image it shows.
func upscaledCrop(_ image: CGImage, _ rect: CGRect, factor: CGFloat) -> (image: CGImage, cut: CGRect)? {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let cut = rect.insetBy(dx: -6, dy: -4).integral.intersection(bounds)
    guard !cut.isEmpty, let piece = image.cropping(to: cut) else { return nil }
    let width = Int(cut.width * factor), height = Int(cut.height * factor)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.interpolationQuality = .high
    context.draw(piece, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage().map { ($0, cut) }
}

guard CommandLine.arguments.count >= 2 else { fail("usage: ocr_boxes IMAGE...") }

var out: [String: Any] = [:]
for path in CommandLine.arguments.dropFirst() {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { fail("cannot read \(path)") }
    let width = Double(image.width), height = Double(image.height)
    func pixels(_ box: CGRect) -> CGRect {
        CGRect(x: (box.minX * width).rounded(), y: ((1 - box.maxY) * height).rounded(),
               width: (box.width * width).rounded(), height: (box.height * height).rounded())
    }
    let observations: [VNRecognizedTextObservation]
    do {
        observations = try recognize(image)
    } catch {
        fail("\(path): \(error)")
    }
    var rows: [[String: Any]] = []
    for observation in observations {
        guard let best = observation.topCandidates(1).first else { continue }
        let rect = pixels(observation.boundingBox)
        var row: [String: Any] = [
            "text": best.string,
            "confidence": Double(best.confidence),
            "box": [rect.minX, rect.minY, rect.width, rect.height],
            "misspelled": misspelled(best.string),
        ]
        if best.string.count >= 8, let crop = upscaledCrop(image, rect, factor: 3),
           let again = try? recognize(crop.image) {
            var lines: [[String: Any]] = []
            var unknown: [String] = []
            for line in again {
                guard let text = line.topCandidates(1).first?.string else { continue }
                // Back in the still's pixels, origin top left.
                let b = line.boundingBox, cut = crop.cut
                lines.append(["text": text, "box": [
                    (cut.minX + b.minX * cut.width).rounded(), (cut.minY + (1 - b.maxY) * cut.height).rounded(),
                    (b.width * cut.width).rounded(), (b.height * cut.height).rounded(),
                ]])
                unknown += misspelled(text)
            }
            row["reread"] = ["lines": lines, "misspelled": unknown]
        }
        rows.append(row)
    }
    out[path] = ["width": Int(width), "height": Int(height), "observations": rows]
}
let data = try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data("\n".utf8))
