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
      printf '@tmux2\\t%s\\n' "$T"
      "$T" list-sessions -F 'S\t#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_activity}' 2>/dev/null
      "$T" list-windows -a -F 'W2\t#{session_name}\t#{window_index}\t#{window_active}\t#{session_id}\t#{window_id}\t#{pid}\t#{start_time}\t#{window_name}' 2>/dev/null
      "$T" list-panes -a -F 'P2\t#{window_id}\t#{pane_id}\t#{pane_active}' 2>/dev/null
      "$T" list-windows -a -F 'L2\t#{window_id}\t#{window_layout}' 2>/dev/null
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
        var modernSessions = Set<String>()
        var windows: [String: [SSHDiscoveredSession.Window]] = [:]
        var activePanes: [String: String] = [:]
        var ambiguousPanes = Set<String>()
        var paneIDs: [String: Set<String>] = [:]
        var layouts: [String: SSHTmuxLayout] = [:]
        var invalidLayouts = Set<String>()
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
                case "@tmux2":
                    guard let binary else { section = ""; continue }
                    tmux = binary
                case "@tmux": tmux = binary ?? .tmux
                case "@screen": screen = binary ?? .screen
                case "@cmux-tui": cmux = binary ?? .cmuxTUI
                default: break
                }
                continue
            }
            switch section {
            case "@tmux", "@tmux2":
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if fields.first == "S", fields.count >= 5, let name = SSHSessionName(validating: fields[1]) {
                    if section == "@tmux2" { modernSessions.insert(name.rawValue) }
                    tmuxSessions.append(SSHDiscoveredSession(
                        kind: .tmux, name: name, target: .tmux(binary: tmux, session: name, window: nil), windows: [],
                        isAttached: (Int(fields[3]) ?? 0) > 0, activity: Int64(fields[4])))
                } else if fields.first == "W2", fields.count >= 9, let name = SSHSessionName(validating: fields[1]),
                          let index = Int(fields[2]), index >= 0,
                          let pid = UInt32(fields[6]), let start = UInt64(fields[7]),
                          let window = SSHTmuxWindow(sessionID: fields[4], windowID: fields[5], serverPID: pid, serverStart: start) {
                    windows[name.rawValue, default: []].append(SSHDiscoveredSession.Window(
                        index: index, name: String(fields[8...].joined(separator: "\t").prefix(200)), isActive: fields[3] == "1",
                        target: .tmuxControl(binary: tmux, window: window)))
                } else if fields.first == "P2", fields.count >= 4,
                          SSHTmuxWindow.validID(fields[1], prefix: "@"),
                          SSHTmuxWindow.validID(fields[2], prefix: "%"),
                          (fields[3] == "0" || fields[3] == "1") {
                    paneIDs[fields[1], default: []].insert(fields[2])
                    // A split window has several panes. Keep only an
                    // unambiguous active pane so control mode can target the
                    // host-selected pane without guessing by list order.
                    if fields[3] == "1" {
                        if activePanes[fields[1]] != nil { ambiguousPanes.insert(fields[1]) }
                        activePanes[fields[1]] = fields[2]
                    }
                } else if fields.first == "L2", fields.count >= 2,
                          SSHTmuxWindow.validID(fields[1], prefix: "@") {
                    let id = fields[1]
                    if fields.count == 3, let layout = SSHTmuxLayout(validating: fields[2]),
                       layouts[id].map({ $0 == layout }) ?? true, !invalidLayouts.contains(id) {
                        layouts[id] = layout
                    } else {
                        layouts[id] = nil
                        invalidLayouts.insert(id)
                    }
                } else if section == "@tmux", fields.first == "W", fields.count >= 5, let name = SSHSessionName(validating: fields[1]),
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
            var discovered = (windows[tmuxSessions[i].name.rawValue] ?? []).sorted { $0.index < $1.index }
            if modernSessions.contains(tmuxSessions[i].name.rawValue) {
                discovered = discovered.compactMap { item in
                    guard case .tmuxControl(let binary, let window) = item.target,
                          !ambiguousPanes.contains(window.windowID),
                          let paneID = activePanes[window.windowID],
                          let targeted = window.targetingPane(paneID) else { return nil }
                    var item = item
                    item.target = .tmuxControl(binary: binary, window: targeted)
                    // Discovery commands are separate reads. Do not expose
                    // geometry when the pane inventory changed between them.
                    if let layout = layouts[window.windowID],
                       Set(layout.panes.map(\.id)) == paneIDs[window.windowID] {
                        item.layout = layout
                    }
                    return item
                }
            }
            tmuxSessions[i].windows = discovered
            if modernSessions.contains(tmuxSessions[i].name.rawValue), let first = discovered.first {
                tmuxSessions[i].target = first.target
            }
        }
        // A malformed or disappeared modern window never downgrades to the
        // name-based PTY attachment path.
        tmuxSessions.removeAll { modernSessions.contains($0.name.rawValue) && $0.windows.isEmpty }
        return tmuxSessions + screens + cmuxSessions
    }
}
