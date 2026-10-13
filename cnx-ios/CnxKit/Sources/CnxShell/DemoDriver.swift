#if os(iOS) && DEBUG
import CmuxAgentQuestion
import CnxAgentChat
import CnxChief
import CnxDesign
import CnxFeed
import CnxModel
import CnxWorkspaces
import QuartzCore
import SwiftUI
import UIKit
import OSLog

private let demoLog = Logger(subsystem: "dev.cmux.cnx", category: "demo")

/// DEBUG-only scripted choreography for simulator recordings (`-cnx-demo <name>`).
/// Drawer drags feed synthetic finger positions, one per display frame, into
/// the container's real tracking path (`beginTracking` / `track` /
/// `endTracking`), so the recorded motion is the production pan code minus the
/// recognizer. The pauses below pace the recording; they are not synchronization.
@MainActor
struct DemoDriver {
    let shell: ShellModel

    func run(_ name: String) async {
        try? await Task.sleep(for: .seconds(1.2))
        switch name {
        case "drawer": await drawer()
        case "settings": await settings()
        case "states": await states()
        case "editor": await editor()
        case "rubber": await rubber()
        case "workspaces": await workspaces()
        case "workspaces-reopen": await workspacesReopen()
        case "chief": await chief()
        case "live": await live()
        default: break
        }
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    /// A finger drag of `distance` points over `duration`, released with the
    /// finger's last-frame velocity (or `release`). Slow drags ease in and out;
    /// flicks accelerate and lift off while still moving, like a real swipe.
    private func drag(_ distance: CGFloat, duration: Double, release: CGFloat? = nil, flick: Bool = false) async {
        let sidebar = shell.sidebar
        sidebar.beginTracking()
        let frames = FrameClock()
        let start = await frames.next()
        var last: (t: Double, x: CGFloat) = (0, 0)
        var velocity: CGFloat = 0
        while true {
            let t = min((await frames.next() - start) / duration, 1)
            let x = flick ? distance * CGFloat(t * t) : distance * CGFloat(t * t * (3 - 2 * t))
            let elapsed = t * duration
            if elapsed > last.t { velocity = (x - last.x) / CGFloat(elapsed - last.t) }
            last = (elapsed, x)
            sidebar.track(translationX: x)
            if t >= 1 { break }
        }
        frames.stop()
        sidebar.endTracking(velocityX: release ?? velocity)
    }

    private func drawer() async {
        // Slow interactive open, released past the threshold with little velocity.
        await drag(240, duration: 0.7, release: 120)
        await pause(1.6)
        // Fast flick closed.
        await drag(-110, duration: 0.12, flick: true)
        await pause(1.2)
        // Toolbar button open.
        shell.sidebar.open()
        await pause(1.4)
        // Switch team: highlight moves, drawer closes, content crossfades.
        if let next = shell.store.teams.first(where: { $0.id != shell.store.activeTeamID }) {
            shell.switchTeam(to: next.id)
        }
        await pause(1.6)
        // Partial drag that does not reach the threshold springs back closed.
        await drag(90, duration: 0.5, release: 0)
        await pause(1.2)
        // Open on a fast short flick (velocity wins over distance).
        await drag(70, duration: 0.1, flick: true)
        await pause(1.4)
        // Close by tapping the card.
        shell.sidebar.close()
        await pause(1.2)
    }

    private func rubber() async {
        shell.sidebar.open()
        await pause(1.0)
        await drag(150, duration: 0.6, release: 0)
        await pause(1.2)
        shell.sidebar.close()
        await pause(1.0)
    }

    private func settings() async {
        shell.tab = .settings
        await pause(1.5)
        shell.settingsScrollTarget = "bottom"
        await pause(2.0)
        shell.settingsPath = [.pairedMacs]
        await pause(1.5)
        shell.settingsPath = []
        await pause(1.0)
        shell.settingsScrollTarget = "top"
        await pause(1.5)
    }

    private func states() async {
        shell.tab = .workspaces
        await pause(1.0)
        shell.store.teamDataState = .loading
        await pause(2.0)
        shell.store.teamDataState = .failed
        await pause(2.0)
        shell.store.teamDataState = .loaded
        await pause(1.0)
        shell.store.isOffline = true
        await pause(2.0)
        shell.store.isOffline = false
        await pause(0.8)
        if let index = shell.store.teams.firstIndex(where: { $0.id == shell.store.activeTeamID }) {
            let macs = shell.store.teams[index].macs
            shell.store.teams[index].macs = macs.map { MacDevice(id: $0.id, name: $0.name, isOnline: false) }
            await pause(2.0)
            shell.store.teams[index].macs = []
            await pause(2.0)
            shell.store.teams[index].macs = macs
        }
        await pause(1.0)
        shell.toast = CnxToast(symbol: "checkmark", text: "Paired with cmux mini 2")
        await pause(2.0)
    }

    /// Open a workspace on its last tab, chat, switch tabs through the grid
    /// (zoom out, zoom into a card), leave, and reopen on the new last tab.
    private func workspaces() async {
        let store = shell.store
        let tabs = WorkspaceDemoDirector.shared
        store.noteOpened(tabID: "t-claude", in: "ws-cmux")
        shell.tab = .workspaces
        await pause(1.6)
        guard let ws = store.workspace(id: "ws-cmux") else { return }
        shell.workspacesPath = [ws]
        await pause(2.4)
        DemoDirector.shared.post(.chatSend("Summarize what changed in the transport layer"))
        await pause(7.0)
        tabs.post(.showGrid(true))
        await pause(2.2)
        tabs.post(.activate("t-zsh"))
        await pause(2.2)
        tabs.post(.showGrid(true))
        await pause(2.0)
        tabs.post(.activate("t-docs"))
        await pause(3.5)
        tabs.post(.showGrid(true))
        await pause(1.8)
        tabs.post(.showGrid(false))
        await pause(1.8)
        tabs.post(.exit)
        await pause(1.8)
        // Reopen: starts on the browser tab used last.
        shell.workspacesPath = [ws]
        await pause(2.6)
        tabs.post(.exit)
        await pause(1.5)
    }

    /// Waits (polling each 0.25 s) for `condition`, up to `timeout` seconds.
    @discardableResult
    private func until(_ timeout: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            await pause(0.25)
        }
        return true
    }

    /// Live end to end (real Mac): Mac online and connected, the daemon's
    /// workspaces, an agent tab streaming acpmux, Feed answers sent back,
    /// then a WebRTC ↔ WireGuard switch.
    private func live() async {
        step("start")
        shell.tab = .workspaces
        guard await until(60, { shell.live?.link.phase.isConnected == true }) else { return }
        guard await until(30, { !shell.store.workspaces.isEmpty }) else { return }
        await pause(2.5)
        // The sidebar: the personal space as "Personal" with its live Mac dots.
        step("sidebar")
        shell.sidebar.open()
        await pause(3)
        shell.sidebar.close()
        await pause(1.5)
        // Open the workspace that has an agent tab, on that tab.
        guard let ws = shell.store.workspaces.first(where: { $0.tabs.contains { $0.kind == .agent } }),
              let agent = ws.tabs.first(where: { $0.kind == .agent }) else { return }
        shell.store.noteOpened(tabID: agent.id, in: ws.id)
        step("open workspace \(ws.title) on \(agent.title)")
        shell.workspacesPath = [ws]
        await pause(4)
        let mac = shell.store.activeTeam?.macs.first { $0.id == ws.macID }?.name ?? "Mac"
        let chat = AgentSessionDirectory.shared.store(workspace: ws, tab: agent, macName: mac)
        chat.send(prompt: "What does the README say?")
        await pause(5)
        step("prompt ask")
        chat.send(prompt: "ask: rm -rf build")
        await until(15) { chat.pendingPermission != nil }
        await pause(2.5)
        // Answer from the Feed: Allow (refused for a phone), then Deny (reaches the Mac).
        shell.workspacesPath = []
        await pause(1)
        step("feed")
        shell.tab = .feed
        await pause(3)
        let feed = FeedStore.shared
        await until(10) { feed.items.contains { if case .permission = $0.kind { return $0.needsYou }; return false } }
        if let item = feed.items.first(where: { if case .permission = $0.kind { return $0.needsYou }; return false }),
           case .permission(let request) = item.kind {
            step("feed allow \(item.id)")
            if let allow = request.options.first(where: \.isAllow) { feed.respond(item.id, option: allow) }
            await pause(3.5)
            step("feed deny \(item.id)")
            if let deny = request.options.first(where: { !$0.isAllow }) { feed.respond(item.id, option: deny) }
            await pause(3)
        }
        // A question: answered from the Feed.
        step("prompt question")
        chat.send(prompt: "question: Which approach?")
        await until(15) { feed.items.contains { if case .question = $0.kind { return $0.needsYou }; return false } }
        await pause(2.5)
        if let item = feed.items.first(where: { if case .question = $0.kind { return $0.needsYou }; return false }),
           case .question(let question) = item.kind, let first = question.items.first, let option = first.options.first {
            step("feed answer \(item.id)")
            feed.answer(item.id, answer: AgentQuestionAnswer(selections: [first.id: .init(optionIDs: [option.id])]))
            await pause(3.5)
        }
        // Transport switch: WebRTC (no TURN: fails gracefully), then back to WireGuard.
        shell.tab = .workspaces
        await pause(2)
        step("transport webrtc")
        shell.settings.transport = .webrtc
        await until(45) { if case .waiting = shell.live?.link.phase { return true }; return false }
        await pause(4)
        step("transport wireguard")
        shell.settings.transport = .wireguard
        await until(30) { shell.live?.link.phase.isConnected == true }
        await pause(4)
    }

    private func step(_ name: String) {
        demoLog.info("demo step: \(name, privacy: .public)")
    }

    /// After a relaunch: the workspace opens on the tab used last before it.
    private func workspacesReopen() async {
        shell.tab = .workspaces
        await pause(1.6)
        guard let ws = shell.store.workspace(id: "ws-cmux") else { return }
        shell.workspacesPath = [ws]
        await pause(3.0)
        WorkspaceDemoDirector.shared.post(.showGrid(true))
        await pause(2.2)
        WorkspaceDemoDirector.shared.post(.showGrid(false))
        await pause(2.0)
    }

    /// Home list, open Chief, send (receipt, Chief's tapback, typing, reply),
    /// tapback Chief's reply, send again, scroll, back to the list.
    private func chief() async {
        let hook = ChiefDemoHook.shared
        shell.tab = .home
        await pause(2.4)
        shell.homePath.append(ChiefRoute())
        await pause(2.6)
        hook.lab("send thanks! what's the status?")
        await pause(6.5)
        hook.lab("doubletap last")
        await pause(1.8)
        hook.lab("react thumbsup")
        await pause(2.2)
        hook.lab("send yes, allow it")
        await pause(6.5)
        hook.scroll(toTop: true)
        await pause(2.2)
        hook.scroll(toTop: false)
        await pause(1.8)
        if !shell.homePath.isEmpty { shell.homePath.removeLast() }
        await pause(2.5)
    }

    private func editor() async {
        shell.sidebar.open()
        await pause(1.2)
        shell.editingTeam = shell.store.activeTeam
        await pause(3.0)
    }
}

/// Awaits display frames.
@MainActor
private final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var waiter: CheckedContinuation<Double, Never>?

    func next() async -> Double {
        await withCheckedContinuation { continuation in
            waiter = continuation
            if link == nil {
                let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                link.add(to: .main, forMode: .common)
                self.link = link
            }
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: link.targetTimestamp)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }
}
#endif
