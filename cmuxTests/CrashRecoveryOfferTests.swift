import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior tests for the crash-recovery offer copy: it names the count and is
/// non-empty on every field (so the alert never shows blank buttons).
@Suite struct CrashRecoveryOfferTests {

    @Test func messageNamesTheResumableCount() {
        let content = CrashRecoveryOfferText.make(resumableCount: 3)
        #expect(content.message.contains("3"))
        #expect(!content.message.contains("workspace(s)"))
    }

    @Test func allFieldsArePopulated() {
        let content = CrashRecoveryOfferText.make(resumableCount: 1)
        #expect(!content.title.isEmpty)
        #expect(!content.message.isEmpty)
        #expect(!content.resumeButton.isEmpty)
        #expect(!content.dismissButton.isEmpty)
    }
}
