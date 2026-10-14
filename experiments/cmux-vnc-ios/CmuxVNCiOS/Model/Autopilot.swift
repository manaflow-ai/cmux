import CmuxScreenKit
import CmuxScreenKitUI
import CmuxVNC
import CmuxVNCWebRTC
import Foundation

/// Launch arguments for unattended runs (simulator screenshots, demos):
/// `-autoDemo` opens the demo desktop, `-autoHost <address>` opens a host
/// (with `-autoUser`/`-autoPassword`), `-autopilot` then plays scripted input
/// through the same session calls the gestures use.
struct Autopilot {
    let arguments = ProcessInfo.processInfo.arguments

    var opensDemo: Bool { arguments.contains("-autoDemo") }
    var playsScript: Bool { arguments.contains("-autopilot") }

    func value(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    @MainActor
    func session() -> ScreenSession? {
        if opensDemo { return ScreenSession(demoPreferences: ScreenPreferences()) }
        if let raw = value("-autoLink"), let url = URL(string: raw), let pairing = VNCPairing(link: url) {
            return ScreenSession(title: pairing.name, pairing: pairing,
                                 credentials: VNCCredentials(username: value("-autoUser"), password: value("-autoPassword")),
                                 preferences: ScreenPreferences())
        }
        guard let address = value("-autoHost"), let parsed = VNCEndpoint.parse(address) else { return nil }
        let credentials = VNCCredentials(username: value("-autoUser") ?? parsed.credentials.username,
                                         password: value("-autoPassword") ?? parsed.credentials.password)
        return ScreenSession(title: parsed.endpoint.label, endpoint: parsed.endpoint, credentials: credentials,
                             preferences: ScreenPreferences())
    }

    /// `-perfScript`: realistic actions on a real Mac, paced like a person,
    /// so `perf.log` records input → frame for each: Spotlight, typing,
    /// Escape, clicks, scrolls. Five rounds.
    @MainActor
    func playPerfScript(on session: ScreenSession) async {
        guard await session.waitUntilConnected() else { return }
        try? await Task.sleep(for: .seconds(3)) // let the first full frame settle
        let size = session.frameSize
        for round in 0 ..< 5 {
            session.tap(.space, modifiers: [.command])
            try? await Task.sleep(for: .seconds(2)) // pacing
            session.type("term")
            try? await Task.sleep(for: .seconds(2)) // pacing
            session.tap(.escape)
            try? await Task.sleep(for: .seconds(2)) // pacing
            session.movePointer(to: CGPoint(x: size.width * (0.3 + 0.1 * Double(round)), y: size.height * 0.5))
            session.click(.left)
            try? await Task.sleep(for: .seconds(2)) // pacing
            session.scroll(dx: 0, dy: -3)
            try? await Task.sleep(for: .seconds(2)) // pacing
        }
    }

    /// Paints a stroke, types a line and scrolls, with pauses a viewer can follow.
    @MainActor
    func play(on session: ScreenSession) async {
        guard await session.waitUntilConnected() else { return }
        // Pacing for a person watching, not synchronization.
        try? await Task.sleep(for: .seconds(1))
        let size = session.frameSize
        guard size.width > 0 else { return }
        session.movePointer(to: CGPoint(x: size.width * 0.55, y: size.height * 0.55))
        session.press(.left, down: true)
        for step in 0 ... 60 {
            let t = Double(step) / 60
            session.movePointer(to: CGPoint(x: size.width * (0.55 + 0.3 * t), y: size.height * (0.55 + 0.25 * sin(t * .pi * 2))))
            try? await Task.sleep(for: .milliseconds(16)) // pacing
        }
        session.press(.left, down: false)
        session.type("hello from cmux VNC on iOS")
        try? await Task.sleep(for: .milliseconds(400)) // pacing
        session.scroll(dx: 0, dy: -2)
    }
}
