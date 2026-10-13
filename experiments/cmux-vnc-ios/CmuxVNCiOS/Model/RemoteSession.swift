import CmuxVNC
import CmuxVNCDemoServer
import CoreGraphics
import Foundation
import Observation
import QuartzCore

/// One live VNC session for the remote screen: connection state, input,
/// and live stats. Frames do not go through observation (30+ per second);
/// the screen controller receives them through `onFrame`.
@MainActor
@Observable
final class RemoteSession {
    enum Phase: Equatable {
        case connecting
        case connected(VNCServerInfo)
        /// `needsSignIn`: the server wants credentials (or refused them).
        case failed(message: String, needsSignIn: Bool)
        case ended
    }

    struct LiveStats: Equatable {
        var fps = 0.0
        var kilobytesPerSecond = 0.0
        var latencyMs: Double?
        var decodeMs: Double?
        var encoding = "-"
    }

    let title: String
    private(set) var phase = Phase.connecting {
        didSet { resumeWaiters() }
    }
    @ObservationIgnored private var phaseWaiters: [CheckedContinuation<Bool, Never>] = []
    private(set) var stats = LiveStats()
    private(set) var frameSize = CGSize.zero
    var preferences: SessionPreferences
    var credentials: VNCCredentials

    @ObservationIgnored var onFrame: ((VNCFrame) -> Void)?
    @ObservationIgnored var onCursor: ((VNCCursor) -> Void)?
    @ObservationIgnored private var client: VNCClient?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let endpoint: VNCEndpoint?
    @ObservationIgnored private var demo: VNCDemoServer?
    @ObservationIgnored private var statsWindow = (start: CACurrentMediaTime(), frames: 0, bytes: 0)
    @ObservationIgnored private var heldButtons: VNCButtons = []
    /// The remote pointer in framebuffer pixels.
    @ObservationIgnored private(set) var pointer = CGPoint(x: 100, y: 100)

    /// A saved host.
    init(title: String, endpoint: VNCEndpoint, credentials: VNCCredentials, preferences: SessionPreferences) {
        self.title = title
        self.endpoint = endpoint
        self.credentials = credentials
        self.preferences = preferences
    }

    /// The built-in demo desktop on a loopback server in this app.
    init(demoPreferences: SessionPreferences) {
        title = "Demo desktop"
        endpoint = nil
        credentials = VNCCredentials()
        preferences = demoPreferences
    }

    var isDemo: Bool { endpoint == nil }

    func connect() {
        disconnect(silently: true)
        phase = .connecting
        tasks.append(Task { [weak self] in
            guard let self else { return }
            var target = endpoint
            if target == nil {
                let server = demo ?? VNCDemoServer(configuration: .init(width: 1440, height: 900, name: "cmux VNC demo desktop"))
                demo = server
                guard let port = try? await server.start() else {
                    phase = .failed(message: "The demo desktop could not start.", needsSignIn: false)
                    return
                }
                target = VNCEndpoint(host: "127.0.0.1", port: port)
            }
            guard let target else { return }
            start(VNCClient(endpoint: target, options: VNCSessionOptions(credentials: credentials, localCursor: preferences.localCursor)))
        })
    }

    private func start(_ client: VNCClient) {
        self.client = client
        statsWindow = (CACurrentMediaTime(), 0, 0)
        tasks.append(Task { [weak self] in
            for await event in client.events {
                guard let self else { return }
                switch event {
                case let .connected(info):
                    phase = .connected(info)
                    pointer = CGPoint(x: info.width / 2, y: info.height / 2)
                case let .cursor(cursor):
                    onCursor?(cursor)
                case let .disconnected(error):
                    if let error {
                        phase = .failed(message: Self.message(for: error), needsSignIn: error.needsCredentials)
                    } else {
                        phase = .ended
                    }
                case .bell, .clipboard:
                    break
                }
            }
        })
        tasks.append(Task { [weak self] in
            for await frame in client.frames {
                guard let self else { return }
                frameSize = CGSize(width: frame.width, height: frame.height)
                onFrame?(frame)
                await updateStats(client)
            }
        })
        Task { await client.connect() }
    }

    func disconnect(silently: Bool = false) {
        for task in tasks { task.cancel() }
        tasks.removeAll()
        if let client { Task { await client.disconnect() } }
        client = nil
        if !silently { phase = .ended }
    }

    /// Stops everything, including the demo server.
    func close() {
        disconnect()
        demo?.stop()
        demo = nil
    }

    private func updateStats(_ client: VNCClient) async {
        statsWindow.frames += 1
        let now = CACurrentMediaTime()
        let elapsed = now - statsWindow.start
        guard elapsed >= 0.5 else { return }
        let snapshot = await client.stats
        var next = stats
        next.fps = Double(statsWindow.frames) / elapsed
        next.kilobytesPerSecond = Double(snapshot.bytesReceived - statsWindow.bytes) / elapsed / 1024
        next.latencyMs = snapshot.lastUpdateLatencyMs
        next.decodeMs = snapshot.lastDecodeMs
        next.encoding = snapshot.rectanglesByEncoding.max { $0.value < $1.value }.map { Self.encodingName($0.key) } ?? "-"
        stats = next
        statsWindow = (now, 0, snapshot.bytesReceived)
    }

    /// Resumes when the session connects (true) or fails or ends (false).
    func waitUntilConnected() async -> Bool {
        switch phase {
        case .connected: return true
        case .failed, .ended: return false
        case .connecting: break
        }
        return await withCheckedContinuation { phaseWaiters.append($0) }
    }

    private func resumeWaiters() {
        let connected: Bool
        switch phase {
        case .connecting: return
        case .connected: connected = true
        case .failed, .ended: connected = false
        }
        let waiters = phaseWaiters
        phaseWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: connected) }
    }

    // MARK: Input

    /// Moves the pointer to framebuffer point `point`.
    func movePointer(to point: CGPoint) {
        guard let client else { return }
        pointer = clamp(point)
        let target = pointer
        Task { await client.movePointer(x: Int(target.x), y: Int(target.y)) }
    }

    func press(_ button: VNCButtons, down: Bool) {
        guard let client else { return }
        if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
        Task { await client.button(button, down: down) }
    }

    func click(_ button: VNCButtons = .left) {
        guard let client else { return }
        Task {
            await client.button(button, down: true)
            await client.button(button, down: false)
        }
    }

    func scroll(dx: Int, dy: Int) {
        guard let client, dx != 0 || dy != 0 else { return }
        Task { await client.scroll(dx: dx, dy: dy) }
    }

    func type(_ text: String, modifiers: [VNCKeysym] = []) {
        guard let client else { return }
        if modifiers.isEmpty {
            Task { await client.type(text) }
        } else {
            Task {
                for character in text { await client.chord(modifiers, VNCKeysym(character: character)) }
            }
        }
    }

    func tap(_ key: VNCKeysym, modifiers: [VNCKeysym] = []) {
        guard let client else { return }
        Task { await client.chord(modifiers, key) }
    }

    func key(_ key: VNCKeysym, down: Bool) {
        guard let client else { return }
        Task { await client.key(key, down: down) }
    }

    func refresh() {
        guard let client else { return }
        Task { await client.refresh() }
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, point.x), max(0, frameSize.width - 1)), y: min(max(0, point.y), max(0, frameSize.height - 1)))
    }

    static func message(for error: RFBError) -> String {
        switch error {
        case .passwordRequired: "This computer asks for a VNC password."
        case .credentialsRequired: "This Mac asks for an account user name and password."
        case let .authenticationFailed(reason): reason.isEmpty ? "The user name or password was not accepted." : reason
        case .connectionClosed: "The computer closed the connection."
        case let .transport(detail): "Could not reach the computer. \(detail)"
        case let .noSupportedSecurityType(types): "This server needs a sign-in method cmux VNC does not support yet (\(types))."
        case let .unsupportedProtocolVersion(version): "Not a VNC server (\(version))."
        case let .protocolViolation(detail): "The server sent something unexpected: \(detail)."
        }
    }

    static func encodingName(_ raw: Int32) -> String {
        switch RFBEncoding(rawValue: raw) {
        case .raw: "Raw"
        case .copyRect: "CopyRect"
        case .rre: "RRE"
        case .hextile: "Hextile"
        case .zlib: "Zlib"
        case .zrle: "ZRLE"
        default: "#\(raw)"
        }
    }
}
