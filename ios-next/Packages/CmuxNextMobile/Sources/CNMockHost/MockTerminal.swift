import CNCore
import Foundation

struct MockTerminal {
    enum Mode { case shell, top, inputEcho }

    var info: Terminal
    var mode: Mode
    var scrollback = Data()
    var line = ""
    /// 0 = normal, 1 = after ESC, 2 = inside CSI.
    var escapeState = 0
    var streams: Set<UInt32> = []
    var animation: Task<Void, Never>?
    var tick = 0
    var shell = MockShell()

    static let maxScrollback = 128 * 1024
}

/// Canned shell behavior with real-looking ANSI output.
struct MockShell {
    var directory = "~/src/cmux"
    var branch = "main"

    var prompt: String {
        "\u{1B}[1;36m\(directory)\u{1B}[0m \u{1B}[35m\(branch)\u{1B}[0m \u{1B}[1;32m❯\u{1B}[0m "
    }

    enum Outcome {
        case output(String)
        case clear
        case startTop
        /// Alternate screen that prints every input byte it receives;
        /// `mouse` also enables SGR mouse reporting (wheel tests).
        case startInputEcho(mouse: Bool)
        /// A codex-like full-screen TUI: prompt box near the bottom, cursor in
        /// it, and a footer hint on the last row (key bar overlap tests).
        case startFooterTUI
        case exit
    }

    private let blue = "\u{1B}[1;34m", green = "\u{1B}[1;32m", reset = "\u{1B}[0m", dim = "\u{1B}[2m"
    private let yellow = "\u{1B}[33m", red = "\u{1B}[31m", cyan = "\u{1B}[36m", bold = "\u{1B}[1m"

    var lsOutput: String {
        let entries: [(String, String)] = [
            ("App", blue), ("Packages", blue), ("Sources", blue), ("Tests", blue), ("docs", blue), ("scripts", blue),
            ("CHANGELOG.md", ""), ("LICENSE", ""), ("Package.swift", ""), ("README.md", ""), ("build.sh", green), ("bootstrap", green),
        ]
        var out = ""
        for (i, (name, color)) in entries.enumerated() {
            let padded = name.padding(toLength: 15, withPad: " ", startingAt: 0)
            out += color + padded.replacingOccurrences(of: name, with: name + reset)
            if i % 4 == 3 { out += "\r\n" }
        }
        return out
    }

    var lsLongOutput: String {
        let rows: [(String, String, String, String)] = [
            ("drwxr-xr-x", "  14", "Oct  7 18:02", blue + "App" + reset),
            ("drwxr-xr-x", "   9", "Oct  8 09:41", blue + "Packages" + reset),
            ("drwxr-xr-x", "  31", "Oct  8 10:12", blue + "Sources" + reset),
            ("drwxr-xr-x", "  12", "Oct  6 22:47", blue + "Tests" + reset),
            ("-rw-r--r--", "   1", "Oct  2 11:20", "Package.swift"),
            ("-rw-r--r--", "   1", "Sep 29 16:05", "README.md"),
            ("-rwxr-xr-x", "   1", "Oct  1 08:58", green + "build.sh" + reset),
        ]
        var out = "total 96\r\n"
        for (perm, links, date, name) in rows {
            out += "\(perm)\(links) aziz  staff   \(String(Int.random(in: 128...9_600)).leftPad(5)) \(date) \(name)\r\n"
        }
        return out
    }

    mutating func run(_ commandLine: String) -> Outcome {
        let trimmed = commandLine.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ").map(String.init)
        guard let cmd = parts.first else { return .output("") }
        switch cmd {
        case "ls":
            return .output(parts.contains(where: { $0.hasPrefix("-") && $0.contains("l") }) ? lsLongOutput : lsOutput + "\r\n")
        case "pwd":
            return .output(directory.replacingOccurrences(of: "~", with: "/Users/aziz") + "\r\n")
        case "whoami":
            return .output("aziz\r\n")
        case "date":
            let f = DateFormatter()
            f.dateFormat = "EEE MMM d HH:mm:ss zzz yyyy"
            return .output(f.string(from: Date()) + "\r\n")
        case "echo":
            return .output(parts.dropFirst().joined(separator: " ") + "\r\n")
        case "clear":
            return .clear
        case "top", "htop":
            return .startTop
        case "mousetest":
            return .startInputEcho(mouse: true)
        case "alttest":
            return .startInputEcho(mouse: false)
        case "footertest":
            return .startFooterTUI
        case "exit", "logout":
            return .exit
        case "cd":
            directory = parts.count > 1 ? (parts[1] == "~" ? "~" : "\(directory)/\(parts[1])") : "~"
            return .output("")
        case "git":
            switch parts.dropFirst().first {
            case "status":
                return .output("""
                On branch \(branch)\r
                Your branch is up to date with '\(red)origin/\(branch)\(reset)'.\r
                \r
                Changes not staged for commit:\r
                  (use "git add <file>..." to update what will be committed)\r
                \t\(red)modified:   Sources/Terminal/TerminalSurface.swift\(reset)\r
                \t\(red)modified:   Sources/Browser/BrowserPane.swift\(reset)\r
                \r
                Untracked files:\r
                \t\(red)Tests/TerminalResizeTests.swift\(reset)\r
                \r
                no changes added to commit (use "git add" and/or "git commit -a")\r

                """)
            case "log":
                return .output("""
                \(yellow)4f2a9c1\(reset) (\(cyan)HEAD -> \(branch)\(reset)) terminal: debounce resize during rotation\r
                \(yellow)b81d0e7\(reset) browser: ack-paced frame streaming\r
                \(yellow)0c3e5aa\(reset) agents: render plan entries\r
                \(yellow)e97f412\(reset) chief: typing indicators\r
                \(yellow)7a1b2c3\(reset) link: 16 KiB lane fragmentation\r

                """)
            default:
                return .output("usage: git [status|log]\r\n")
            }
        case "cat":
            return .output("\(bold)# cmux\(reset)\r\n\r\nThe terminal built for coding agents.\r\n\r\n\(dim)See docs/ for setup.\(reset)\r\n")
        case "swift", "npm", "make", "./build.sh":
            return .output("""
            \(dim)[1/4]\(reset) Resolving dependencies\r
            \(dim)[2/4]\(reset) Compiling CNCore (14 files)\r
            \(dim)[3/4]\(reset) Compiling CNTransport (9 files)\r
            \(dim)[4/4]\(reset) Linking cmux\r
            \(green)✓\(reset) Build complete (6.42s)\r

            """)
        case "help":
            return .output("demo shell: ls, ls -la, pwd, cd, git status, git log, cat, date, echo, top, clear, exit\r\n")
        default:
            return .output("zsh: command not found: \(cmd)\r\n")
        }
    }

    /// One full `top`-like screen, redrawn in place.
    func topScreen(tick: Int, cols: Int, rows: Int) -> String {
        let width = max(40, cols)
        func line(_ s: String) -> String { s + "\u{1B}[K\r\n" }
        let load = String(format: "%.2f %.2f %.2f", 2.1 + sin(Double(tick) / 3) * 0.6, 2.4 + cos(Double(tick) / 5) * 0.3, 2.2)
        var out = "\u{1B}[H"
        out += line("\(bold)Processes:\(reset) 612 total, 4 running, 608 sleeping, 3184 threads   \(dim)\(Self.clock())\(reset)")
        out += line("Load Avg: \(load)  CPU usage: \(String(format: "%.1f", 12 + Double(tick % 7) * 1.7))% user, 6.3% sys, \(String(format: "%.1f", 80 - Double(tick % 7) * 1.7))% idle")
        out += line("PhysMem: 41G used (3.2G wired, 1.1G compressor), 22G unused.")
        out += line("")
        let header = "PID    COMMAND          %CPU  TIME     #TH   MEM    STATE"
        out += line("\u{1B}[7m" + header.padding(toLength: width, withPad: " ", startingAt: 0) + reset)
        let procs: [(Int, String, Double, Int, String)] = [
            (8123, "cmux", 18.4, 42, "812M"), (8130, "cmux-next-host", 9.7, 18, "164M"), (912, "WindowServer", 7.2, 23, "1.1G"),
            (8201, "node", 5.9, 12, "402M"), (8244, "claude", 4.4, 16, "288M"), (8302, "Google Chrome", 3.1, 31, "740M"),
            (8399, "swift-frontend", 2.8, 4, "1.6G"), (433, "mds_stores", 1.2, 7, "96M"), (8410, "zsh", 0.3, 1, "4M"),
            (1, "launchd", 0.1, 4, "22M"),
        ]
        var rowsOut = procs.map { p -> (Int, String, Double, Int, String) in
            var p = p
            p.2 = max(0, p.2 + sin(Double(tick + p.0) / 2.3) * 2.5)
            return p
        }
        rowsOut.sort { $0.2 > $1.2 }
        for (pid, name, cpu, threads, mem) in rowsOut.prefix(max(3, rows - 7)) {
            let cpuColor = cpu > 10 ? red : (cpu > 5 ? yellow : "")
            let state = cpu > 5 ? "\(green)running\(reset)" : "sleeping"
            out += line(String(pid).padding(toLength: 7, withPad: " ", startingAt: 0)
                + name.padding(toLength: 17, withPad: " ", startingAt: 0)
                + cpuColor + String(format: "%5.1f", cpu) + reset
                + "  " + String(format: "%02d:%02d.%02d", (tick / 60 + pid % 17) % 60, tick % 60, pid % 100)
                + "  " + String(threads).leftPad(3) + "   " + mem.padding(toLength: 6, withPad: " ", startingAt: 0) + " " + state)
        }
        out += "\u{1B}[J"
        return out
    }

    static func clock() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

extension String {
    func leftPad(_ n: Int) -> String {
        count >= n ? self : String(repeating: " ", count: n - count) + self
    }
}
