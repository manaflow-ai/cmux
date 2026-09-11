import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Tests the OSC 777/9 desktop-notification interceptor used on mirrored
/// `%output` (issue #833). The filter must strip a complete notification
/// sequence (reporting `(title, body)`), survive chunk splits at any byte,
/// pass every other OSC through byte-identical, and never buffer an
/// unfinished candidate past its ceiling.
///
/// Assertions compare raw `Data` (not UTF-8-decoded strings): the filter is a
/// byte-stream transform, and `String(decoding:as:)` silently replaces invalid
/// UTF-8 — which would mask a byte-corruption regression instead of failing.
@Suite struct RemoteTmuxNotificationOSCFilterTests {
    private func run(
        _ chunks: [String]
    ) -> (output: Data, notifications: [(title: String, body: String)]) {
        var filter = RemoteTmuxNotificationOSCFilter()
        var out = Data()
        var notifications: [(title: String, body: String)] = []
        for chunk in chunks {
            out.append(filter.filter(Data(chunk.utf8)) { title, body in
                notifications.append((title, body))
            })
        }
        return (out, notifications)
    }

    private func run(
        _ s: String
    ) -> (output: Data, notifications: [(title: String, body: String)]) {
        run([s])
    }

    private func bytes(_ s: String) -> Data { Data(s.utf8) }

    private let ESC = "\u{1b}"
    private let BEL = "\u{07}"
    private var ST: String { "\(ESC)\\" }

    // MARK: - Complete sequences

    @Test func stripsBelTerminatedOsc777AndReportsTitleBody() {
        let result = run("before\(ESC)]777;notify;Build;done\(BEL)after")
        #expect(result.output == bytes("beforeafter"))
        #expect(result.notifications.count == 1)
        #expect(result.notifications.first?.title == "Build")
        #expect(result.notifications.first?.body == "done")
    }

    @Test func stripsStTerminatedOsc777AndReportsTitleBody() {
        let result = run("a\(ESC)]777;notify;T;B\(ST)z")
        #expect(result.output == bytes("az"))
        #expect(result.notifications.count == 1)
        #expect(result.notifications.first?.title == "T")
        #expect(result.notifications.first?.body == "B")
    }

    @Test func stripsOsc9WithEmptyTitle() {
        let bel = run("x\(ESC)]9;hello\(BEL)y")
        #expect(bel.output == bytes("xy"))
        #expect(bel.notifications.count == 1)
        #expect(bel.notifications.first?.title == "")
        #expect(bel.notifications.first?.body == "hello")

        let st = run("x\(ESC)]9;hello\(ST)y")
        #expect(st.output == bytes("xy"))
        #expect(st.notifications.count == 1)
        #expect(st.notifications.first?.body == "hello")
    }

    @Test func titleOnlyOsc777ReportsEmptyBody() {
        // `777;notify;<title>` with no body separator is still a notification.
        let result = run("\(ESC)]777;notify;JustTitle\(BEL)")
        #expect(result.output == bytes(""))
        #expect(result.notifications.count == 1)
        #expect(result.notifications.first?.title == "JustTitle")
        #expect(result.notifications.first?.body == "")
    }

    @Test func bodyMayContainSemicolons() {
        // Only the FIRST separator after `notify;` splits title from body.
        let result = run("\(ESC)]777;notify;t;a;b;c\(BEL)")
        #expect(result.notifications.first?.title == "t")
        #expect(result.notifications.first?.body == "a;b;c")
    }

    @Test func utf8MultibyteBodySurvives() {
        let result = run("\(ESC)]777;notify;构建;完成 ✅ émoji\(BEL)")
        #expect(result.output == bytes(""))
        #expect(result.notifications.first?.title == "构建")
        #expect(result.notifications.first?.body == "完成 ✅ émoji")
    }

    @Test func multipleNotificationsInOneChunkReportInOrder() {
        let result = run("1\(ESC)]9;first\(BEL)2\(ESC)]777;notify;t;second\(ST)3")
        #expect(result.output == bytes("123"))
        #expect(result.notifications.map { $0.body } == ["first", "second"])
    }

    // MARK: - Chunk splits

    @Test func survivesChunkSplitsAtEveryBoundary() {
        // Covers all the interesting cuts: right after ESC, inside `]777;notify;`,
        // at each semicolon, mid-title, mid-body, and before/inside the ST
        // terminator.
        let full = "X\(ESC)]777;notify;ab;cd\(ST)Y"
        let allBytes = Array(full.utf8)
        for cut in 1..<allBytes.count {
            var filter = RemoteTmuxNotificationOSCFilter()
            var out = Data()
            var notifications: [(String, String)] = []
            out.append(filter.filter(Data(allBytes[0..<cut])) { notifications.append(($0, $1)) })
            out.append(filter.filter(Data(allBytes[cut...])) { notifications.append(($0, $1)) })
            #expect(out == bytes("XY"), "split at \(cut)")
            #expect(notifications.count == 1, "split at \(cut)")
            #expect(notifications.first?.0 == "ab", "split at \(cut)")
            #expect(notifications.first?.1 == "cd", "split at \(cut)")
        }
    }

    @Test func survivesChunkSplitsWithBelTerminator() {
        let full = "X\(ESC)]9;body\(BEL)Y"
        let allBytes = Array(full.utf8)
        for cut in 1..<allBytes.count {
            var filter = RemoteTmuxNotificationOSCFilter()
            var out = Data()
            var bodies: [String] = []
            out.append(filter.filter(Data(allBytes[0..<cut])) { bodies.append($1) })
            out.append(filter.filter(Data(allBytes[cut...])) { bodies.append($1) })
            #expect(out == bytes("XY"), "split at \(cut)")
            #expect(bodies == ["body"], "split at \(cut)")
        }
    }

    @Test func survivesMultibyteSplitInsideUtf8Body() {
        // Cut inside the 3-byte UTF-8 encoding of 中.
        let full = Array("\(ESC)]9;中文\(BEL)ok".utf8)
        var filter = RemoteTmuxNotificationOSCFilter()
        var out = Data()
        var bodies: [String] = []
        out.append(filter.filter(Data(full[0..<5])) { bodies.append($1) })  // mid-中
        out.append(filter.filter(Data(full[5...])) { bodies.append($1) })
        #expect(out == bytes("ok"))
        #expect(bodies == ["中文"])
    }

    // MARK: - Pass-through

    @Test func nonNotifyOsc777SubcommandPassesVerbatim() {
        let sequence = "\(ESC)]777;other;payload\(BEL)"
        let result = run("a\(sequence)b")
        #expect(result.output == bytes("a\(sequence)b"))
        #expect(result.notifications.isEmpty)
    }

    @Test func otherOscSequencesPassVerbatim() {
        // Window title (OSC 0), hyperlink (OSC 8), clipboard (OSC 52) — both
        // terminators, byte-identical.
        for sequence in [
            "\(ESC)]0;my title\(BEL)",
            "\(ESC)]8;;https://example.com\(ST)link\(ESC)]8;;\(ST)",
            "\(ESC)]52;c;aGVsbG8=\(BEL)",
        ] {
            let result = run("L\(sequence)R")
            #expect(result.output == bytes("L\(sequence)R"))
            #expect(result.notifications.isEmpty)
        }
    }

    @Test func passThroughOscSurvivesChunkSplits() {
        let full = "L\(ESC)]0;title text\(BEL)R"
        let allBytes = Array(full.utf8)
        for cut in 1..<allBytes.count {
            var filter = RemoteTmuxNotificationOSCFilter()
            var out = Data()
            out.append(filter.filter(Data(allBytes[0..<cut])) { _, _ in })
            out.append(filter.filter(Data(allBytes[cut...])) { _, _ in })
            #expect(out == bytes(full), "split at \(cut)")
        }
    }

    @Test func csiAndOtherEscapesPassUntouched() {
        let input = "\(ESC)[31mred\(ESC)[0m \(ESC)[2J\(ESC)[H plain"
        let result = run(input)
        #expect(result.output == bytes(input))
        #expect(result.notifications.isEmpty)
    }

    @Test func interleavedOutputAroundNotificationIsByteIdentical() {
        let result = run([
            "\(ESC)[1mbold\(ESC)[0m",
            "\(ESC)]777;notify;t;b\(BEL)",
            "tail\r\n",
        ])
        #expect(result.output == bytes("\(ESC)[1mbold\(ESC)[0mtail\r\n"))
        #expect(result.notifications.count == 1)
    }

    @Test func bareEscInsideCandidateFlushesVerbatim() {
        // An OSC payload cannot legally contain a bare ESC (other than ST); the
        // malformed sequence must not be swallowed.
        let input = "\(ESC)]777;no\(ESC)[31mtify"
        let result = run(input)
        #expect(result.output == bytes(input))
        #expect(result.notifications.isEmpty)
    }

    @Test func tooShortOsc9CandidatePassesVerbatim() {
        // `ESC ] 9 BEL` (no `;`) is not a notification.
        let input = "\(ESC)]9\(BEL)"
        let result = run(input)
        #expect(result.output == bytes(input))
        #expect(result.notifications.isEmpty)
    }

    // MARK: - Buffer ceiling

    @Test func oversizedUnfinishedCandidatePassesVerbatim() {
        // A prefix-compatible sequence that exceeds the ceiling before its
        // terminator is flushed verbatim — never stripped, never retained.
        let hugeBody = String(repeating: "A", count: RemoteTmuxNotificationOSCFilter.maxBufferedBytes + 16)
        let input = "\(ESC)]9;\(hugeBody)\(BEL)after"
        let result = run(input)
        #expect(result.output == bytes(input))
        #expect(result.notifications.isEmpty)
    }

    @Test func oversizedCandidateSplitAcrossChunksPassesVerbatim() {
        let hugeBody = String(repeating: "B", count: RemoteTmuxNotificationOSCFilter.maxBufferedBytes)
        let result = run([
            "\(ESC)]777;notify;t;",
            hugeBody,
            "tail\(BEL)done",
        ])
        #expect(result.output == bytes("\(ESC)]777;notify;t;\(hugeBody)tail\(BEL)done"))
        #expect(result.notifications.isEmpty)
    }

    @Test func maxSizedCompleteNotificationStillStrips() {
        // Just under the ceiling must still work.
        let body = String(repeating: "C", count: RemoteTmuxNotificationOSCFilter.maxBufferedBytes - 64)
        let result = run("\(ESC)]9;\(body)\(BEL)")
        #expect(result.output == bytes(""))
        #expect(result.notifications.first?.body == body)
    }
}
