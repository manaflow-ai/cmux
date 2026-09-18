import Foundation
import Testing
@testable import cmuxFeature

@MainActor
struct MobileIrohV2ConfigurationTests {
    @Test
    func emptyBuildSettingsUseDevelopmentDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bundle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = [
            "CFBundleIdentifier": "dev.cmux.ios.config-test",
            "CMUX_IROH_V2_ENVIRONMENT": "",
            "CMUX_IROH_V2_BASE_URL": "",
            "CMUX_IROH_V2_FORCE_RELAY": ""
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: root))
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let configuration = MobileIrohV2Configuration.current(
            projectID: "project", bundle: bundle, environment: [:], defaults: defaults
        )
        #expect(configuration.environment == "development")
        #expect(configuration.baseURL.absoluteString == "https://cmux-iroh-v2-development.debussy.workers.dev")
    }
}
