import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension CampfireSupportTests {
    static func detectedCampfireSnapshot(
        processName: String = "campfire",
        processPath: String? = "/Users/example/.local/bin/campfire",
        arguments: [String],
        environment: [String: String],
        registration: CmuxVaultAgentRegistration = .builtInCampfire,
        defaultCampfireSessionRole: String? = "host"
    ) -> SessionRestorableAgentSnapshot? {
        let workspaceId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let panelId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let processId = 4243
        let panelKey = RestorableAgentSessionIndex.PanelKey(workspaceId: workspaceId, panelId: panelId)
        let processSnapshot = CmuxTopProcessSnapshot(
            processes: [
                CmuxTopProcessInfo(
                    pid: processId,
                    parentPID: 1,
                    name: processName,
                    path: processPath,
                    ttyDevice: nil,
                    cmuxWorkspaceID: workspaceId,
                    cmuxSurfaceID: panelId,
                    cmuxAttributionReason: "cmux-test",
                    processGroupID: nil,
                    terminalProcessGroupID: nil,
                    cpuPercent: 0,
                    residentBytes: 0,
                    virtualBytes: 0,
                    threadCount: 1
                )
            ],
            sampledAt: Date(timeIntervalSince1970: 0),
            includesProcessDetails: true
        )
        var processEnvironment = environment
        if let defaultCampfireSessionRole,
           processEnvironment["CAMPFIRE_SESSION_ROLE"] == nil {
            processEnvironment["CAMPFIRE_SESSION_ROLE"] = defaultCampfireSessionRole
        }
        return RestorableAgentSessionIndex.processDetectedSnapshots(
            registry: CmuxVaultAgentRegistry(registrations: [registration]),
            fileManager: FileManager.default,
            processSnapshot: processSnapshot,
            capturedAt: 42,
            processArgumentsProvider: { requestedProcessId in
                guard requestedProcessId == processId else { return nil }
                return CmuxTopProcessArguments(arguments: arguments, environment: processEnvironment)
            }
        )[panelKey]?.snapshot
    }

    static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    static func makeTemporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeSessionFile(id: String, in directory: URL, modifiedAt: Date) throws -> URL {
        let url = directory.appendingPathComponent("\(id).jsonl", isDirectory: false)
        try "{}\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }
}
