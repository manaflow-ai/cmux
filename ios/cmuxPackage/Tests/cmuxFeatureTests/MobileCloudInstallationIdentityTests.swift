import Foundation
import Testing
@testable import cmuxFeature

#if targetEnvironment(simulator)
@Suite
struct MobileCloudInstallationIdentityTests {
    @Test
    func cloudAndTransportShareThePersistedInstallationID() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-identity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = MobileIrohV2Configuration(
            baseURL: try #require(URL(string: "https://example.invalid")),
            environment: "development", projectID: "test", appNamespace: "cloud-identity-test",
            buildTag: "test", appVersion: "1", displayName: "Test", stateDirectory: directory
        )
        let runtime = MobileIrxRuntimeComposition(configuration: configuration)
        async let cloudID = runtime.installationDeviceID()
        async let transportID = runtime.installation.deviceID()
        let (cloud, transport) = try await (cloudID, transportID)
        #expect(cloud == transport)
        #expect(UUID(uuidString: cloud) != nil)
        let relaunched = MobileIrxRuntimeComposition(configuration: configuration)
        #expect(try await relaunched.installationDeviceID() == cloud)
    }
}
#endif
