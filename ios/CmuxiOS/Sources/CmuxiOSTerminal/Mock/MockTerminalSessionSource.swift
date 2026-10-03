import Foundation

/// A terminal owner for demos and tests until the transport engine lands:
/// a tiny line-discipline shell that echoes typed keys and answers a few
/// commands. It behaves like a session host: snapshot first, then bytes.
public actor MockTerminalSessionSource: TerminalSessionSource {
    private var continuations: [String: AsyncStream<TerminalChannelEvent>.Continuation] = [:]
    private var line = ""
    private let prompt = "\u{1B}[1mlawrence@mini\u{1B}[0m \u{1B}[2m~/fun/cmux\u{1B}[0m % "

    public static let demo = TerminalRef(host: "host_mock", terminal: "term_mock", title: "zsh", hostName: "Mac mini")

    public init() {}

    public func terminals() -> [TerminalRef] { [Self.demo] }

    public func attach(_ terminal: TerminalRef) -> AsyncStream<TerminalChannelEvent> {
        let (stream, continuation) = AsyncStream<TerminalChannelEvent>.makeStream()
        continuations[terminal.id] = continuation
        continuation.yield(.path(.lan, rttMilliseconds: 3))
        continuation.yield(.snapshot(Data(snapshotText.utf8), cols: 80, rows: 24))
        return stream
    }

    public func setPresence(_ terminal: TerminalRef, visible: Bool, cols: Int, rows: Int) {}

    public func send(_ input: Data, to terminal: TerminalRef) {
        guard let continuation = continuations[terminal.id] else { return }
        var out = ""
        for scalar in String(decoding: input, as: UTF8.self).unicodeScalars {
            switch scalar {
            case "\r", "\n":
                out += "\r\n" + respond(to: line) + prompt
                line = ""
            case "\u{7F}", "\u{08}":
                if !line.isEmpty { line.removeLast(); out += "\u{08} \u{08}" }
            default:
                line.unicodeScalars.append(scalar)
                out.unicodeScalars.append(scalar)
            }
        }
        if !out.isEmpty { continuation.yield(.bytes(Data(out.utf8))) }
    }

    public func detach(_ terminal: TerminalRef) {
        continuations[terminal.id]?.finish()
        continuations[terminal.id] = nil
    }

    private var snapshotText: String {
        "\u{1B}[2J\u{1B}[H" +
        "Last login: Thu Oct  2 07:58:12 on ttys004\r\n" +
        prompt + "git status --short\r\n" +
        " \u{1B}[31mM\u{1B}[0m ios/CmuxiOS/Package.swift\r\n" +
        "\u{1B}[32m??\u{1B}[0m ios/CmuxiOS/Sources/CmuxiOSTerminal/Ghostty/\r\n" +
        prompt
    }

    private func respond(to command: String) -> String {
        switch command.trimmingCharacters(in: .whitespaces) {
        case "": ""
        case "ls": "Package.swift  Sources  Tests\r\n"
        case "date": "\(Date())\r\n"
        default: "zsh: command not found: \(command)\r\n"
        }
    }
}
