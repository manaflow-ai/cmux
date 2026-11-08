import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
    @Test func testMemoryCommandLabelsMultiWorkspaceGroupWithoutSingleOwner() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = "/tmp/cmux-memory-attribution-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(
            path: socketPath,
            response: Self.multiWorkspaceMemoryResponse
        )
        defer { responder.stop() }

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("CMUX_") {
            environment.removeValue(forKey: key)
        }
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["AppleLanguages"] = "(en)"
        environment["AppleLocale"] = "en_US"
        environment["LANG"] = "en_US.UTF-8"
        environment["LC_ALL"] = "en_US.UTF-8"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["--socket", socketPath, "memory", "--all"],
            environment: environment,
            timeout: 5
        )

        #expect(!result.timedOut, Comment(rawValue: result.stdout))
        #expect(result.status == 0, Comment(rawValue: result.stdout))
        #expect(result.stdout.contains("2 workspaces"), Comment(rawValue: result.stdout))
        #expect(!result.stdout.contains("workspace workspace:"), Comment(rawValue: result.stdout))
    }

    private static let multiWorkspaceMemoryResponse = #"""
    {"ok":true,"result":{"memory_diagnostic":{"summary":"100 MB app footprint + 23 MB child RSS; top child group: cmux 23 MB","app":{"pid":100,"name":"cmux","physical_footprint_bytes":104857600,"resident_bytes":52428800},"children":{"root_pid":100,"recursive_rss_bytes":24117248,"process_count":2,"pids":[101,102],"groups":[{"id":"cmux","name":"cmux","rss_bytes":24117248,"resident_bytes":24117248,"process_count":2,"pids":[101,102],"group_attribution":{"kind":"multiple","owner":null,"workspace_count":2,"owner_count":2,"attributed_process_count":2,"unattributed_process_count":0},"top_attribution":{"workspace_id":"11111111-1111-1111-1111-111111111111","workspace_ref":"workspace:1","pane_id":null,"pane_ref":null,"surface_id":null,"surface_ref":null,"surface_type":null,"reason":"surface-process-tree","rss_bytes":12582912,"resident_bytes":12582912,"process_count":1,"pids":[101]},"attributions":[{"workspace_id":"11111111-1111-1111-1111-111111111111","workspace_ref":"workspace:1","pane_id":null,"pane_ref":null,"surface_id":null,"surface_ref":null,"surface_type":null,"reason":"surface-process-tree","rss_bytes":12582912,"resident_bytes":12582912,"process_count":1,"pids":[101]},{"workspace_id":"22222222-2222-2222-2222-222222222222","workspace_ref":"workspace:2","pane_id":null,"pane_ref":null,"surface_id":null,"surface_ref":null,"surface_type":null,"reason":"surface-process-tree","rss_bytes":11534336,"resident_bytes":11534336,"process_count":1,"pids":[102]}]}]}}}}
    """#
}
