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
        let targetNamespace = try #require(MobileIOSAppNamespace(
            bundleIdentifier: "dev.cmux.ios.feature-a"
        ))
        let request = MacPairedMacBackupPublisher.makeRequest(
            url: try #require(URL(string: "https://presence.example/v1/sync/paired-macs")),
            accessToken: "token",
            teamID: "team-a",
            targetNamespace: targetNamespace,
            payload: Data("payload".utf8)
        )

        #expect(
            request.value(forHTTPHeaderField: "X-Cmux-Client-Scope")
                == "ios:v3:ZGV2LmNtdXguaW9zLmZlYXR1cmUtYQ"
        )
        #expect(request.value(forHTTPHeaderField: "X-Cmux-Team-Id") == "team-a")
    }

    @Test func releasePublishersTargetEachExactIOSBackupScope() throws {
        let bundleIdentifiers = [
            "com.cmux.app",
            "dev.cmux.app.beta",
            "dev.cmux.app.internal",
            "dev.cmux.app.demo",
        ]
        for bundleIdentifier in bundleIdentifiers {
            let targetNamespace = try #require(MobileIOSAppNamespace(
                bundleIdentifier: bundleIdentifier
            ))
            let request = MacPairedMacBackupPublisher.makeRequest(
                url: try #require(URL(
                    string: "https://presence.example/v1/sync/paired-macs"
                )),
                accessToken: "token",
                teamID: nil,
                targetNamespace: targetNamespace,
                payload: Data("payload".utf8)
            )

            #expect(
                request.value(forHTTPHeaderField: "X-Cmux-Client-Scope")
                    == targetNamespace.serverScope
            )
        }
    }

    @Test func publisherRecordCarriesCompareAndSetInstanceAuthority() throws {
        let record = MacPairedMacBackupRecordWire(
            macDeviceID: "mac-a",
            displayName: "Studio",
            routes: [],
            instanceTag: "feature-a",
            createdAt: 1,
            lastSeenAt: 2,
            isActive: true
        )
        let json = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(record)
        ) as? [String: Any])

        #expect(json["instanceTag"] as? String == "feature-a")
        #expect(json["instanceTagWriteMode"] as? String == "compare_and_set")
    }
}
