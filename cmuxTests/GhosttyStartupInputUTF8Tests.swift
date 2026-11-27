import CmuxTerminal
import Foundation
import GhosttyKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// `cmux workspace create --command` types its command into the new shell as
/// Ghostty startup input. A command that prints an OSC 0 title therefore sets
/// the title from the bytes Ghostty wrote to the child, not from the text cmux
/// passed in, so those bytes must be the command's UTF-8.
/// https://github.com/manaflow-ai/cmux/issues/12915
@MainActor
@Suite("Ghostty startup input keeps its UTF-8", .serialized)
struct GhosttyStartupInputUTF8Tests {
    @Test(arguments: [
        "라마바OSC테스트",
        "日本語のタイトル",
        "🚀 빌드 ✅ 👩‍👩‍👧",
        "e\u{301}cole \u{1112}\u{1161}\u{11AB}",
    ])
    func oscTitleTypedAsStartupInputArrivesAsUTF8(title: String) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let payload = "\u{1b}]0;\(title)\u{07}"
            let terminal = try ScrollbackTestTerminal(initialInput: payload)
            defer { terminal.close() }
            let titles = SurfaceTitleWatch(surfaceId: terminal.surface.id)
            defer { titles.stop() }
            try await terminal.launch()

            let typed = try await terminal.inputBytesBeforeBarrier()
            #expect(typed == Data(payload.utf8))

            // The shell's `printf` writes the bytes it received back out.
            try terminal.output(typed)
            let received = await titles.title(settlingOn: title)
            #expect(received == title)
            // String equality is canonical; the scalars must survive unchanged.
            #expect(received.map { Array($0.unicodeScalars) } == Array(title.unicodeScalars))
        }
    }

    /// Bytes that are not UTF-8 never become a Latin-1 title, and the next
    /// valid title still applies.
    @Test func invalidUTF8TitleDoesNotBlockTheNextTitle() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let terminal = try ScrollbackTestTerminal()
            defer { terminal.close() }
            let titles = SurfaceTitleWatch(surfaceId: terminal.surface.id)
            defer { titles.stop() }
            try await terminal.launch()

            var output = Data("\u{1b}]0;invalid-".utf8)
            output.append(contentsOf: [0xFF, 0xFE, 0xEB, 0xB0])
            output.append(Data("\u{07}\u{1b}]0;라마바OSC테스트\u{07}".utf8))
            try terminal.output(output)

            #expect(await titles.title(settlingOn: "라마바OSC테스트") == "라마바OSC테스트")
            let latin1Titles = titles.all.filter { $0.contains("ÿ") || $0.contains("þ") }
            #expect(latin1Titles.isEmpty)
        }
    }
}

/// The titles `.ghosttyDidSetTitle` delivers for one surface.
@MainActor
private final class SurfaceTitleWatch {
    private let recorder = GhosttyTitleChangeRecorder()
    private var observer: (any NSObjectProtocol)?

    init(surfaceId: UUID) {
        let recorder = self.recorder
        observer = NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: nil
        ) { notification in
            guard let change = GhosttyTitleChange(notification: notification),
                  change.surfaceId == surfaceId else { return }
            recorder.append(change)
        }
    }

    var all: [String] { recorder.values.map(\.title) }

    /// The newest title once it equals `expected`, otherwise the newest title
    /// delivered before the deadline.
    func title(settlingOn expected: String) async -> String? {
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            if let latest = all.last, latest == expected { return latest }
            await Task.yield()
        }
        return all.last
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}
