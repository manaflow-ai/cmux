import UIKit

/// `-snapshot <seconds>`: writes PNGs of the app's window to Documents
/// (`snapshot-1.png`, ...) every `seconds`, rendered on the CPU with
/// `CALayer.render(in:)`. Headless simulators that do not composite app
/// content still produce real captures this way (evidence for demos and PRs).
@MainActor
struct Snapshotter {
    func start() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-snapshot"), index + 1 < arguments.count,
              let interval = Double(arguments[index + 1]), interval > 0 else { return }
        Task { @MainActor in
            for count in 1 ... 12 {
                try? await Task.sleep(for: .seconds(interval)) // capture cadence, not synchronization
                capture(count)
            }
        }
    }

    private func capture(_ count: Int) {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first else { return }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { context in
            // Every window of the scene, bottom to top (full-screen covers live in their own window views).
            for item in windows where !item.isHidden { item.layer.render(in: context.cgContext) }
        }
        guard let data = image.pngData(),
              let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        try? data.write(to: folder.appendingPathComponent("snapshot-\(count).png"))
    }
}
