import Foundation
import Testing

extension CMUXCLIErrorOutputRegressionTests {
    @Test(arguments: ["next-transport-ticket", "next-transport-grant"])
    func nextTransportRequiresOutputBeforeRPC(command: String) throws {
        let cli = try bundledCLIPath()
        let socket = "/tmp/cmux-next-output-\(UUID().uuidString.prefix(8)).sock"
        let responder = try UnixSocketResponder(path: socket, response: "{\"secret\":\"must-not-mint\"}")
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX_") }
        environment["CMUX_SOCKET_PATH"] = socket
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cli, arguments: [command], environment: environment, timeout: 5)
        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 1, Comment(rawValue: result.diagnostics))
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("--output"), Comment(rawValue: result.diagnostics))
        #expect(responder.receivedRequests.isEmpty)
    }

    @Test(arguments: ["next-transport-ticket", "next-transport-grant"])
    func nextTransportServerRefusalExitsUnsuccessfully(command: String) throws {
        let cli = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-refusal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = "/tmp/cmux-next-refusal-\(UUID().uuidString.prefix(8)).sock"
        let output = root.appendingPathComponent("material.json")
        let secret = "server-private-diagnostic"
        let responder = try UnixSocketResponder(path: socket, response: "ERROR: \(secret)")
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX_") }
        environment["CMUX_SOCKET_PATH"] = socket
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cli, arguments: [command, "--output", output.path],
            environment: environment, timeout: 5)
        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 1, Comment(rawValue: result.diagnostics))
        #expect(result.stdout.isEmpty)
        #expect(!result.stderr.isEmpty)
        #expect(!(result.stdout + result.stderr).contains(secret))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(responder.receivedRequests.count == 1)
    }

    @Test(arguments: ["next-transport-ticket", "next-transport-grant"])
    func nextTransportSuccessfulHandoffWritesPrivateFile(command: String) throws {
        let cli = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-success-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = "/tmp/cmux-next-success-\(UUID().uuidString.prefix(8)).sock"
        let output = root.appendingPathComponent("material.json")
        let material = "{\"secret\":\"private-capability\"}"
        let responder = try UnixSocketResponder(path: socket, response: material)
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX_") }
        environment["CMUX_SOCKET_PATH"] = socket
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cli, arguments: [command, "--output", output.path],
            environment: environment, timeout: 5)
        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status == 0, Comment(rawValue: result.diagnostics))
        #expect(!(result.stdout + result.stderr).contains("private-capability"))
        #expect(try String(contentsOf: output, encoding: .utf8) == material)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(responder.receivedRequests.count == 1)
    }

    @Test func nextTransportTicketRejectsUnexpectedArgumentsBeforeRPC() throws {
        let cli = try bundledCLIPath()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("next-ticket-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let socket = "/tmp/cmux-next-ticket-\(UUID().uuidString.prefix(8)).sock"
        let output = root.appendingPathComponent("material.json")
        let responder = try UnixSocketResponder(path: socket, response: "{\"ticket\":\"must-not-mint\"}")
        defer { responder.stop() }
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CMUX_") }
        environment["CMUX_SOCKET_PATH"] = socket
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        let result = runProcess(
            executablePath: cli,
            arguments: ["next-transport-ticket", "unexpected", "--output", output.path],
            environment: environment, timeout: 5)
        #expect(!result.timedOut, Comment(rawValue: result.diagnostics))
        #expect(result.status != 0, Comment(rawValue: result.diagnostics))
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(responder.receivedRequests.isEmpty)
    }
}
