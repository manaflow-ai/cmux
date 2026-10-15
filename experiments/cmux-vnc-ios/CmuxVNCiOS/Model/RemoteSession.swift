import CmuxVNC
import CmuxVNCDemoServer
import CmuxVNCWebRTC
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
    @ObservationIgnored let perf = PerfLog()
    /// The session's latest counters (for the perf log).
    @ObservationIgnored private(set) var clientStats = VNCSessionStats()
    @ObservationIgnored var onCursor: ((VNCCursor) -> Void)?
    /// The server's own screen layout (ExtendedDesktopSize), when it sends one.
    @ObservationIgnored var onScreens: (([CGRect]) -> Void)?
    @ObservationIgnored private var client: VNCClient?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private let endpoint: VNCEndpoint?
    /// Set for a Mac paired over WebRTC.
    @ObservationIgnored private let pairing: VNCPairing?
    @ObservationIgnored private var demo: VNCDemoServer?
    @ObservationIgnored private var statsWindow = (start: CACurrentMediaTime(), frames: 0, bytes: 0)
    @ObservationIgnored private var heldButtons: VNCButtons = []
    /// Set for a Mac paired as a screen stream (WebRTC video + input channel).
    @ObservationIgnored private(set) var stream: ScreenStreamViewer?
    @ObservationIgnored var onVideoTrack: ((VideoTrackBox) -> Void)?
    /// Stream displays (sizes) and the one streaming.
    @ObservationIgnored var onStreamDisplays: (([CGSize], Int) -> Void)?
    private(set) var streamPath = "WebRTC"
    /// The stream dropped and is coming back on its own.
    private(set) var isReconnecting = false
    @ObservationIgnored private var reconnectAttempts = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    var isStream: Bool { pairing?.isStream == true }
    /// The saved host this session opened, so its menu choices are kept.
    @ObservationIgnored var hostID: UUID?
    /// The remote pointer in framebuffer pixels.
    @ObservationIgnored private(set) var pointer = CGPoint(x: 100, y: 100)

    /// A saved host.
    init(title: String, endpoint: VNCEndpoint, credentials: VNCCredentials, preferences: SessionPreferences) {
        self.title = title
        self.endpoint = endpoint
        self.credentials = credentials
        self.preferences = preferences
        pairing = nil
    }

    /// A Mac paired over WebRTC (its cmux-vnc-host).
    init(title: String, pairing: VNCPairing, credentials: VNCCredentials, preferences: SessionPreferences) {
        self.title = title
        endpoint = VNCEndpoint(host: "webrtc", port: 1)
        self.pairing = pairing
        self.credentials = credentials
        self.preferences = preferences
    }

    /// "WebRTC" or "Direct", for the stats line.
    var pathLabel: String { isStream ? "Video · \(streamPath)" : (pairing != nil ? "WebRTC" : (isDemo ? "Loopback" : "Direct")) }

    /// The built-in demo desktop on a loopback server in this app.
    init(demoPreferences: SessionPreferences) {
        title = "Demo desktop"
        endpoint = nil
        credentials = VNCCredentials()
        preferences = demoPreferences
        pairing = nil
    }

    var isDemo: Bool { endpoint == nil }

    func connect() {
        disconnect(silently: true)
        phase = .connecting
        if let pairing, pairing.isStream {
            connectStream(pairing)
            return
        }
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
            let options = VNCSessionOptions(credentials: credentials, localCursor: preferences.localCursor)
            start(VNCClient(endpoint: target, options: options, transport: pairing.map { WebRTCRFBTransport(pairing: $0) }))
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
                case let .screens(screens):
                    onScreens?(screens.count > 1 ? screens.map(\.frame) : [])
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
                clientStats = await client.stats
                onFrame?(frame)
                await updateStats(client)
            }
        })
        Task { await client.connect() }
    }

    // MARK: Stream

    private func connectStream(_ pairing: VNCPairing) {
        let viewer = ScreenStreamViewer(pairing: pairing)
        stream = viewer
        viewer.onVideo = { [weak self] box in Task { @MainActor in self?.onVideoTrack?(box) } }
        viewer.onDisplays = { [weak self] message in
            Task { @MainActor in
                let sizes = (message.displays ?? []).map { CGSize(width: $0.w, height: $0.h) }
                self?.onStreamDisplays?(sizes, message.current ?? 0)
            }
        }
        viewer.onPath = { [weak self] path in Task { @MainActor in self?.streamPath = path } }
        viewer.onState = { [weak self, weak viewer] message in
            Task { @MainActor in
                guard let self, let message, self.stream === viewer else { return }
                self.streamDropped(message)
            }
        }
        tasks.append(Task { [weak self] in
            do {
                try await viewer.connect()
                guard let self else { return }
                reconnectAttempts = 0
                isReconnecting = false
                viewer.setQuality(preferences.quality)
                phase = .connected(VNCServerInfo(width: 0, height: 0, name: pairing.name, nativeFormat: .bgrx,
                                                 protocolMinor: 8, securityType: 0))
                await pollStreamStats(viewer)
            } catch {
                guard let self, stream === viewer else { return }
                if isReconnecting {
                    streamDropped("Could not reach the Mac: \(error)")
                } else {
                    phase = .failed(message: "Could not reach the Mac: \(error)", needsSignIn: false)
                }
            }
        })
    }

    /// The stream ended without the user closing it: reconnect a few times
    /// (backing off) before showing the error.
    private func streamDropped(_ message: String) {
        guard reconnectAttempts < 5 else {
            isReconnecting = false
            phase = .failed(message: message, needsSignIn: false)
            return
        }
        reconnectAttempts += 1
        isReconnecting = true
        phase = .connecting
        let delay = reconnectAttempts == 1 ? 0 : min(pow(2, Double(reconnectAttempts - 2)), 8)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay)) // reconnect backoff
            guard !Task.isCancelled, let self, isReconnecting else { return }
            connect()
        }
    }

    /// The app came back to the foreground: a stream that dropped while it
    /// was suspended reconnects right away.
    func resumeIfNeeded() {
        guard isStream else { return }
        switch phase {
        case .failed(_, false), .ended:
            reconnectAttempts = 0
            isReconnecting = true
            connect()
        default:
            break
        }
    }

    /// Applies `preferences.quality` to the running stream.
    func applyQuality() {
        stream?.setQuality(preferences.quality)
    }

    /// WebRTC's own numbers, once a second, for the stats line.
    private func pollStreamStats(_ viewer: ScreenStreamViewer) async {
        var lastBytes = 0.0
        var lastTime = CACurrentMediaTime()
        while !Task.isCancelled, stream === viewer {
            try? await Task.sleep(for: .seconds(1)) // stats sampling period
            let video = await viewer.videoStats()
            let now = CACurrentMediaTime()
            var next = stats
            next.fps = video.fps ?? 0
            next.kilobytesPerSecond = (video.bytesReceived - lastBytes) / 1024 / max(now - lastTime, 0.001)
            next.latencyMs = video.rttMs
            next.encoding = [video.codec, video.decoder == "VideoToolbox" ? "HW" : video.decoder].compactMap { $0 }.joined(separator: " ")
            stats = next
            lastBytes = video.bytesReceived
            lastTime = now
        }
    }

    /// Streams display `index` (the Mac crops to it).
    func selectDisplay(_ index: Int) {
        stream?.send(ScreenInput(t: "display", i: index))
    }

    /// The pointer as a fraction of the streamed display.
    private func normalized(_ point: CGPoint) -> (Double, Double) {
        (Double(point.x / max(frameSize.width, 1)), Double(point.y / max(frameSize.height, 1)))
    }

    /// The video's pixel size (the streamed display).
    func setStreamFrameSize(_ size: CGSize) {
        frameSize = size
    }

    func disconnect(silently: Bool = false) {
        if !silently {
            reconnectTask?.cancel()
            isReconnecting = false
        }
        for task in tasks { task.cancel() }
        tasks.removeAll()
        if let client { Task { await client.disconnect() } }
        client = nil
        stream?.close()
        stream = nil
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
        if let stream {
            pointer = clamp(point)
            let (x, y) = normalized(pointer)
            stream.send(ScreenInput(t: "move", x: x, y: y, b: heldButtons.rawValue))
            return
        }
        guard let client else { return }
        pointer = clamp(point)
        let target = pointer
        Task { await client.movePointer(x: Int(target.x), y: Int(target.y)) }
    }

    func press(_ button: VNCButtons, down: Bool) {
        if let stream {
            if down { perf.input("press"); heldButtons.insert(button) } else { heldButtons.remove(button) }
            let (x, y) = normalized(pointer)
            stream.send(ScreenInput(t: "move", x: x, y: y, b: heldButtons.rawValue))
            return
        }
        guard let client else { return }
        if down { perf.input("press") }
        if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
        Task { await client.button(button, down: down) }
    }

    func click(_ button: VNCButtons = .left) {
        if let stream {
            perf.input(button == .right ? "right-click" : "click")
            let (x, y) = normalized(pointer)
            stream.send(ScreenInput(t: "move", x: x, y: y, b: heldButtons.union(button).rawValue))
            stream.send(ScreenInput(t: "move", x: x, y: y, b: heldButtons.rawValue))
            return
        }
        guard let client else { return }
        perf.input(button == .right ? "right-click" : "click")
        Task {
            await client.button(button, down: true)
            await client.button(button, down: false)
        }
    }

    func scroll(dx: Int, dy: Int) {
        if let stream, dx != 0 || dy != 0 {
            perf.input("scroll")
            let (x, y) = normalized(pointer)
            stream.send(ScreenInput(t: "scroll", x: x, y: y, dx: dx, dy: dy))
            return
        }
        guard let client, dx != 0 || dy != 0 else { return }
        perf.input("scroll")
        Task { await client.scroll(dx: dx, dy: dy) }
    }

    func type(_ text: String, modifiers: [VNCKeysym] = []) {
        if let stream {
            perf.input("type")
            if modifiers.isEmpty {
                stream.send(ScreenInput(t: "text", s: text))
            } else {
                for character in text {
                    stream.send(ScreenInput(t: "chord", k: VNCKeysym(character: character).rawValue, m: modifiers.map(\.rawValue)))
                }
            }
            return
        }
        guard let client else { return }
        perf.input("type")
        if modifiers.isEmpty {
            Task { await client.type(text) }
        } else {
            Task {
                for character in text { await client.chord(modifiers, VNCKeysym(character: character)) }
            }
        }
    }

    func tap(_ key: VNCKeysym, modifiers: [VNCKeysym] = []) {
        if let stream {
            perf.input(modifiers.isEmpty ? "key" : "shortcut")
            stream.send(ScreenInput(t: "chord", k: key.rawValue, m: modifiers.map(\.rawValue)))
            return
        }
        guard let client else { return }
        perf.input(modifiers.isEmpty ? "key" : "shortcut")
        Task { await client.chord(modifiers, key) }
    }

    func key(_ key: VNCKeysym, down: Bool) {
        if let stream {
            stream.send(ScreenInput(t: "key", k: key.rawValue, d: down))
            return
        }
        guard let client else { return }
        Task { await client.key(key, down: down) }
    }

    func refresh() {
        if let stream {
            stream.send(ScreenInput(t: "refresh"))
            return
        }
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
