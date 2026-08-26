import Foundation
import Testing

#if canImport(cmux_DEV)
    @testable import cmux_DEV
#elseif canImport(cmux)
    @testable import cmux
#endif

@Suite
struct LinksLocalizationInterpolationTests {
    @Test
    func localizedDefaultsCarryInterpolationArguments() {
        let count = 7
        let source = "Terminal"
        let time = "3:15 PM"
        let countText = String(
            localized: "linksPane.count.other",
            defaultValue: "\(count) Links"
        )
        let repeatText = String(
            localized: "linksPane.repeatCount",
            defaultValue: "×\(count)"
        )
        let sourceText = String(
            localized: "linksPane.row.sourceAndTime",
            defaultValue: "\(source) · \(time)"
        )

        #expect(countText.contains(String(count)))
        #expect(repeatText.contains(String(count)))
        #expect(sourceText.contains(source))
        #expect(sourceText.contains(time))
        #expect(!countText.contains("%lld"))
        #expect(!repeatText.contains("%lld"))
        #expect(!sourceText.contains("%@"))
    }
}
