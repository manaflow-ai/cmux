import CmuxDockExtensions
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("DockExtension socket payloads")
struct DockExtensionSocketPayloadTests {
    private func makeManifest() -> DockExtensionManifest {
        DockExtensionManifest(
            manifestVersion: 1,
            id: "token-usage",
            name: "Token Usage",
            version: "0.2.0",
            description: "Live spend",
            build: [DockExtensionBuildStep(command: ["npm", "install"])],
            panes: [
                DockExtensionPane(
                    id: "main",
                    title: "Token Usage",
                    command: ["./run.sh", "with space"],
                    env: ["MODE": "live"],
                    cwd: "app"
                ),
            ]
        )
    }

    @Test func listPayloadCarriesIdentityPinAndPanes() {
        let record = DockExtensionInstallRecord(
            id: "token-usage",
            source: .github(owner: "o", repository: "r", subdirectory: nil),
            pinnedSha: String(repeating: "a", count: 40),
            ref: "main",
            installedAt: Date(timeIntervalSince1970: 1_750_000_000),
            enabled: true,
            consentFingerprint: "fp"
        )
        let installed = InstalledDockExtension(
            record: record,
            manifest: makeManifest(),
            rootDirectory: URL(fileURLWithPath: "/tmp/checkout", isDirectory: true),
            status: .ok
        )
        let payload = installed.socketPayload
        #expect(payload["id"] as? String == "token-usage")
        #expect(payload["name"] as? String == "Token Usage")
        #expect(payload["version"] as? String == "0.2.0")
        #expect(payload["source"] as? String == "o/r")
        #expect(payload["pinned_sha"] as? String == String(repeating: "a", count: 40))
        #expect(payload["status"] as? String == "ok")
        #expect(payload["enabled"] as? Bool == true)
        #expect(payload["linked"] as? Bool == false)
        let panes = payload["panes"] as? [[String: Any]]
        #expect(panes?.count == 1)
        #expect(panes?.first?["qualified_id"] as? String == "token-usage.main")
    }

    @Test func unhealthyAndDisabledStatesSurfaceInPayload() {
        let record = DockExtensionInstallRecord(
            id: "x",
            source: .local(path: "/tmp/dev"),
            pinnedSha: nil,
            installedAt: Date(timeIntervalSince1970: 1_750_000_000),
            enabled: false,
            consentFingerprint: "fp"
        )
        let installed = InstalledDockExtension(
            record: record,
            manifest: nil,
            rootDirectory: URL(fileURLWithPath: "/tmp/dev", isDirectory: true),
            status: .manifestUnavailable("no manifest")
        )
        let payload = installed.socketPayload
        #expect(payload["status"] as? String == "unavailable")
        #expect(payload["status_message"] as? String == "no manifest")
        #expect(payload["enabled"] as? Bool == false)
        #expect(payload["linked"] as? Bool == true)
        #expect((payload["panes"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func previewPayloadCarriesTokenCommandsAndKind() {
        let preview = DockExtensionInstallPreview(
            source: .github(owner: "o", repository: "r", subdirectory: nil),
            resolvedSha: String(repeating: "b", count: 40),
            ref: "main",
            manifest: makeManifest(),
            stagingDirectory: URL(fileURLWithPath: "/tmp/staging", isDirectory: true),
            warnings: ["some warning"],
            kind: .update(previousSha: String(repeating: "c", count: 40))
        )
        let payload = preview.socketPayload(token: "tok-1")
        #expect(payload["preview_token"] as? String == "tok-1")
        #expect(payload["kind"] as? String == "update")
        #expect(payload["previous_sha"] as? String == String(repeating: "c", count: 40))
        #expect(payload["resolved_sha"] as? String == String(repeating: "b", count: 40))
        #expect(payload["warnings"] as? [String] == ["some warning"])
        #expect(payload["build_commands"] as? [String] == ["npm install"])
        let panes = payload["panes"] as? [[String: Any]]
        #expect(panes?.first?["command"] as? String == "./run.sh 'with space'")
        #expect(panes?.first?["cwd"] as? String == "app")
        #expect(panes?.first?["env_keys"] as? [String] == ["MODE"])
    }
}
