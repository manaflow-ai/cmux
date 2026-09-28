import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The toolbar row is what a user sees when the machine list read fails while
/// cached rows stay on screen. It used to render one warning triangle and one
/// "Machine list unavailable" line for all three failures, with nothing to
/// click, even though the notice and the empty state already route a rejected
/// session to a fresh sign-in and a lapsed plan to an upgrade.
@MainActor
@Suite("The Cloud toolbar names the failure it has and offers its fix", .serialized)
struct MachinesListStatusToolbarRowTests {
    @Test("Each failure offers the action that can fix it")
    func failureOffersItsAction() throws {
        let expected: [(MachinesPanelViewModel.CloudListProblem, String)] = [
            (.unreachable, "CloudMachinesUnavailableRetryButton"),
            (.sessionRejected, "CloudMachinesSessionRejectedSignInButton"),
            (.requiresPro, "CloudMachinesRequiresProUpgradeButton"),
        ]
        for (problem, identifier) in expected {
            #expect(
                Self.element(identifier, in: Self.host(.failed(problem))) != nil,
                "\(problem) left the toolbar with no way to act"
            )
        }
    }

    @Test("The three failures do not read the same line")
    func failuresReadDifferently() throws {
        let unreachable = Self.text(of: Self.host(.failed(.unreachable)))
        let rejected = Self.text(of: Self.host(.failed(.sessionRejected)))
        let pro = Self.text(of: Self.host(.failed(.requiresPro)))
        #expect(!unreachable.isEmpty)
        #expect(unreachable != rejected)
        #expect(unreachable != pro)
        #expect(rejected != pro)
    }

    @Test("A failure still says the cached rows are the last known ones")
    func failureKeepsTheStaleQualifier() throws {
        for problem in [MachinesPanelViewModel.CloudListProblem.unreachable, .sessionRejected, .requiresPro] {
            let text = Self.text(of: Self.host(.failed(problem)))
            #expect(text.contains("last known"), "\(problem) dropped the stale qualifier: \(text)")
        }
    }

    /// Waiting for the network is not a failure: it keeps its own glyph and
    /// offers nothing, because the coordinator retries on its own.
    @Test("Offline is not dressed up as a failure")
    func offlineOffersNoAction() throws {
        let hosted = Self.host(.waitingForNetwork)
        #expect(Self.element("CloudMachinesUnavailableRetryButton", in: hosted) == nil)
        #expect(Self.text(of: hosted).contains("Offline"))
    }

    /// Pressing the toolbar's action runs the same handler the notice and the
    /// empty state use, rather than only looking actionable.
    @Test("The upgrade action reaches the handler")
    func upgradeActionFires() throws {
        let performed = ActionLog()
        let hosted = Self.host(.failed(.requiresPro), perform: { performed.actions.append($0) })
        let element = try #require(Self.element("CloudMachinesRequiresProUpgradeButton", in: hosted))
        try #require(Self.press(element), "The upgrade affordance must be a button an assistive client can press")
        #expect(performed.actions == [.upgrade])
    }

    // MARK: - Fixtures

    /// The row's action closure escapes into SwiftUI, so the recorder has to be
    /// a reference the test still holds afterwards.
    @MainActor
    private final class ActionLog {
        var actions: [MachineListStatusPresentation.Action] = []
    }

    /// A mounted row plus the window that keeps it alive: an `NSHostingView`
    /// whose window has gone away stops answering for its SwiftUI children.
    private struct Hosted {
        let window: NSWindow
        let view: NSView
    }

    private static func host(
        _ status: MachineListStatus,
        perform: @escaping (MachineListStatusPresentation.Action) -> Void = { _ in }
    ) -> Hosted {
        // In-process there is no assistive client to switch SwiftUI's
        // accessibility output on, so this hierarchy asks for it directly.
        let view = NSHostingView(
            rootView: MachinesListStatusToolbarRow(
                status: status,
                error: "HTTP 402 from /api/vm",
                onDismiss: { _ in },
                perform: perform
            )
            .environment(\.accessibilityEnabled, true)
        )
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 28)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return Hosted(window: window, view: view)
    }

    private static func element(_ identifier: String, in hosted: Hosted) -> NSObject? {
        CloudTreeHeaderActionsTests.accessibilityElement(identifier, in: hosted.view)
    }

    /// A SwiftUI node answers either the modern getter or the legacy attribute,
    /// and puts its text under whichever of these three suits its role.
    private static let textAttributes: [(NSAccessibility.Attribute, String)] = [
        (.value, "accessibilityValue"),
        (.description, "accessibilityLabel"),
        (.title, "accessibilityTitle"),
    ]

    /// Every string the row exposes, joined: the status line plus any button.
    private static func text(of hosted: Hosted) -> String {
        var found: [String] = []
        var pending: [NSObject] = [hosted.view]
        var visited = Set<ObjectIdentifier>()
        while !pending.isEmpty {
            let element = pending.removeFirst()
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            for (attribute, getter) in textAttributes {
                if let value = CloudTreeHeaderActionsTests.accessibilityAttribute(
                    attribute, getter: getter, of: element
                ) as? String, !value.isEmpty {
                    found.append(value)
                }
            }
            let children = CloudTreeHeaderActionsTests.accessibilityAttribute(
                .children, getter: "accessibilityChildren", of: element
            ) as? [Any]
            pending += NSAccessibility.unignoredChildren(from: children ?? []).compactMap { $0 as? NSObject }
        }
        return found.joined(separator: " | ")
    }

    /// Presses `element` the way VoiceOver would, through the modern protocol
    /// method when it is implemented and the legacy action API otherwise.
    private static func press(_ element: NSObject) -> Bool {
        let modern = NSSelectorFromString("accessibilityPerformPress")
        if element.responds(to: modern) {
            _ = element.perform(modern)
            return true
        }
        let legacy = NSSelectorFromString("accessibilityPerformAction:")
        guard element.responds(to: legacy) else { return false }
        _ = element.perform(legacy, with: NSAccessibility.Action.press.rawValue)
        return true
    }
}
