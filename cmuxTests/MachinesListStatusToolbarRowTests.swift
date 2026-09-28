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
    /// The three list failures, in the order the panel can hit them.
    private static let problems: [MachinesPanelViewModel.CloudListProblem] = [
        .unreachable, .sessionRejected, .requiresPro,
    ]

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

    /// Each row must carry its own sentence, not merely differ from the other
    /// two: a different glyph and a different button already make three
    /// identical sentences compare unequal, so pairwise inequality proves
    /// nothing. Each rendered row is matched against its own stale line, and
    /// the three stale lines are checked to be distinct. Comparing against the
    /// catalog rather than English literals keeps a copy edit or a non-`en`
    /// host from reddening this for reasons unrelated to the behavior.
    @Test("Each failure renders its own line, and the stale one, not the panel headline")
    func failuresReadDifferently() throws {
        for problem in Self.problems {
            let presentation = MachineListStatusPresentation(.failed(problem))
            let stale = try #require(presentation.staleTitle, "\(problem) has no stale line")
            let text = Self.text(of: Self.host(.failed(problem)))
            #expect(text.contains(stale), "\(problem) rendered \(text), not \(stale)")
            // The toolbar sits beside cached rows, so it takes the one-line
            // stale form. The panel's paragraph belongs to the notice and the
            // empty state, and would blow the toolbar's single line apart.
            let paragraph = try #require(presentation.subtitle, "\(problem) has no panel subtitle")
            #expect(!text.contains(paragraph), "\(problem) rendered the panel subtitle in the toolbar")
        }
        let lines = Self.problems.compactMap { MachineListStatusPresentation(.failed($0)).staleTitle }
        #expect(Set(lines).count == Self.problems.count, "two failures share a stale line: \(lines)")
    }

    /// Waiting for the network is not a failure: it keeps its own glyph, offers
    /// nothing, and cannot be dismissed, because the coordinator retries on its
    /// own and there is no error to dismiss.
    @Test("Offline is not dressed up as a failure")
    func offlineOffersNoAction() throws {
        let hosted = Self.host(.waitingForNetwork)
        #expect(Self.element("CloudMachinesUnavailableRetryButton", in: hosted) == nil)
        let offline = try #require(MachineListStatusPresentation(.waitingForNetwork).staleTitle)
        #expect(Self.text(of: hosted).contains(offline))
        // The dismiss button is what pins `failure = isFailure ? error : nil`.
        // Without this, simplifying that line to `let failure = error` leaves
        // every other case in this suite green while offline gains an orange
        // dismissable chip, hover text and a context menu it never had.
        #expect(Self.element("CloudBannerDismissButton", in: hosted) == nil, "offline offered a dismiss button")
        #expect(Self.element("CloudBannerDismissButton", in: Self.host(.reconnecting)) == nil)
        for problem in Self.problems {
            #expect(
                Self.element("CloudBannerDismissButton", in: Self.host(.failed(problem))) != nil,
                "\(problem) lost its dismiss button"
            )
        }
    }

    /// Pressing the toolbar's action runs the same handler the notice and the
    /// empty state use, rather than only looking actionable.
    @Test("The upgrade action reaches the handler")
    func upgradeActionFires() throws {
        let performed = ActionLog()
        let hosted = Self.host(.failed(.requiresPro), perform: { performed.actions.append($0) })
        let element = try #require(Self.element("CloudMachinesRequiresProUpgradeButton", in: hosted))
        // `press` only reports that a press selector exists; the assertion
        // below is what proves the press reached the handler.
        try #require(Self.press(element), "The upgrade affordance exposes no press action")
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
        let view = NSHostingView(
            rootView: MachinesListStatusToolbarRow(
                status: status,
                error: "HTTP 402 from /api/vm",
                onDismiss: { _ in },
                perform: perform
            )
            // Required, empirically: run 36401958401 dropped this line and every
            // lookup in this suite went nil with no text at all, while the same
            // assertions passed with it in run 36397834894. In-process there is
            // no assistive client to switch SwiftUI's accessibility output on,
            // so the hierarchy asks for it directly. The deprecation notice says
            // to read this key, not to set it; there is no replacement that
            // turns the output on, and without it there is nothing to test.
            .environment(\.accessibilityEnabled, true)
        )
        view.frame = NSRect(x: 0, y: 0, width: 420, height: 28)
        // A window as well, so the view is not queried while detached.
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
