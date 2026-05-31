import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct PrivacyUsageDescriptionBundleTests {
    @Test
    func appBundleDeclaresSpeechRecognitionUsageDescription() throws {
        let usageDescription = try #require(Bundle(for: AppDelegate.self)
            .object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") as? String
        )

        #expect(usageDescription == "A program running within cmux would like to use speech recognition.")
    }
}
