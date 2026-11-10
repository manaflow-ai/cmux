#if DEBUG
import CmuxHomeCore
import CmuxHomeUI
import UIKit

/// Captures the Home prototype gallery and the Settings gallery once per launch.
@MainActor
enum GalleryRunner {
    static func run(store: HomeStore, window: UIWindow) {
        Task { @MainActor in
            var urls = (try? await HomeGallery.capture(into: directory, store: store, window: window)) ?? []
            urls += (try? await SettingsGallery(directory: directory, window: window).capture()) ?? []
            try? "\(urls.count)\n".write(to: directory.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
        }
    }

    static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cmux-gallery", isDirectory: true)
    }
}
#endif
