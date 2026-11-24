// (Run 45339990503's OCR read empty because `import Foundation, Vision, AppKit` is not Swift: one module per import.)
// OCR of one screenshot: prints JSON [{"t": text, "x": cx, "y": cy}] in screenshot pixels. cmux#52200 evidence rig.
import Foundation
import Vision
import AppKit
let path = CommandLine.arguments[1]
guard let img = NSImage(contentsOfFile: path), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("[]"); exit(0) }
let w = Double(cg.width), h = Double(cg.height)
let req = VNRecognizeTextRequest(); req.recognitionLevel = .accurate; req.usesLanguageCorrection = false
do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([req]) } catch { FileHandle.standardError.write(Data("ocr: \(error)\n".utf8)) }
var out: [[String: Any]] = []
for o in req.results ?? [] { if let c = o.topCandidates(1).first { let b = o.boundingBox
  out.append(["t": c.string, "x": (b.midX) * w, "y": (1 - b.midY) * h]) } }
print(String(data: try! JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
