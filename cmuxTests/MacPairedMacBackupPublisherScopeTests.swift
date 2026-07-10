import CMUXMobileCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct MacPairedMacBackupPublisherScopeTests {
    @Test func taggedPublisherTargetsTheMatchingIOSBackupScope() throws {
        let request = MacPairedMacBackupPublisher.makeRequest(
            url: try #require(URL(string: "https://presence.example/v1/sync/paired-macs")),
            accessToken: "token",
            teamID: "team-a",
            instanceTag: "feature-a",
            payload: Data("payload".utf8)
        )

        #expect(request.value(forHTTPHeaderField: "X-Cmux-Client-Scope") == "ios:v2:ZmVhdHVyZS1h")
        #expect(request.value(forHTTPHeaderField: "X-Cmux-Team-Id") == "team-a")
    }

    @Test func stablePublisherKeepsTheUnscopedBackupCollection() throws {
        let request = MacPairedMacBackupPublisher.makeRequest(
            url: try #require(URL(string: "https://presence.example/v1/sync/paired-macs")),
            accessToken: "token",
            teamID: nil,
            instanceTag: "default",
            payload: Data("payload".utf8)
        )

        #expect(request.value(forHTTPHeaderField: "X-Cmux-Client-Scope") == nil)
    }
}
