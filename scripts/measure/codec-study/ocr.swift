// The codec study's text legibility (README.md): Vision OCR (accurate, no language correction) of
// each decoded frame against the OCR of its lossless original, as a character error rate: edit
// distance / the original's characters. The same recognizer and the same normalizing as
// scripts/measure/screen-stream-eval/ocr.swift, so the two harnesses' numbers compare.
//
//   swiftc -O -o codec-study-ocr ocr.swift
//   codec-study-ocr PAIRS_JSONL OUT_JSONL [JOBS]
//
// PAIRS_JSONL: one {"id", "ref", "cand"} per line (PNG paths). Each reference is read once. JOBS
// (default 4) frames are recognized at a time; OCR is not timed, so running several is fine.

import AppKit
import Foundation
import ImageIO
import Vision

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("codec-study-ocr: \(message)\n".utf8))
    exit(2)
}

func image(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

func normalize(_ line: String) -> String {
    line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
}

/// The recognized lines, top to bottom, then left to right, joined by newlines.
func recognize(_ path: String) -> String? {
    guard let image = image(path) else { return nil }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { return nil }
    let observations = (request.results ?? []).sorted {
        abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.004 ? $0.boundingBox.midY > $1.boundingBox.midY : $0.boundingBox.minX < $1.boundingBox.minX
    }
    return observations.compactMap { $0.topCandidates(1).first?.string }.map(normalize).filter { !$0.isEmpty }.joined(separator: "\n")
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

let args = CommandLine.arguments
guard args.count == 3 || args.count == 4 else { fail("usage: codec-study-ocr PAIRS_JSONL OUT_JSONL [JOBS]") }
let jobs = args.count == 4 ? max(1, Int(args[3]) ?? 4) : 4
guard let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { fail("cannot read \(args[1])") }
let pairs: [[String: String]] = text.split(separator: "\n").compactMap {
    (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: String]
}

/// Shared results across the OCR workers.
final class Store: @unchecked Sendable {
    let lock = NSLock()
    var refText = [String: String]()
    var lines: [String]
    init(_ count: Int) { lines = [String](repeating: "", count: count) }
}

// The references first (each once), then every candidate against its reference.
let refs = Array(Set(pairs.compactMap { $0["ref"] })).sorted()
let store = Store(pairs.count)
DispatchQueue.concurrentPerform(iterations: refs.count) { index in
    let recognized = recognize(refs[index]) ?? ""
    store.lock.lock(); store.refText[refs[index]] = recognized; store.lock.unlock()
}
let semaphore = DispatchSemaphore(value: jobs)
let group = DispatchGroup()
for (index, pair) in pairs.enumerated() {
    semaphore.wait()
    group.enter()
    DispatchQueue.global().async {
        defer { semaphore.signal(); group.leave() }
        guard let id = pair["id"], let ref = pair["ref"], let cand = pair["cand"] else { return }
        store.lock.lock(); let reference = store.refText[ref] ?? ""; store.lock.unlock()
        var record: [String: Any] = ["id": id, "ref_chars": reference.count]
        if let candidate = recognize(cand) {
            record["cand_chars"] = candidate.count
            record["cer"] = reference.isEmpty ? (candidate.isEmpty ? 0.0 : 1.0) : Double(distance(Array(candidate), Array(reference))) / Double(reference.count)
        } else {
            record["error"] = "could not read \(cand)"
        }
        let json = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        store.lock.lock(); store.lines[index] = String(decoding: json, as: UTF8.self); store.lock.unlock()
    }
}
group.wait()
try! (store.lines.filter { !$0.isEmpty }.joined(separator: "\n") + "\n").write(toFile: args[2], atomically: true, encoding: .utf8)
