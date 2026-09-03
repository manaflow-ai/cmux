import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
    @Test func cloudDomainsDefaultsToListAndPrintsCustomerDNSInstructions() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-domains-list-\(UUID().uuidString.prefix(8)).sock"
        let customRetry = cloudDomainPublicationWithoutVerification(
            id: "pub-retry",
            hostname: "retry.example.com",
            domainKind: "custom",
            state: "provider_setup_failed"
        )
        let generated = cloudDomainPublicationWithoutVerification(
            id: "pub-generated",
            hostname: "bright-otter.cmux.sh",
            domainKind: "generated",
            state: "active"
        )
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: try cloudDomainsV2Response(
                result: [
                    "publications": [
                        cloudDomainPublicationFixture(),
                        customRetry,
                        generated,
                    ]
                ]
            )
        )
        defer { responder.stop() }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["cloud", "domains"],
            environment: cloudDomainsEnvironment(socketPath: socketPath),
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
        #expect(result.stdout.contains("https://preview.example.com"))
        #expect(result.stdout.contains("verification: pending"))
        #expect(result.stdout.contains("TXT _cmux.preview.example.com cmux-token"))
        #expect(
            result.stdout.contains(
                "CNAME/ALIAS/ANAME/CNAME_FLATTENING preview.example.com beta-web.freestyle.sh"
            )
        )
        #expect(
            result.stdout.contains(
                "NS _acme-challenge.preview.example.com beta-dns.freestyle.sh"
            )
        )
        #expect(result.stdout.contains("verification: provider_setup_failed"))
        #expect(result.stdout.contains("cmux cloud domains verify retry.example.com"))
        #expect(result.stdout.contains("cmux cloud domains verify preview.example.com"))
        #expect(result.stdout.contains("verification: not required (cmux domain)"))
        let request = try cloudDomainsRequest(from: try #require(responder.receivedRequests.first))
        #expect(request["method"] as? String == "vm.publication_list")
    }

    @Test func cloudDomainsPublishSendsPolicyAndReturnsStableJSON() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-domains-publish-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: try cloudDomainsV2Response(
                result: ["publication": cloudDomainPublicationFixture()]
            )
        )
        defer { responder.stop() }

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "cloud", "domains", "publish", "vm-alpha", "3000",
                "--domain", "preview.example.com", "--access", "team",
                "--team", "team-1", "--json",
            ],
            environment: cloudDomainsEnvironment(socketPath: socketPath),
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
        let request = try cloudDomainsRequest(from: try #require(responder.receivedRequests.first))
        #expect(request["method"] as? String == "vm.publication_create")
        let params = try #require(request["params"] as? [String: Any])
        #expect(params["vmId"] as? String == "vm-alpha")
        #expect(params["port"] as? Int == 3000)
        #expect(params["hostname"] as? String == "preview.example.com")
        #expect(params["accessMode"] as? String == "team")
        #expect(params["teamId"] as? String == "team-1")

        let output = try #require(
            JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
        )
        let publication = try #require(output["publication"] as? [String: Any])
        let verification = try #require(publication["verification"] as? [String: Any])
        #expect(verification["state"] as? String == "pending")
        let instructions = try #require(verification["dnsInstructions"] as? [String: Any])
        let routing = try #require(instructions["routing"] as? [String: Any])
        #expect(
            routing["recordTypes"] as? [String]
                == ["CNAME", "ALIAS", "ANAME", "CNAME_FLATTENING"]
        )
    }

    @Test func cloudDomainMutationCommandsAddressDomainsByName() throws {
        let cliPath = try bundledCLIPath()
        let specs: [(
            suffix: String,
            arguments: [String],
            method: String,
            params: [String: String],
            response: [String: Any],
            expectedOutput: String
        )] = [
            (
                "verify-zone",
                ["cloud", "domains", "verify", "example.com"],
                "vm.domain_verify",
                ["name": "example.com"],
                ["domain": cloudDomainZoneFixture()],
                "example.com\nid: zone-1\nverification: pending"
            ),
            (
                "verify-publication",
                ["cloud", "domains", "verify", "prickly-lavender-minnow"],
                "vm.domain_verify",
                ["name": "prickly-lavender-minnow"],
                ["publication": cloudDomainPublicationFixture()],
                "https://preview.example.com"
            ),
            (
                "access",
                ["cloud", "domains", "access", "preview.example.com", "public"],
                "vm.publication_update",
                ["id": "preview.example.com", "accessMode": "public"],
                ["publication": cloudDomainPublicationFixture()],
                "https://preview.example.com"
            ),
            (
                "remove",
                ["cloud", "domains", "rm", "preview.example.com"],
                "vm.publication_delete",
                ["id": "preview.example.com"],
                ["deleted": true, "id": "pub-1"],
                "Removed publication preview.example.com."
            ),
        ]

        for spec in specs {
            let socketPath = "/tmp/cmux-domains-\(spec.suffix)-\(UUID().uuidString.prefix(8)).sock"
            let responder = try UnixSocketResponder(
                path: socketPath,
                response: try cloudDomainsV2Response(result: spec.response)
            )
            let result = runProcess(
                executablePath: cliPath,
                arguments: spec.arguments,
                environment: cloudDomainsEnvironment(socketPath: socketPath),
                timeout: 5
            )
            responder.stop()

            #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
            #expect(result.status == 0, Comment(rawValue: result.diagnostics))
            #expect(result.stdout.contains(spec.expectedOutput), Comment(rawValue: result.stdout))
            let request = try cloudDomainsRequest(
                from: try #require(responder.receivedRequests.first)
            )
            #expect(request["method"] as? String == spec.method)
            let params = try #require(request["params"] as? [String: Any])
            for (key, value) in spec.params {
                #expect(params[key] as? String == value)
            }
            if spec.method == "vm.publication_update" {
                #expect(params["teamId"] == nil)
            }
        }
    }

    @Test func cloudDomainsZonesListsOwnedZonesApartFromPublications() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-domains-zones-\(UUID().uuidString.prefix(8)).sock"
        let pendingZone = cloudDomainZoneFixture()
        let verifiedZone: [String: Any] = [
            "id": "zone-2",
            "hostname": "verified.example.net",
            "verificationState": "verified",
            "certificateState": "active",
            "createdAt": NSNull(),
            "dnsInstructions": NSNull(),
            "publications": [],
        ]
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: try cloudDomainsV2Response(result: ["domains": [pendingZone, verifiedZone]])
        )
        defer { responder.stop() }

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["cloud", "domains", "zones"],
            environment: cloudDomainsEnvironment(socketPath: socketPath),
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
        #expect(
            result.stdout.contains(
                "example.com\nid: zone-1\nverification: pending\ncertificate: missing\n"
                    + "publications: preview.example.com (provisioning)"
            )
        )
        #expect(result.stdout.contains("TXT _cmux.example.com cmux-token"))
        #expect(result.stdout.contains("NS _acme-challenge.example.com beta-dns.freestyle.sh"))
        #expect(result.stdout.contains("cmux cloud domains verify example.com"))
        #expect(!result.stdout.contains("cmux cloud domains verify verified.example.net"))
        #expect(
            result.stdout.contains(
                "verified.example.net\nid: zone-2\nverification: verified\ncertificate: active\n"
                    + "publications: none"
            )
        )
        #expect(!result.stdout.contains("verified.example.net beta-web"))
        let request = try cloudDomainsRequest(from: try #require(responder.receivedRequests.first))
        #expect(request["method"] as? String == "vm.domain_list")
    }

    private func cloudDomainZoneFixture() -> [String: Any] {
        [
            "id": "zone-1",
            "hostname": "example.com",
            "verificationState": "pending",
            "certificateState": "missing",
            "createdAt": "2026-09-02T12:00:00.000Z",
            "dnsInstructions": [
                "verification": [
                    "purpose": "verification",
                    "recordTypes": ["TXT"],
                    "name": "_cmux.example.com",
                    "value": "cmux-token",
                ],
                "certificate": [
                    "purpose": "certificate",
                    "recordTypes": ["NS"],
                    "name": "_acme-challenge.example.com",
                    "value": "beta-dns.freestyle.sh",
                ],
            ],
            "publications": [
                ["id": "pub-1", "hostname": "preview.example.com", "state": "provisioning"],
            ],
        ]
    }

    private func cloudDomainsEnvironment(socketPath: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
        return environment
    }

    private func cloudDomainsV2Response(result: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["ok": true, "result": result],
            options: [.sortedKeys]
        )
        return try #require(String(data: data, encoding: .utf8))
    }

    private func cloudDomainsRequest(from line: String) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
    }

    private func cloudDomainPublicationFixture() -> [String: Any] {
        [
            "id": "pub-1",
            "hostname": "preview.example.com",
            "url": "https://preview.example.com",
            "domainKind": "custom",
            "vmId": "vm-alpha",
            "port": 3000,
            "accessMode": "team",
            "teamId": "team-1",
            "state": "pending_verification",
            "routingRevision": 1,
            "verification": [
                "verificationId": "verify-1",
                "domain": "preview.example.com",
                "state": "pending",
                "dnsInstructions": [
                    "verification": [
                        "purpose": "verification",
                        "recordTypes": ["TXT"],
                        "name": "_cmux.preview.example.com",
                        "value": "cmux-token",
                    ],
                    "routing": [
                        "purpose": "routing",
                        "recordTypes": ["CNAME", "ALIAS", "ANAME", "CNAME_FLATTENING"],
                        "name": "preview.example.com",
                        "value": "beta-web.freestyle.sh",
                    ],
                    "certificate": [
                        "purpose": "certificate",
                        "recordTypes": ["NS"],
                        "name": "_acme-challenge.preview.example.com",
                        "value": "beta-dns.freestyle.sh",
                    ],
                ],
            ],
        ]
    }

    private func cloudDomainPublicationWithoutVerification(
        id: String,
        hostname: String,
        domainKind: String,
        state: String
    ) -> [String: Any] {
        [
            "id": id,
            "hostname": hostname,
            "url": "https://\(hostname)",
            "domainKind": domainKind,
            "vmId": "vm-alpha",
            "port": 3000,
            "accessMode": "personal",
            "teamId": NSNull(),
            "state": state,
            "routingRevision": 1,
            "verification": NSNull(),
        ]
    }
}
