import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct WindowDecorationSettingsIsolationTests {
    @Test(.timeLimit(.minutes(1)))
    func presentationModeLoadDoesNotRunOnMainThread() async {
        let threadProbe = WindowDecorationSettingsThreadProbe()
        let controller = WindowDecorationsController(
            initialPresentationMode: .standard,
            presentationModeProvider: {
                let isMainThread = Thread.isMainThread
                Task { await threadProbe.record(isMainThread) }
                return .standard
            }
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }

        controller.start()
        controller.apply(to: window)
        let settingsLoadedOnMainThread = await threadProbe.next()

        #expect(!settingsLoadedOnMainThread)
    }
}
