import AppKit
import CmuxFoundation
import CmuxVaultHistory
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite struct VaultHistoryRowLayoutTests {
    @Test(arguments: [240.0, 320.0, 420.0], ["en", "de", "ja"])
    func longTitlesDoNotIncreaseRowHeight(width: Double, locale: String) {
        let short = rowSize(title: "Fix layout", width: width, locale: locale)
        let long = rowSize(
            title: "You are working directly in the full clone /Users/austinwang/manaflow/term/cmux123. "
                + String(repeating: "Restore the compact Vault session styling. ", count: 8),
            width: width,
            locale: locale
        )

        #expect(short.height > 20)
        #expect(long.height <= short.height + 1)
        #expect(long.height < 60)
        #expect(abs(long.width - width) < 1)
    }

    private func rowSize(title: String, width: Double, locale: String) -> NSSize {
        let event = VaultHistoryEvent(
            timestamp: Date().addingTimeInterval(-46 * 60),
            kind: .sessionActivity,
            title: title,
            subject: VaultHistorySubject(
                agent: "codex",
                directory: "/Users/austinwang/manaflow/term/cmux123"
            )
        )
        let host = NSHostingView(
            rootView: VaultHistoryEventRow(event: event)
                .environment(\.locale, Locale(identifier: locale))
                .environment(\.cmuxGlobalFontMagnificationPercent, 100)
                .frame(width: width)
        )
        return host.fittingSize
    }
}
