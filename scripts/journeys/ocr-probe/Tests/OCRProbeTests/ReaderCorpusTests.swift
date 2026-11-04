import Foundation
import Testing

// R-HARNESS probe v2 (never merge, cmux-ad m10 1): compiles the text reader as feat has it (Tools/base.swift) and with
// the band fallback (Tools/fixed.swift), runs both on every stored r3-after-switch frame of the corpus (Corpus/, with
// manifest.json: what the mini read), and prints one OCRPROBE3 line per read. It asserts only that both tools ran.

struct CorpusRead: Codable {
    var image: String
    var tool: String
    var exit: Int32
    var ms: Int
    var lines: [String]
    var stderr: String
}

enum ProbeFailure: Error {
    case failed(String)
}

let probeDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

/// Runs `argv` with its output in two files; its exit status. No pipe, so no read can block.
func run(_ argv: [String], out: URL, err: URL) async throws -> Int32 {
    FileManager.default.createFile(atPath: out.path, contents: nil)
    FileManager.default.createFile(atPath: err.path, contents: nil)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: argv[0])
    process.arguments = Array(argv.dropFirst())
    process.environment = ProcessInfo.processInfo.environment.merging(["PR_MEDIA_OCR_DEBUG": "1"]) { $1 }
    process.standardOutput = try FileHandle(forWritingTo: out)
    process.standardError = try FileHandle(forWritingTo: err)
    return try await withCheckedThrowingContinuation { continuation in
        process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
        do { try process.run() } catch { continuation.resume(throwing: error) }
    }
}

func compile(_ name: String, into dir: URL) async throws -> URL {
    let binary = dir.appendingPathComponent(name)
    let source = probeDir.appendingPathComponent("Tools/\(name).swift")
    let status = try await run(["/usr/bin/xcrun", "swiftc", "-O", source.path, "-o", binary.path],
                               out: dir.appendingPathComponent("\(name).build.out"), err: dir.appendingPathComponent("\(name).build.err"))
    guard status == 0 else {
        let log = (try? String(contentsOf: dir.appendingPathComponent("\(name).build.err"), encoding: .utf8)) ?? ""
        throw ProbeFailure.failed("swiftc \(name) exited \(status): \(log.suffix(2000))")
    }
    return binary
}

@Suite(.serialized)
struct ReaderCorpusTests {
    @Test func corpus() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("ocr-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let tools = [("base", try await compile("base", into: work)), ("final", try await compile("final", into: work)),
                     ("debug", try await compile("debug", into: work))]
        let corpus = probeDir.appendingPathComponent("Corpus")
        let images = try FileManager.default.contentsOfDirectory(atPath: corpus.path).filter { $0.hasSuffix(".png") }.sorted()
        print("OCRPROBE3-ENV os=\(ProcessInfo.processInfo.operatingSystemVersionString) host=\(ProcessInfo.processInfo.hostName) images=\(images.count)")
        for image in images {
            for (tool, binary) in tools {
                let out = work.appendingPathComponent("o.txt"), err = work.appendingPathComponent("e.txt")
                let started = Date()
                let status = try await run([binary.path, corpus.appendingPathComponent(image).path], out: out, err: err)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                let row = CorpusRead(image: image, tool: tool, exit: status, ms: ms, lines: lines,
                                     stderr: (try? String(contentsOf: err, encoding: .utf8)) ?? "")
                if let data = try? JSONEncoder().encode(row), let json = String(data: data, encoding: .utf8) {
                    print("OCRPROBE3 \(json)")
                }
                #expect(status == 0, "\(tool) on \(image) exited \(status)")
            }
        }
    }
}
