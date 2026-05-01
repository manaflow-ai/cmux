import XCTest
@testable import cmux_DEV

final class TerminalServerCatalogTests: XCTestCase {
    func testCatalogDecodesTeamServerMetadata() throws {
        let json = """
        {
          "cmux": {
            "servers": [
              {
                "id": "cmux-macmini",
                "name": "Mac mini",
                "hostname": "cmux-macmini",
                "port": 22,
                "username": "cmux",
                "symbolName": "desktopcomputer",
                "palette": "mint",
                "transport": "cmuxd-remote",
                "direct_tls_pins": ["sha256:pin-a", "sha256:pin-b"]
              }
            ]
          }
        }
        """

        let catalog = try TerminalServerCatalog(metadataJSON: json, teamID: "team-1")

        XCTAssertEqual(catalog.hosts.map(\.stableID), ["cmux-macmini"])
        XCTAssertEqual(catalog.hosts.first?.transportPreference, .remoteDaemon)
        XCTAssertEqual(catalog.hosts.first?.source, .discovered)
        XCTAssertEqual(catalog.hosts.first?.teamID, "team-1")
        XCTAssertEqual(catalog.hosts.first?.serverID, "cmux-macmini")
        XCTAssertEqual(catalog.hosts.first?.directTLSPins, ["sha256:pin-a", "sha256:pin-b"])
    }

    func testMergePreservesLocalSecretsAndExistingWorkspaceHostIDs() {
        let discovered = [
            TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini",
                allowsSSHFallback: false,
                directTLSPins: ["sha256:new-pin"]
            )
        ]

        let preservedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let local = [
            TerminalHost(
                id: preservedID,
                stableID: "cmux-macmini",
                name: "Old Label",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                bootstrapCommand: "tmux new-session -A -s {{session}}",
                trustedHostKey: "ssh-ed25519 AAAA",
                sortIndex: 4,
                source: .discovered,
                transportPreference: .rawSSH,
                directTLSPins: ["sha256:old-pin"]
            )
        ]

        let merged = TerminalServerCatalog.merge(discovered: discovered, local: local)

        XCTAssertEqual(merged.first?.id, preservedID)
        XCTAssertEqual(merged.first?.trustedHostKey, "ssh-ed25519 AAAA")
        XCTAssertEqual(merged.first?.sortIndex, 4)
        XCTAssertEqual(merged.first?.transportPreference, .remoteDaemon)
        XCTAssertEqual(merged.first?.name, "Mac mini")
        XCTAssertEqual(merged.first?.teamID, "team-1")
        XCTAssertEqual(merged.first?.serverID, "cmux-macmini")
        XCTAssertEqual(merged.first?.allowsSSHFallback, true)
        XCTAssertEqual(merged.first?.directTLSPins, ["sha256:new-pin"])
    }

    func testMergePreservesExistingSSHFallbackPreference() {
        let discovered = [
            TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini",
                allowsSSHFallback: true
            )
        ]

        let local = [
            TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .custom,
                transportPreference: .rawSSH,
                allowsSSHFallback: false
            )
        ]

        let merged = TerminalServerCatalog.merge(discovered: discovered, local: local)

        XCTAssertEqual(merged.first?.allowsSSHFallback, false)
    }

    func testMergePreservesLocalSSHAuthenticationMethodForDiscoveredHosts() {
        let discovered = [
            TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini"
            )
        ]

        let local = [
            TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .rawSSH,
                sshAuthenticationMethod: .privateKey
            )
        ]

        let merged = TerminalServerCatalog.merge(discovered: discovered, local: local)

        XCTAssertEqual(merged.first?.sshAuthenticationMethod, .privateKey)
    }

    func testMergePreservesLocalBootstrapCommandForDiscoveredHosts() {
        let discovered = [
            TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                bootstrapCommand: "tmux new-session -A -s {{session}}",
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini"
            )
        ]

        let local = [
            TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                bootstrapCommand: "cmux attach --workspace {{session}}",
                source: .discovered,
                transportPreference: .remoteDaemon
            )
        ]

        let merged = TerminalServerCatalog.merge(discovered: discovered, local: local)

        XCTAssertEqual(merged.first?.bootstrapCommand, "cmux attach --workspace {{session}}")
    }

    func testMergeReplacesPlaceholderCustomHostWithLiveMachine() {
        let placeholderID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let discovered = [
            TerminalHost(
                stableID: "machine-macmini-live",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini",
                allowsSSHFallback: false
            )
        ]

        let local = [
            TerminalHost(
                id: placeholderID,
                stableID: "cmux-setup",
                name: "Mac mini",
                hostname: "",
                username: "",
                symbolName: "desktopcomputer",
                palette: .mint,
                sortIndex: 3,
                source: .custom,
                transportPreference: .rawSSH
            )
        ]

        let merged = TerminalServerCatalog.merge(discovered: discovered, local: local)

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.id, placeholderID)
        XCTAssertEqual(merged.first?.stableID, "machine-macmini-live")
        XCTAssertEqual(merged.first?.hostname, "cmux-macmini")
        XCTAssertEqual(merged.first?.username, "cmux")
        XCTAssertEqual(merged.first?.source, .discovered)
        XCTAssertEqual(merged.first?.serverID, "cmux-macmini")
        XCTAssertEqual(merged.first?.sortIndex, 3)
    }

    func testCatalogNormalizesDirectTLSPinsFromMetadata() throws {
        let json = """
        {
          "cmux": {
            "servers": [
              {
                "id": "cmux-macmini",
                "name": "Mac mini",
                "hostname": "cmux-macmini",
                "username": "cmux",
                "transport": "cmuxd-remote",
                "direct_tls_pins": [" sha256:pin-a ", "", "sha256:pin-a", "sha256:pin-b "]
              }
            ]
          }
        }
        """

        let catalog = try TerminalServerCatalog(metadataJSON: json, teamID: "team-1")

        XCTAssertEqual(catalog.hosts.first?.directTLSPins, ["sha256:pin-a", "sha256:pin-b"])
    }

    func testGeneratedLocalEndpointNameFollowsCurrentDaemonPort() {
        let updatedName = TailscaleServerDiscovery.refreshedEndpointDisplayName(
            currentName: "Local Dev (:52191)",
            hostname: "127.0.0.1",
            port: 52192,
            source: .discovered
        )

        XCTAssertEqual(updatedName, "Local Dev (:52192)")
    }

    func testGeneratedEndpointNameDoesNotOverwriteCustomName() {
        let updatedName = TailscaleServerDiscovery.refreshedEndpointDisplayName(
            currentName: "Mac mini",
            hostname: "127.0.0.1",
            port: 52192,
            source: .discovered
        )
        let customHostName = TailscaleServerDiscovery.refreshedEndpointDisplayName(
            currentName: "Local Dev (:52191)",
            hostname: "127.0.0.1",
            port: 52192,
            source: .custom
        )

        XCTAssertEqual(updatedName, "Mac mini")
        XCTAssertEqual(customHostName, "Local Dev (:52191)")
    }
}
