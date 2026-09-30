// Vision OCR helper for the iOS e2e driver: prints the text recognized in a
// screenshot so shell steps can assert what the PHONE actually rendered,
// not what the Mac believes it sent. Compiled ad hoc with swiftc by
// ios-e2e-run.sh; kept dependency-free on purpose (no xcodebuild target).
import Foundation
import Vision
import CoreImage

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: ocr <image.png>\n".utf8))
    exit(2)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = CIImage(contentsOf: url) else {
    FileHandle.standardError.write(Data("ocr: unreadable image \(url.path)\n".utf8))
    exit(2)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["en-US"]
request.usesLanguageCorrection = false
let handler = VNImageRequestHandler(ciImage: image)
try handler.perform([request])
for observation in request.results ?? [] {
    if let candidate = observation.topCandidates(1).first {
        print(candidate.string)
    }
}
