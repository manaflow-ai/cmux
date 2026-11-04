// R-INPUT scratch (never merge): Vision text with its box, one line per text: `x y w h<TAB>text`, in the image's
// pixels from its top-left. ext_rinputmenu finds the menu bar title and the menu item to click with a real mouse.
import Foundation
import ImageIO
import Vision

guard CommandLine.arguments.count == 2,
      let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    FileHandle.standardError.write(Data("ocr_boxes: usage: ocr_boxes IMAGE\n".utf8))
    exit(2)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["en-US"]
request.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: image).perform([request])
let width = Double(image.width), height = Double(image.height)
for result in request.results ?? [] {
    guard let candidate = result.topCandidates(1).first else { continue }
    let box = result.boundingBox // normalized, origin bottom-left
    let x = box.minX * width, y = (1 - box.maxY) * height, w = box.width * width, h = box.height * height
    print(String(format: "%.1f %.1f %.1f %.1f\t%@", x, y, w, h, candidate.string))
}
