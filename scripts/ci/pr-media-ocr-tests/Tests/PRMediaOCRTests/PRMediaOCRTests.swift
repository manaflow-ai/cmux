import Foundation
import Testing

/// scripts/ci/pr_media_ocr.swift is the text reader of the journeys' frame checks (scripts/journeys/driver.py
/// `read_text`) and of the pr-media privacy gate. These tests compile it as scripts/journeys/run.py and
/// scripts/ci/pr_media_privacy.py do (`swiftc -O`) and read real window images with it.
///
/// Frames/ holds four `debug.window_snapshot` images of the journey r3-after-switch, as the P0 journey runner stored
/// them on 2026-11-04 (cmux-ad m10 1), and a crop of one of them. In three of the frames Vision's accurate recognizer on
/// macOS 27 finds no text at all, the same on every try (35 to 48 tries of each step on the capture minis, macOS 27.0;
/// again on aws-m4pro-3, macOS 27.0.1),
/// although they show the whole terminal: the journey's frame check, which wants 3 lines, failed, and the builds
/// 15a9a010, b04b1326, 8e8f5f70 and fc51ea73 had no judgment of the journey. The fourth reads whole (23 lines).
/// macOS 26.7 (aws-m4pro-8) reads all four whole, so without the band read these tests fail only on macOS 27: run
/// them on a macOS 27 worker (`--label macos-27`).
@Suite(.serialized)
struct PRMediaOCRTests {
    /// The frames Vision read as empty: the reader returns the terminal's lines. Before the band read it printed
    /// nothing for any of them.
    @Test(arguments: [
        ("b04b1326-r3fc-dark", ["r3fc-648935 48 173", "echo base-648935", "Command Palette"]),
        ("8e8f5f70-r3fc-light", ["r3fc-869637 45 173", "echo base-869637", "r3fg-869637 45 86"]),
        ("15a9a010-r3fg-light", ["r3fg-994364 45 86", "echo base-994364", "right-994364"]),
    ])
    func emptyReadFrameReadsTheTerminal(frame: String, shows: [String]) async throws {
        let read = try await Reader.shared.read(frame)
        #expect(read.status == 0, "the reader exited \(read.status): \(read.stderr)")
        #expect(read.stderr.contains("lines in 4 bands"), "\(frame): no band read on stderr (did Vision read it whole?): \(read.stderr)")
        #expect(read.lines.count >= 3, "\(frame): \(read.lines.count) lines (the journey's frame check wants 3)")
        for text in shows {
            #expect(read.lines.contains { $0.contains(text) }, "\(frame) reads no line with \(text): \(read.lines)")
        }
    }

    /// A band that reads no text is named on stderr: in the light r3fc frame of 8e8f5f70 the bottom band (the card
    /// "Did you know? Command Palette ...") reads nothing on macOS 27, so the read is partial, and a negative frame check
    /// must not trust it (scripts/journeys/driver.py `unread_bands`). Band 3 (empty terminal rows there) shows no ink: it
    /// is named blank, not unread (review 2 of #35282, note 1).
    @Test func aBandThatReadsNothingIsNamed() async throws {
        let read = try await Reader.shared.read("8e8f5f70-r3fc-light")
        #expect(read.status == 0, "the reader exited \(read.status): \(read.stderr)")
        #expect(read.stderr.contains("lines in 4 bands; blank band 3; no text in band 4\n"),
                "band 3 is not named blank and band 4 unread: \(read.stderr)")
        #expect(!read.lines.contains { $0.contains("Command Palette") }, "band 4 read after all: \(read.lines)")
    }

    /// A band read whose silent bands show no ink is complete: in 15a9a010's r3fg frame bands 2 and 3 (empty terminal
    /// rows) read nothing on macOS 27, and they are named blank, never unread, so a negative check may hold on that read.
    /// In the 53-frame corpus of review 2 of #35282 band 3 read nothing in all 30 band reads and showed no ink in all of
    /// them; the 10 silent bands with ink were the card's band 4.
    @Test func blankBandsAreNotUnread() async throws {
        let read = try await Reader.shared.read("15a9a010-r3fg-light")
        #expect(read.status == 0, "the reader exited \(read.status): \(read.stderr)")
        #expect(read.stderr.contains("lines in 4 bands; blank bands 2, 3\n"), "bands 2 and 3 are not named blank: \(read.stderr)")
        #expect(!read.stderr.contains("no text in band"), "a blank band is named unread: \(read.stderr)")
    }

    /// An image too short for 4 bands of 16 rows is not read in bands, and each of its bands that shows ink is unread
    /// (review 2 of #35282, note 4: before, such an image read as complete and empty). `--bands-only` skips the whole
    /// read, as when Vision on macOS 27 finds nothing in it.
    @Test func aShortImageNamesEveryBandWithInkUnread() async throws {
        let read = try await Reader.shared.read("b04b1326-card-two-lines", arguments: ["--bands-only"])
        #expect(read.status == 0, "the reader exited \(read.status): \(read.stderr)")
        #expect(read.lines.isEmpty, "\(read.lines)")
        #expect(read.stderr.contains("0 lines in 4 bands; no text in bands 1, 2, 3, 4\n"), "\(read.stderr)")
    }

    /// An image whose whole read gives 1 or 2 lines is not read in bands either (only a whole read of no line is).
    @Test func aFewLinesAreNotReadInBands() async throws {
        let read = try await Reader.shared.read("b04b1326-card-two-lines")
        #expect(read.status == 0, "the reader exited \(read.status): \(read.stderr)")
        #expect(read.stderr.isEmpty, "a readable image went to the band read: \(read.stderr)")
        #expect((1...2).contains(read.lines.count), "\(read.lines)")
        #expect(read.lines.joined(separator: " ").contains("Palette"), "\(read.lines)")
    }

    /// A frame whose whole image reads is never read in bands: the reader's output is the whole read, and it says
    /// nothing on stderr.
    @Test func readableFrameIsReadWhole() async throws {
        let read = try await Reader.shared.read("b04b1326-r3fg-dark")
        #expect(read.status == 0, "the reader exited \(read.status): \(read.stderr)")
        #expect(read.stderr.isEmpty, "a readable frame went to the band read: \(read.stderr)")
        #expect(read.lines.count >= 20, "\(read.lines)")
        for text in ["r3fg-648935 48 86", "echo right-648935", "Command Palette"] {
            #expect(read.lines.contains { $0.contains(text) }, "no line with \(text): \(read.lines)")
        }
    }

    /// The command line of the r3fc step sits on the edge of the first two bands (rows 200 to 216 of a 895 and an
    /// 836 pixel frame): both bands read it, and it comes back once.
    @Test(arguments: ["b04b1326-r3fc-dark", "8e8f5f70-r3fc-light"])
    func lineOnABandEdgeComesBackOnce(frame: String) async throws {
        let read = try await Reader.shared.read(frame)
        let command = read.lines.filter { $0.contains("printf") && $0.lowercased().contains("r3fcw") }
        #expect(command.count == 1, "\(frame): the r3fc command line read \(command.count) times: \(read.lines)")
    }
}

struct ReadResult {
    var status: Int32
    var lines: [String]
    var stderr: String
}

enum ReaderError: Error, CustomStringConvertible {
    case compile(String)

    var description: String {
        switch self {
        case .compile(let log): "swiftc pr_media_ocr.swift failed: \(log)"
        }
    }
}

/// The reader, compiled once per test run into a temporary folder (removed when the test process exits), and run on
/// one frame at a time.
actor Reader {
    static let shared = Reader()
    static let workRoot = FileManager.default.temporaryDirectory.appendingPathComponent("pr-media-ocr-tests-\(UUID().uuidString)")

    private var binary: URL?
    private let work = Reader.workRoot

    static let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let source = here.appendingPathComponent("../../../pr_media_ocr.swift").standardizedFileURL

    func read(_ frame: String, arguments: [String] = []) async throws -> ReadResult {
        let tool = try await compiled()
        let image = Self.here.appendingPathComponent("Frames/\(frame).png")
        let (status, out, err) = try await run([tool.path] + arguments + [image.path], name: frame)
        let lines = out.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return ReadResult(status: status, lines: lines, stderr: err)
    }

    private func compiled() async throws -> URL {
        if let binary { return binary }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: Reader.workRoot) }
        let tool = work.appendingPathComponent("pr-media-ocr")
        let (status, _, err) = try await run(["/usr/bin/xcrun", "swiftc", "-O", Self.source.path, "-o", tool.path], name: "swiftc")
        guard status == 0 else { throw ReaderError.compile(String(err.suffix(3000))) }
        binary = tool
        return tool
    }

    /// Runs `argv` with its output in files (no pipe that could fill and block); its status, stdout and stderr.
    private func run(_ argv: [String], name: String) async throws -> (Int32, String, String) {
        let out = work.appendingPathComponent("\(name).out"), err = work.appendingPathComponent("\(name).err")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.standardOutput = try FileHandle(forWritingTo: out)
        process.standardError = try FileHandle(forWritingTo: err)
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        let text = { (url: URL) in (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
        return (status, text(out), text(err))
    }
}
