// The text on each screenshot, read with Vision (macOS), for a fleet step's checks on a phone
// screen it cannot query (cmux_next_pair_e2e.py's new-chat leg): prints one JSON object,
// {path: [line, ...]}, in reading order.
//
// Usage: xcrun swift scripts/ci/screen_text.swift IMAGE.png [IMAGE.png ...]
import Foundation
import Vision

var result: [String: [String]] = [:]
for path in CommandLine.arguments.dropFirst() {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path))
    do {
        try handler.perform([request])
        let lines = (request.results ?? []).sorted { $0.boundingBox.minY > $1.boundingBox.minY }
        result[path] = lines.compactMap { $0.topCandidates(1).first?.string }
    } catch {
        result[path] = ["<error: \(error)>"]
    }
}
let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(data)
