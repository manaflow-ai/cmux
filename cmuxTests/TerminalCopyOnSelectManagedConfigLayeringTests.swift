import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct TerminalCopyOnSelectManagedConfigLayeringTests {
    @Test
    func managedSettingsDoNotDowngradeUserGhosttySelectionClipboardMode() throws {
        let suiteName = "cmux-terminal-copy-on-select-layering-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(false, forKey: TerminalCopyOnSelectSettings.copyOnSelectKey)

        let effectiveValue = Self.effectiveCopyOnSelectValue(afterLoading: [
            "copy-on-select = true",
            TerminalManagedGhosttySettings.ghosttyConfigContents(defaults: defaults),
        ])

        #expect(effectiveValue == "true")
    }

    private static func effectiveCopyOnSelectValue(afterLoading configs: [String?]) -> String? {
        var value: String?
        for config in configs.compactMap({ $0 }) {
            for line in config.components(separatedBy: .newlines) {
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separatorRange = trimmedLine.range(of: "=") else { continue }
                let key = trimmedLine[..<separatorRange.lowerBound].trimmingCharacters(in: .whitespaces)
                guard key == "copy-on-select" else { continue }
                value = trimmedLine[separatorRange.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return value
    }
}
