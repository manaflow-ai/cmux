import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Keyboard shortcut settings observer", .serialized)
struct KeyboardShortcutSettingsObserverTests {
    @Test func mainThreadSettingsChangeIsAuthoritativeBeforePostReturns() {
        let observer = KeyboardShortcutSettingsObserver.shared
        let expectedRevision = observer.revision &+ 1

        NotificationCenter.default.post(
            name: KeyboardShortcutSettings.didChangeNotification,
            object: nil
        )

        #expect(observer.revision == expectedRevision)
    }
}
