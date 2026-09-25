import Foundation

// Compile the production readiness boundary against a byte-capturing terminal.
// The paste adapter models Ghostty's DECSET 2004 transport, not shell behavior:
// the Python driver feeds these bytes to real interactive shells.
@MainActor
final class TerminalSurface {
    var surface: Int? = 1
    let terminalLifecycleId = UUID()
    var startupInputGate = TerminalStartupInputGate()
    var bytes = Data()

    struct Result {
        let accepted = true
    }

    func sendInputAfterExplicitInput(_ text: String, recordsExplicitInput: Bool = true) -> Result {
        precondition(!recordsExplicitInput, "restore must not count as user input")
        bytes.append(contentsOf: text.utf8)
        return Result()
    }

    func sendTextAfterExplicitInput(_ data: Data, recordsExplicitInput: Bool = true) -> Result {
        precondition(!recordsExplicitInput, "restore must not count as user input")
        bytes.append(contentsOf: "\u{1b}[200~".utf8)
        bytes.append(data)
        bytes.append(contentsOf: "\u{1b}[201~".utf8)
        return Result()
    }
}

@main
struct RestoreInputHarness {
    @MainActor
    static func main() {
        let terminal = TerminalSurface()
        terminal.startupInputGate.stage(CommandLine.arguments[1], generation: terminal.terminalLifecycleId)
        terminal.shellDidBecomeReadyForStartupInput()
        terminal.shellDidBecomeReadyForStartupInput()
        FileHandle.standardOutput.write(terminal.bytes)
    }
}
