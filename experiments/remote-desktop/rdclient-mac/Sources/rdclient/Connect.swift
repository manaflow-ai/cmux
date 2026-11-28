import CoreVideo
import Foundation

struct ConnectOptions {
    let addr: String
    let socksUnix: String?
    let workload: String
    let capture: String
    let samples: Int
    let width: Int
    let height: Int
    let maxFps: Int
    let bitrateKbps: Int
    let pixelFormat: OSType
    let keycode: UInt32
    let pings: Int
    let idleSeconds: Int
    let label: String?
    let out: String?

    init(_ a: Args) throws {
        guard let addr = a.string("addr") else { throw UsageError.message("connect needs --addr HOST:PORT") }
        self.addr = addr
        socksUnix = a.string("socks-unix")
        workload = a.string("workload", default: "marker")
        guard ["marker", "text", "motion", "idle"].contains(workload) else { throw UsageError.message("bad --workload \(workload)") }
        capture = a.string("capture", default: "damage")
        guard ["damage", "poll"].contains(capture) else { throw UsageError.message("bad --capture \(capture)") }
        samples = try a.int("samples", default: 300)
        width = try a.int("width", default: 1920)
        height = try a.int("height", default: 1080)
        maxFps = try a.int("max-fps", default: 60)
        bitrateKbps = try a.int("bitrate-kbps", default: 8000)
        let pf = a.string("pixfmt", default: "420v")
        guard pf == "420v" || pf == "420f" else { throw UsageError.message("bad --pixfmt \(pf)") }
        pixelFormat = pf == "420f" ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        keycode = UInt32(try a.int("keycode", default: 38))
        pings = try a.int("pings", default: 100)
        idleSeconds = try a.int("idle-seconds", default: 30)
        label = a.string("label")
        out = a.string("out")
    }
}

enum ConnectError: Error, CustomStringConvertible {
    case timeout(String)
    var description: String {
        switch self {
        case .timeout(let what): return "timed out waiting for \(what)"
        }
    }
}

func runConnect(_ o: ConnectOptions) throws {
    let (host, port) = try splitHostPort(o.addr)
    let utcStart = utcNow()
    let tc0 = nowNs()
    let sock = try o.socksUnix.map { try StreamSocket.socksUnix(path: $0, host: host, port: port) }
        ?? StreamSocket.tcp(host: host, port: port)
    let connectMs = ms(tc0, nowNs())
    log("connected via \(sock.kind) in \(round3(connectMs)) ms")

    let session = Session(sock: sock, pixelFormat: o.pixelFormat)
    let reader = Thread { session.runReader() }
    reader.stackSize = 4 << 20
    reader.qualityOfService = .userInteractive
    reader.start()

    let hello: [String: Any] = [
        "proto": "rdproto/0", "width": o.width, "height": o.height, "max_fps": o.maxFps,
        "bitrate_kbps": o.bitrateKbps, "workload": o.workload, "capture": o.capture, "client": "mac-vt",
    ]
    let helloBytes = try JSONSerialization.data(withJSONObject: hello, options: [.sortedKeys])
    try sock.writeAll(frame(.hello, Array(helloBytes)))
    guard session.ackReady.wait(timeout: .now() + 15) == .success, session.withLock({ session.helloAck }) != nil else {
        throw ConnectError.timeout("HELLO_ACK (\(session.withLock { "error=\(session.readerError ?? "-") bye=\(session.byeReason ?? "-")" }))")
    }
    log("hello_ack \(session.withLock { session.helloAck ?? [:] })")

    // Idle-path RTT: sequential pings, one in flight.
    for _ in 0..<o.pings {
        while session.pongReady.wait(timeout: .now()) == .success {}
        try session.sendPing(underLoad: false)
        _ = session.pongReady.wait(timeout: .now() + 2)
    }

    guard session.firstMarker.wait(timeout: .now() + 15) == .success, session.withLock({ session.lastMarker }) != nil else {
        let diag = session.withLock { "frames=\(session.frames.count) guard_failures=\(session.guardFailures) decode_errors=\(session.decodeErrors) err=\(session.readerError ?? "-")" }
        throw ConnectError.timeout("first decoded marker (\(diag))")
    }

    let cpu0 = CPUTimes.now()
    let w0 = nowNs()
    var losses = 0
    var seq: UInt32 = 0
    var rng = SystemRandomNumberGenerator()
    if o.workload == "idle" {
        // Observation window with no input; ends early only if the reader dies.
        _ = session.readerExited.wait(timeout: .now() + .seconds(o.idleSeconds))
    } else {
        for _ in 0..<o.samples {
            guard session.withLock({ session.readerError == nil && session.byeReason == nil }) else { break }
            let expected = session.withLock { session.lastMarker ?? 0 } &+ 1
            seq += 1
            let t0 = nowNs()
            session.arm(expected: expected, seq: seq, t0: t0)
            try sock.writeAll(frame(.input, inputPayload(seq: seq, kind: 1, x: 0, y: 0, code: o.keycode, tSendNs: t0)))
            if session.sampleDone.wait(timeout: .now() + .milliseconds(1000)) == .timedOut {
                if session.disarmIfPending(seq: seq) {
                    losses += 1
                } else {
                    session.sampleDone.wait()
                }
            }
            try session.sendPing(underLoad: true)
            // Protocol inter-sample wait: uniform 40..160 ms so samples do not lock to the frame cadence.
            usleep(UInt32.random(in: 40_000...160_000, using: &rng))
        }
    }
    let w1 = nowNs()
    let cpu1 = CPUTimes.now()
    session.markClosing()
    // Send BYE and half-close, then keep reading until the host closes, so the host sees the BYE
    // and the tunnel hop never holds unread data for a session that looks alive.
    try? sock.writeAll(frame(.bye, Array("done".utf8)))
    sock.shutdownWrite()
    if session.readerExited.wait(timeout: .now() + 5) == .timedOut {
        sock.shutdown()
        _ = session.readerExited.wait(timeout: .now() + 5)
    }

    let report = buildConnectReport(o, session: session, window: (w0, w1), cpu: cpu0.delta(to: cpu1),
                                     connectMs: connectMs, losses: losses, sent: Int(seq), sockKind: sock.kind,
                                     utcStart: utcStart, hello: hello)
    try emitJSON(report, to: o.out)
}
