import CmuxMobileSSH
import Foundation

/// Lists the sessions of an SSH host in one exec: tmux sessions and
/// windows (`list-sessions -F`, `list-windows -a -F`), GNU screen sessions
/// (`screen -ls`) and cmux-tui session sockets when cmux-tui is installed.
/// The script takes no input; the parser keeps only ids that pass
/// `SSHSessionName` and paths that pass `SSHRemoteBinary`.
public struct SSHSessionDiscovery: Sendable {
    public init() {}

    /// The exec command: `/bin/sh` reads the script from stdin, so it runs
    /// the same under any login shell (csh rejects newlines in quotes).
    public var command: String { "/bin/sh -s" }

    /// The script, sent on the command's stdin.
    public var input: String { Self.script + "\n" }

    static let script = """
    T=""
    for p in "$(command -v tmux 2>/dev/null)" /opt/homebrew/bin/tmux /usr/local/bin/tmux /usr/bin/tmux; do
      [ -n "$p" ] && [ -x "$p" ] && { T="$p"; break; }
    done
    if [ -n "$T" ]; then
      printf '@tmux\\t%s\\n' "$T"
      "$T" list-sessions -F 'S\t#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_activity}' 2>/dev/null
      "$T" list-windows -a -F 'W\t#{session_name}\t#{window_index}\t#{window_active}\t#{window_name}' 2>/dev/null
    fi
    if command -v screen >/dev/null 2>&1; then
      printf '@screen\\t%s\\n' "$(command -v screen)"
      screen -ls 2>/dev/null
    fi
    C=""
    for p in "$HOME/.local/bin/cmux-tui" "$(command -v cmux-tui 2>/dev/null)" /opt/homebrew/bin/cmux-tui /usr/local/bin/cmux-tui; do
      [ -n "$p" ] && [ -x "$p" ] && [ ! -d "$p" ] && { C="$p"; break; }
    done
    if [ -n "$C" ]; then
      printf '@cmux-tui\\t%s\\n' "$C"
      u=$(id -u)
      for d in "${XDG_RUNTIME_DIR:-}" "$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)" "${TMPDIR:-}" /tmp; do
        [ -n "$d" ] || continue
        s="${d%/}/cmux-tui-$u"
        [ -d "$s" ] || continue
        for f in "$s"/*.sock; do [ -S "$f" ] && printf 'C\\t%s\\n' "$f"; done
      done
    fi
    exit 0
    """

    /// Parses the script's output. Unknown or invalid lines are skipped.
    public func parse(_ output: String) -> [SSHDiscoveredSession] {
        var section = ""
        var tmux: SSHRemoteBinary = .tmux
        var screen: SSHRemoteBinary = .screen
        var cmux: SSHRemoteBinary = .cmuxTUI
        var tmuxSessions: [SSHDiscoveredSession] = []
        var windows: [String: [SSHDiscoveredSession.Window]] = [:]
        var screens: [SSHDiscoveredSession] = []
        var cmuxSessions: [SSHDiscoveredSession] = []
        var seenCmux = Set<String>()
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("@") {
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                section = parts[0]
                let binary = parts.count > 1 ? SSHRemoteBinary(validatingPath: parts[1]) : nil
                switch section {
                case "@tmux": tmux = binary ?? .tmux
                case "@screen": screen = binary ?? .screen
                case "@cmux-tui": cmux = binary ?? .cmuxTUI
                default: break
                }
                continue
            }
            switch section {
            case "@tmux":
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if fields.first == "S", fields.count >= 5, let name = SSHSessionName(validating: fields[1]) {
                    tmuxSessions.append(SSHDiscoveredSession(
                        kind: .tmux, name: name, target: .tmux(binary: tmux, session: name, window: nil), windows: [],
                        isAttached: (Int(fields[3]) ?? 0) > 0, activity: Int64(fields[4])))
                } else if fields.first == "W", fields.count >= 5, let name = SSHSessionName(validating: fields[1]),
                          let index = Int(fields[2]), index >= 0 {
                    let title = fields[4...].joined(separator: "\t")
                    windows[name.rawValue, default: []].append(SSHDiscoveredSession.Window(
                        index: index, name: String(title.prefix(200)), isActive: fields[3] == "1",
                        target: .tmux(binary: tmux, session: name, window: index)))
                }
            case "@screen":
                // `\t12345.name\t(Detached)` or `(Attached)`, `(Multi, attached)`.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let first = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init),
                      let dot = first.firstIndex(of: "."), first[..<dot].allSatisfy(\.isNumber), !first[..<dot].isEmpty,
                      let name = SSHSessionName(validating: first) else { continue }
                screens.append(SSHDiscoveredSession(
                    kind: .screen, name: name, target: .screen(binary: screen, session: name), windows: [],
                    isAttached: trimmed.lowercased().contains("attached)"), activity: nil))
            case "@cmux-tui":
                guard line.hasPrefix("C\t") else { continue }
                guard let socket = SSHCmuxTUISocket(validatingPath: String(line.dropFirst(2))),
                      seenCmux.insert(socket.session.rawValue).inserted else { continue }
                // Keep the first runtime directory's socket, matching the
                // server's precedence without deriving a path at attach time.
                cmuxSessions.append(SSHDiscoveredSession(
                    kind: .cmuxTUI, name: socket.session, target: .cmuxTUI(binary: cmux, socket: socket), windows: [],
                    isAttached: false, activity: nil))
            default:
                continue
            }
        }
        for i in tmuxSessions.indices {
            tmuxSessions[i].windows = (windows[tmuxSessions[i].name.rawValue] ?? []).sorted { $0.index < $1.index }
        }
        return tmuxSessions + screens + cmuxSessions
    }
}
