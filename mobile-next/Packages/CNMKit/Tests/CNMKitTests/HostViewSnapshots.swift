#if os(macOS)
import AppKit
import CNMBackend
import CNMHost
import CNMHostRuntime
import SwiftUI
import Testing

/// Renders the Mac app's pairing views to PNGs (in $CNM_SNAPSHOT_DIR) for
/// visual review; the menu bar window can't be screenshotted over SSH.
@MainActor
@Suite struct HostViewSnapshots {
    @Test func renderPairingStates() throws {
        guard let dir = ProcessInfo.processInfo.environment["CNM_SNAPSHOT_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let runtime = HostRuntime(
            environment: HostEnvironment(supportDirectory: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cnm-snap")),
            backend: BackendClient(), name: "Aziz's MacBook Pro"
        )
        let states: [(String, HostRuntime.Phase)] = [
            ("pairing", .pairing(code: "AZWXAR3H")),
            ("approving", .approving(code: "AZWXAR3H", email: "aziz@manaflow.ai")),
        ]
        for (name, phase) in states {
            runtime.showPhaseForSnapshot(phase)
            try render(PairingWindow(runtime: runtime), to: "\(dir)/window-\(name).png")
            try render(HostMenu(runtime: runtime), to: "\(dir)/menu-\(name).png")
        }
        runtime.showPhaseForSnapshot(.serving, identity: .init(hostID: "h", hostToken: "t", userEmail: "aziz@manaflow.ai", name: "Mac"))
        try render(HostMenu(runtime: runtime), to: "\(dir)/menu-serving.png")
    }

    private func render(_ view: some View, to path: String) throws {
        let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .light))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw CancellationError() }
        try png.write(to: URL(fileURLWithPath: path))
    }
}
#endif
