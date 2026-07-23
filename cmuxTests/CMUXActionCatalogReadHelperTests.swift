import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct CMUXActionCatalogReadHelperTests {
    @Test
    func helperServiceWritesTheSameStrictFrame() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-helper-service-\(UUID().uuidString)",
            isDirectory: true
        )
        let project = root.appendingPathComponent("-cwd\n;$()", isDirectory: true)
        let configDirectory = project.appendingPathComponent(".cmux", isDirectory: true)
        let localURL = configDirectory.appendingPathComponent("cmux.json")
        let globalURL = root.appendingPathComponent("global.json")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("12345678".utf8).write(to: localURL)

        var writes: [Data] = []
        let helper = CMUXActionCatalogReadHelper { writes.append($0) }
        let status = helper.runIfRequested(arguments: [
            "/unused/cmux",
            CmuxConfigActionCatalogProcessReader.helperCommand,
            project.path,
            globalURL.path,
            "4",
        ])
        #expect(status == 0)
        #expect(writes.count == 1)
        let output = try #require(writes.first)
        let response = try #require(CmuxConfigActionCatalogFrameCodec.shared.decode(
            output,
            maximumConfigBytes: 4
        ))
        #expect(response.localPath == localURL.path)
        #expect(response.local?.status == .tooLarge)
        #expect(response.local?.data.isEmpty == true)
        #expect(response.global.status == .missing)
        #expect(response.global.data.isEmpty)
    }

    @Test
    func bundledHelperPreservesArgvPathsAndEnforcesSizeCaps() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "cmux-helper-\(UUID().uuidString)",
            isDirectory: true
        )
        let project = root.appendingPathComponent(
            "-project\n;$(touch should-not-run) [x]",
            isDirectory: true
        )
        let configDirectory = project.appendingPathComponent(".cmux", isDirectory: true)
        let localURL = configDirectory.appendingPathComponent("cmux.json")
        let globalURL = root.appendingPathComponent("global config.json")
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let localData = Data(#"{"actions":{"local":{"type":"command","command":"true"}}}"#.utf8)
        let globalData = Data(#"{"actions":{"global":{"type":"command","command":"true"}}}"#.utf8)
        try localData.write(to: localURL)
        try globalData.write(to: globalURL)
        let executable = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )

        let result = try run(
            executable: executable,
            arguments: [
                CmuxConfigActionCatalogProcessReader.helperCommand,
                project.path,
                globalURL.path,
                "1024",
            ]
        )
        #expect(result.status == 0)
        let response = try #require(CmuxConfigActionCatalogFrameCodec.shared.decode(
            result.output,
            maximumConfigBytes: 1024
        ))
        #expect(response.localPath == localURL.path)
        #expect(response.local == .init(status: .data, data: localData))
        #expect(response.global == .init(status: .data, data: globalData))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("should-not-run").path
        ))

        let cappedResult = try run(
            executable: executable,
            arguments: [
                CmuxConfigActionCatalogProcessReader.helperCommand,
                project.path,
                globalURL.path,
                "4",
            ]
        )
        #expect(cappedResult.status == 0)
        let capped = try #require(CmuxConfigActionCatalogFrameCodec.shared.decode(
            cappedResult.output,
            maximumConfigBytes: 4
        ))
        #expect(capped.local?.status == .tooLarge)
        #expect(capped.local?.data.isEmpty == true)
        #expect(capped.global.status == .tooLarge)
        #expect(capped.global.data.isEmpty)

        let globalOnlyResult = try run(
            executable: executable,
            arguments: [
                CmuxConfigActionCatalogProcessReader.helperCommand,
                "",
                globalURL.path,
                "1024",
            ]
        )
        let globalOnly = try #require(CmuxConfigActionCatalogFrameCodec.shared.decode(
            globalOnlyResult.output,
            maximumConfigBytes: 1024
        ))
        #expect(globalOnly.localPath == nil)
        #expect(globalOnly.local == nil)
    }

    private func run(
        executable: String,
        arguments: [String]
    ) throws -> (status: Int32, output: Data) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            Issue.record("helper failed: \(String(data: errorOutput, encoding: .utf8) ?? "")")
        }
        return (process.terminationStatus, output)
    }
}
