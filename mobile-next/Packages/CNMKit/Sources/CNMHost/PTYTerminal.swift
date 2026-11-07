#if os(macOS)
import CNMProtocol
import Darwin
import Foundation

/// A shell on a pseudo-terminal, with a bounded output history so a phone
/// that attaches later sees the screen.
final class PTYTerminal: @unchecked Sendable {
    let id: UInt32
    let cwd: String
    let createdAt = Date()
    private(set) var title: String
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var exitCode: Int32?
    private(set) var lastOutputAt: Date?

    private let lock = NSLock()
    private var masterFD: Int32 = -1
    private var pid: pid_t = 0
    private var history = Data()
    private let historyLimit = 2 * 1024 * 1024
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    /// Input not yet accepted by the pty (it is non-blocking).
    private var pendingInput = Data()
    private var processSource: DispatchSourceProcess?
    private let queue: DispatchQueue

    var onOutput: (@Sendable (Data) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?

    init(id: UInt32, cwd: String, cols: Int, rows: Int, command: String?, environment: [String: String]) throws {
        self.id = id
        self.cwd = cwd
        self.cols = min(max(cols, 2), 1000)
        self.rows = min(max(rows, 2), 1000)
        self.title = (cwd as NSString).lastPathComponent
        self.queue = DispatchQueue(label: "cnm.pty.\(id)")
        try spawn(command: command, environment: environment)
    }

    var running: Bool { lock.withLock { exitCode == nil } }

    var info: TerminalInfo {
        lock.withLock {
            TerminalInfo(
                id: id, title: title, cwd: cwd, cols: cols, rows: rows, running: exitCode == nil,
                exitCode: exitCode, createdAt: createdAt, lastOutputAt: lastOutputAt
            )
        }
    }

    /// The bytes to replay to a newly attached viewer.
    func snapshot() -> Data { lock.withLock { history } }

    func rename(_ title: String) { lock.withLock { self.title = title } }

    private func spawn(command: String?, environment: [String: String]) throws {
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let shell = environment["SHELL"] ?? "/bin/zsh"
        var argv: [String] = [shell, "-l"]
        if let command { argv = [shell, "-l", "-c", command] }
        var env = environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "cmux-next-mobile"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"

        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
        }

        let child = forkpty(&master, nil, nil, &size)
        if child < 0 { throw RPCError(code: -32010, message: "forkpty failed: \(errno)") }
        if child == 0 {
            _ = chdir(cwd)
            execve(shell, cArgs, cEnv)
            _exit(127)
        }
        pid = child
        masterFD = master
        let flags = fcntl(master, F_GETFL)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.resume()
        readSource = source

        let processSource = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: queue)
        processSource.setEventHandler { [weak self] in self?.reap() }
        processSource.resume()
        self.processSource = processSource
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(masterFD, &buffer, buffer.count)
            if count > 0 {
                let data = Data(buffer[0..<count])
                lock.withLock {
                    history.append(data)
                    // Trim in large steps (to 3/4 of the limit) so the copy
                    // happens rarely instead of on every read.
                    if history.count > historyLimit {
                        history = Data(history.suffix(historyLimit * 3 / 4))
                    }
                    lastOutputAt = Date()
                }
                onOutput?(data)
            } else {
                if count == 0 || (errno != EAGAIN && errno != EINTR) {
                    readSource?.cancel()
                }
                return
            }
        }
    }

    private func reap() {
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        let code: Int32 = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        readAvailable()
        lock.withLock { exitCode = code }
        processSource?.cancel()
        readSource?.cancel()
        writeSource?.cancel()
        writeSource = nil
        pendingInput.removeAll()
        let fd = masterFD
        masterFD = -1
        close(fd)
        onExit?(code)
    }

    /// Queues input; a write source drains it as the pty accepts bytes, so a
    /// program that isn't reading never blocks the caller (or spins).
    func write(_ data: Data) {
        queue.async { [self] in
            guard masterFD >= 0, exitCode == nil else { return }
            pendingInput.append(data)
            if pendingInput.count > 4 * 1024 * 1024 { pendingInput.removeFirst(pendingInput.count - 4 * 1024 * 1024) }
            drainInput()
        }
    }

    private func drainInput() {
        while !pendingInput.isEmpty, masterFD >= 0 {
            let written = pendingInput.withUnsafeBytes { raw in Darwin.write(masterFD, raw.baseAddress!, raw.count) }
            if written > 0 {
                pendingInput.removeFirst(written)
            } else if written < 0, errno == EINTR {
                continue
            } else {
                break
            }
        }
        if pendingInput.isEmpty {
            writeSource?.cancel()
            writeSource = nil
        } else if writeSource == nil, masterFD >= 0 {
            let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
            source.setEventHandler { [weak self] in self?.drainInput() }
            source.resume()
            writeSource = source
        }
    }

    /// Runs `body` on the pty queue with the current history, so a viewer can
    /// register before the next output is read (no bytes fall in between).
    func withSnapshot(_ body: (Data) -> Void) {
        queue.sync { body(lock.withLock { history }) }
    }

    func resize(cols: Int, rows: Int) {
        let cols = min(max(cols, 2), 1000)
        let rows = min(max(rows, 2), 1000)
        lock.withLock {
            self.cols = cols
            self.rows = rows
        }
        queue.async { [self] in
            guard masterFD >= 0, exitCode == nil else { return }
            var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(masterFD, TIOCSWINSZ, &size)
        }
    }

    func terminate() {
        guard running else { return }
        kill(pid, SIGHUP)
    }
}
#endif
