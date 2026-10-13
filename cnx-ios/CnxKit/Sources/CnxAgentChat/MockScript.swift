import CmuxAgentQuestion
import Foundation

/// Content for `MockAgentSession`: realistic text, files and diffs.
struct MockScript {
    static let historyAnswer = """
    Every link frame is a fixed 9-byte header followed by the payload:

    ```rust
    pub struct Frame {
        len: u32,       // big endian, payload length
        channel: u32,   // odd = phone, even = Mac
        kind: FrameKind,
        payload: Bytes,
    }
    ```

    | Type | Meaning | Payload |
    | --- | --- | --- |
    | `0` open | open a channel | `{"service", "args"}` |
    | `1` data | raw bytes | bytes |
    | `2` close | close a channel | `{"code", "reason"}` |
    | `3`/`4` | ping / pong | 8-byte nonce |

    The transport underneath never sees channels, so **WebRTC and WireGuard can share it unchanged**.
    """

    static let thinking = """
    The person wants a runtime switch between WebRTC and WireGuard. The frame layer is transport-agnostic, \
    so the change lives in the dialer and settings. Check how `MacLink` is created and where `TransportKind` is referenced first.
    """

    static let readSnippet = """
    pub async fn dial(config: &DialConfig) -> Result<Link> {
        let stream = webrtc::connect(config).await?;
        Ok(Link::new(stream))
    }
    """

    static let searchOutput = """
    cnx-ios/PROTOCOL.md:72:  The app exposes Settings → Connection → Transport
    cnx-ios/rust/cnx-link/src/dial.rs:14:  // TODO: TransportKind switch
    cnx-ios/CnxKit/Sources/CnxShell/Screens.swift:241:  Picker(selection: .constant(0))
    """

    static let planIntro = """
    The frame layer already hides the transport, so the switch only needs to live in the dialer and in Settings. Here's the plan:
    """

    static let plan = [
        ACPPlanEntry(content: "Add `TransportKind` with WebRTC and WireGuard cases", priority: "high"),
        ACPPlanEntry(content: "Route `LinkDialer.dial` through the selected transport", priority: "high"),
        ACPPlanEntry(content: "Run the Swift and Rust link tests", priority: "medium"),
        ACPPlanEntry(content: "Wire the Settings → Connection picker", priority: "medium"),
    ]

    static let kindPath = "cnx-ios/CnxKit/Sources/CnxTransport/TransportKind.swift"
    static let kindNew = """
    import Foundation

    /// How the phone reaches a Mac. Both produce the same framed `Link`.
    public enum TransportKind: String, CaseIterable, Codable, Sendable {
        /// Data channel `cnx-link`, TURN when no direct path exists.
        case webrtc
        /// One smoltcp TCP stream to the Mac's overlay address.
        case wireguard

        public var displayName: String {
            switch self {
            case .webrtc: "WebRTC"
            case .wireguard: "WireGuard"
            }
        }
    }
    """

    static let dialerPath = "cnx-ios/CnxKit/Sources/CnxTransport/LinkDialer.swift"
    static let dialerOld = """
    import Foundation

    /// Opens the framed link to a Mac.
    public struct LinkDialer: Sendable {
        let signaling: SignalingClient
        let iceProvider: ICEProvider

        public init(signaling: SignalingClient, iceProvider: ICEProvider) {
            self.signaling = signaling
            self.iceProvider = iceProvider
        }

        public func dial(_ mac: MacDevice) async throws -> MacLink {
            let servers = try await iceProvider.servers()
            let session = UUID()
            let channel = try await WebRTCDialer(servers: servers)
                .connect(to: mac.id, session: session, signaling: signaling)
            return MacLink(stream: channel)
        }

        public func redial(_ link: MacLink, to mac: MacDevice) async throws -> MacLink {
            await link.close(reason: "redial")
            return try await dial(mac)
        }

        func log(_ message: String) {
            Logger.link.debug("\\(message)")
        }
    }
    """

    static let dialerNew = """
    import Foundation

    /// Opens the framed link to a Mac over the selected transport.
    public struct LinkDialer: Sendable {
        let signaling: SignalingClient
        let iceProvider: ICEProvider
        let transport: @Sendable () -> TransportKind

        public init(signaling: SignalingClient, iceProvider: ICEProvider, transport: @escaping @Sendable () -> TransportKind) {
            self.signaling = signaling
            self.iceProvider = iceProvider
            self.transport = transport
        }

        public func dial(_ mac: MacDevice) async throws -> MacLink {
            let session = UUID()
            switch transport() {
            case .webrtc:
                let servers = try await iceProvider.servers()
                let channel = try await WebRTCDialer(servers: servers)
                    .connect(to: mac.id, session: session, signaling: signaling)
                return MacLink(stream: channel, kind: .webrtc)
            case .wireguard:
                let tunnel = try await WireGuardDialer(signaling: signaling)
                    .connect(to: mac.id, session: session)
                return MacLink(stream: try await tunnel.openStream(port: 7420), kind: .wireguard)
            }
        }

        public func redial(_ link: MacLink, to mac: MacDevice) async throws -> MacLink {
            await link.close(reason: "redial")
            return try await dial(mac)
        }

        func log(_ message: String) {
            Logger.link.debug("\\(message)")
        }
    }
    """

    static let swiftTestOutput = """
    Building for debugging...
    [12/12] Linking CnxTransportTests
    Test Suite 'LinkDialerTests' started.
    ✔ Test dialsWebRTCByDefault() passed (0.012 seconds)
    ✔ Test dialsWireGuardWhenSelected() passed (0.019 seconds)
    ✔ Test redialClosesTheOldLink() passed (0.004 seconds)
    ✔ Test run with 3 tests passed after 0.041 seconds.
    """

    static let cargoOutput = """
       Compiling cnx-link v0.1.0 (cnx-ios/rust/cnx-link)
        Finished `test` profile [unoptimized + debuginfo] target(s) in 6.82s
         Running unittests src/lib.rs
    running 9 tests
    test frame::tests::round_trips_every_kind ... ok
    test frame::tests::rejects_oversized_payload ... ok
    test mux::tests::odd_channels_belong_to_the_phone ... ok
    test dial::tests::wireguard_falls_back_to_relay ... ok
    test result: ok. 9 passed; 0 failed; 0 ignored
    """

    static let beforeQuestion = "Both test suites pass. Two product decisions before I wire Settings:"

    static func question(session: String) -> AgentQuestion {
        AgentQuestion(
            id: "q-transport",
            source: AgentQuestion.Source(harness: .claude, session: session, permission: "perm-question", agentName: "Claude"),
            items: [
                AgentQuestion.Item(
                    id: "default", header: "Cellular", prompt: "Which transport should be the default on cellular?",
                    options: [
                        AgentQuestion.Option(id: "webrtc", label: "WebRTC", detail: "Fastest to connect; uses TURN when there's no direct path."),
                        AgentQuestion.Option(id: "wireguard", label: "WireGuard", detail: "One tunnel for every service; falls back to the relay."),
                    ]
                ),
                AgentQuestion.Item(
                    id: "surfaces", header: "Settings", prompt: "Where should the switch appear?",
                    options: [
                        AgentQuestion.Option(id: "connection", label: "Settings → Connection"),
                        AgentQuestion.Option(id: "per-mac", label: "Per Mac", detail: "Long-press a Mac in the sidebar."),
                        AgentQuestion.Option(id: "debug", label: "Debug menu only"),
                    ],
                    multiSelect: true
                ),
            ]
        )
    }

    static let settingsPath = "cnx-ios/CnxKit/Sources/CnxSettings/ConnectionSettings.swift"
    static let settingsOld = """
    import SwiftUI

    struct ConnectionSettings: View {
        var body: some View {
            Section("Connection") {
                Picker(selection: .constant(0)) {
                    Text("WebRTC").tag(0)
                    Text("WireGuard").tag(1)
                } label: {
                    Label("Transport", systemImage: "point.3.connected.trianglepath.dotted")
                }
            }
        }
    }
    """

    static func settingsNew(cellular: String) -> String {
        """
        import SwiftUI

        struct ConnectionSettings: View {
            @AppStorage("transport") private var transport: TransportKind = .\(cellular)

            var body: some View {
                Section("Connection") {
                    Picker(selection: $transport) {
                        ForEach(TransportKind.allCases, id: \\.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    } label: {
                        Label("Transport", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                }
            }
        }
        """
    }

    static func finalAnswer(cellular: String) -> String {
        let name = cellular == "wireguard" ? "WireGuard" : "WebRTC"
        return """
        ## Done: the transport is switchable

        `LinkDialer` now asks a `TransportKind` provider on every dial, so switching in Settings tears the link down and redials. **\(name)** is the default on cellular.

        | Transport | Connect time | Survives network change | Relay |
        | --- | --- | --- | --- |
        | WebRTC | ~350 ms | ICE restart | TURN |
        | WireGuard | ~120 ms | Roams natively | TeamHub DO |

        The redial cost is dominated by the handshake. With loss rate $p$ and round trip $r$, the expected connect time is roughly

        $$
        T \\approx \\frac{k \\cdot r}{1 - p} + t_{\\text{ice}}
        $$

        where $k = 2$ for WireGuard and $k = 4$ for WebRTC.

        To try it from the simulator:

        ```bash
        nx-remote -- swift test --package-path cnx-ios/CnxKit --filter LinkDialerTests
        ```

        Next steps:

        1. Persist the choice per Mac once the registry stores device prefs.
        2. Show the active transport in the connection banner.
        - [x] Swift tests pass
        - [x] Rust tests pass
        - [ ] Dogfood on cellular
        """
    }

    static func shortAnswer(for prompt: String) -> String {
        """
        Sure. I looked at the README and the current branch. Short answer to *\(prompt.prefix(60))*:

        - The change is isolated to the dialer.
        - Nothing else needs to move.

        Want me to open a PR?
        """
    }
}
