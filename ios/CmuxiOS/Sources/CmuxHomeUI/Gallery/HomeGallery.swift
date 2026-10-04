#if DEBUG
public import CmuxHomeCore
import CmuxiOSDesign
import Observation
import QuartzCore
public import UIKit

/// DEBUG-only screenshot capture of every Home prototype variant, for
/// Lawrence to compare off the phone. The app calls it at launch when
/// `CMUX_IOS_GALLERY=1`. Each screen is installed as the window's root,
/// laid out (no sleeps: layout passes, a transaction flush and main-actor
/// yields), and drawn to a PNG.
// lint:allow namespace: the DEBUG entry point the app shell calls by this agreed name; it owns no state.
public enum HomeGallery {
    @MainActor
    public static func capture(into directory: URL, store: HomeStore, window: UIWindow) async throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = window.rootViewController
        let originalStyle = window.overrideUserInterfaceStyle
        defer {
            window.overrideUserInterfaceStyle = originalStyle
            window.rootViewController = original
        }
        await waitUntil(store) { $0.isOnline && !$0.rows.isEmpty }
        var shot = Shooter(directory: directory, window: window)

        // Home in each density, then dark mode and an accessibility text size.
        let home = HomeViewController(store: store, options: HomeUIOptions())
        let navigation = largeTitleNavigation(home)
        window.overrideUserInterfaceStyle = .light
        try await shot.install(navigation, name: nil)
        for density in HomeListDensity.allCases {
            home.apply(HomeUIOptions(density: density, composeFlow: .inlineTo))
            try await shot.capture("home-\(density.rawValue)-light")
        }
        home.apply(HomeUIOptions())
        window.overrideUserInterfaceStyle = .dark
        try await shot.capture("home-comfortable-dark")
        window.overrideUserInterfaceStyle = .light
        navigation.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraLarge
        try await shot.capture("home-comfortable-axxl-light")
        navigation.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)

        // Conversations: the Chief DM and a group (author names and avatars).
        let chief = store.rows.first { $0.kind == .chief }?.id
        let group = store.rows.first { $0.kind == .group }?.id
        for (name, id) in [("chief", chief), ("group", group)] {
            guard let id else { continue }
            await store.open(id)
            let screen = ConversationViewController(store: store, conversation: id)
            navigation.setViewControllers([home, screen], animated: false)
            navigation.view.layoutIfNeeded()
            await screen.rendered()
            try await shot.capture("conversation-\(name)-light")
            if name == "chief" {
                window.overrideUserInterfaceStyle = .dark
                try await shot.capture("conversation-chief-dark")
                window.overrideUserInterfaceStyle = .light
            }
        }
        navigation.setViewControllers([home], animated: false)

        // Compose and invite flows, with sample recipients filled in.
        for flow in HomeComposeFlow.allCases {
            try await shot.install(sheetNavigation(await composeSample(flow, store: store)), name: "compose-\(flow.rawValue)-light")
            let invite = ComposeCoordinator.makeScreen(.invite, flow: flow, store: store)
            invite.focusesOnAppear = false
            try await shot.install(sheetNavigation(invite), name: "invite-\(flow.rawValue)-light")
        }
        try await shot.install(sheetNavigation(NewGroupViewController(store: store)), name: "newgroup-light")
        let chiefForm = NewChiefViewController(store: store)
        chiefForm.focusesOnAppear = false
        try await shot.install(sheetNavigation(chiefForm), name: "newchief-light")

        // Offline: only with the mock owner, which can drop its connection.
        if let mock = store.source as? MockHomeSource {
            await mock.setOnline(false)
            await waitUntil(store) { !$0.isOnline }
            try await shot.install(navigation, name: "home-comfortable-offline-light")
            if let chief {
                let screen = ConversationViewController(store: store, conversation: chief)
                navigation.setViewControllers([home, screen], animated: false)
                navigation.view.layoutIfNeeded()
                await screen.rendered()
                try await shot.capture("conversation-chief-offline-light")
                navigation.setViewControllers([home], animated: false)
            }
            await mock.setOnline(true)
            await waitUntil(store) { $0.isOnline && !$0.rows.isEmpty }
        }
        return shot.urls
    }

    @MainActor
    private static func composeSample(_ flow: HomeComposeFlow, store: HomeStore) async -> UIViewController {
        switch flow {
        case .inlineTo:
            let screen = NewMessageViewController(store: store, mode: .message,
                                                  prefill: [.email("austin@manaflow.com"), .email("sam.lee@example.org")])
            screen.focusesOnAppear = false
            await screen.settled()
            return screen
        case .inviteSheet:
            let screen = InviteSheetViewController(store: store, mode: .message, prefill: "sam.lee@example.org")
            screen.focusesOnAppear = false
            screen.loadViewIfNeeded()
            await screen.settled()
            return screen
        case .contactsFirst:
            return ComposeCoordinator.makeScreen(.newMessage, flow: flow, store: store)
        }
    }

    @MainActor
    private static func largeTitleNavigation(_ root: UIViewController) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: root)
        navigation.navigationBar.prefersLargeTitles = true
        return navigation
    }

    @MainActor
    private static func sheetNavigation(_ root: UIViewController) -> UINavigationController {
        let navigation = UINavigationController(rootViewController: root)
        navigation.navigationBar.tintColor = HomePalette.accent
        return navigation
    }

    /// Suspends until `condition` holds, re-checking only when a store
    /// property it reads changes (observation, not polling).
    @MainActor
    static func waitUntil(_ store: HomeStore, _ condition: @escaping @MainActor (HomeStore) -> Bool) async {
        while !condition(store) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = condition(store)
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}

/// Installs screens in the window and writes PNGs.
@MainActor
private struct Shooter {
    let directory: URL
    let window: UIWindow
    private(set) var urls: [URL] = []

    init(directory: URL, window: UIWindow) {
        self.directory = directory
        self.window = window
    }

    mutating func install(_ root: UIViewController, name: String?) async throws {
        window.rootViewController = root
        window.makeKeyAndVisible()
        if let name { try await capture(name) }
    }

    mutating func capture(_ name: String) async throws {
        await settle()
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let window = self.window
        let data = renderer.pngData { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = directory.appendingPathComponent(name + ".png")
        try data.write(to: url, options: .atomic)
        urls.append(url)
    }

    /// Lets deferred renders (observation re-renders run in a later
    /// main-actor job) and layout complete before drawing.
    private func settle() async {
        for _ in 0..<4 {
            await Task.yield()
            window.setNeedsLayout()
            window.layoutIfNeeded()
            CATransaction.flush()
        }
    }
}
#endif
