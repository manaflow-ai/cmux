#if DEBUG
import CmuxHomeCore
import CmuxiOSAccount
import QuartzCore
import SwiftUI
import UIKit

/// DEBUG-only captures of Settings > Delete Account in each state, next to
/// the Home gallery's PNGs (`CMUX_IOS_GALLERY=1`): idle (light, dark, the
/// largest accessibility text), the confirmation, progress, and a failure
/// with Try Again (light, dark, large text). Every state is a real
/// `AccountDeletionModel` phase; nothing is sent.
@MainActor
struct SettingsGallery {
    let directory: URL
    let window: UIWindow

    func capture() async throws -> [URL] {
        let original = window.rootViewController
        let originalStyle = window.overrideUserInterfaceStyle
        defer {
            window.overrideUserInterfaceStyle = originalStyle
            window.rootViewController = original
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        let variants: [(name: String, phase: AccountDeletionPhase, style: UIUserInterfaceStyle, large: Bool)] = [
            ("settings-delete-idle-light", .idle, .light, false),
            ("settings-delete-idle-dark", .idle, .dark, false),
            ("settings-delete-idle-axxl-light", .idle, .light, true),
            ("settings-delete-confirming-light", .confirming, .light, false),
            ("settings-delete-confirming-dark", .confirming, .dark, false),
            ("settings-delete-deleting-light", .deleting, .light, false),
            ("settings-delete-failed-light", .failed(.offline), .light, false),
            ("settings-delete-failed-dark", .failed(.unconfirmed), .dark, false),
            ("settings-delete-failed-axxl-light", .failed(.refused), .light, true),
        ]
        for variant in variants {
            let model = AccountDeletionModel(phase: variant.phase, delete: {}, signOut: {})
            let hosting = UIHostingController(rootView: NavigationStack {
                SettingsView(email: "sam.lee@example.org",
                             chatServer: ChatServerSettingsModel(current: .hosted) { _ in },
                             deletion: model, onClose: {})
            })
            if variant.large {
                hosting.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraLarge
            }
            window.overrideUserInterfaceStyle = variant.style
            window.rootViewController = hosting
            window.makeKeyAndVisible()
            if variant.phase == .confirming { await settle(until: { hosting.presentedViewController != nil }) }
            urls.append(try await shoot(variant.name))
        }
        return urls
    }

    /// Lets layout and observation re-renders finish; with `until`, also
    /// waits (a bounded number of main-actor turns) for a presentation.
    private func settle(until condition: () -> Bool = { true }) async {
        for turn in 0..<400 {
            await Task.yield()
            window.setNeedsLayout()
            window.layoutIfNeeded()
            CATransaction.flush()
            if turn >= 4, condition() { return }
        }
    }

    private func shoot(_ name: String) async throws -> URL {
        await settle()
        let window = self.window
        let data = UIGraphicsImageRenderer(bounds: window.bounds).pngData { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let url = directory.appendingPathComponent(name + ".png")
        try data.write(to: url, options: .atomic)
        return url
    }
}
#endif
