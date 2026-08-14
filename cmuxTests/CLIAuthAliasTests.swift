import CmuxControlSocket
import Darwin
import Foundation
import Testing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Minimal authenticated-socket stand-in for routed alias tests. The real app
/// performs the same request over its local control socket. Keeping this test
/// server here lets the child-launch tests exercise the one-use arm step
/// without starting the full AppKit host.
private enum CLICoderouterMockResponseMutation: Sendable, Equatable {
    case none
    case tamperProof
    case addEnvelopeKey
    case addPayloadKey
    case unsignedError
    case missingNewline
    case oversizedFrame
    case secondFrame
    case trailingWhitespace
}

private final class CLICoderouterMockHandoffServer: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var commands: [String] = []
        let handled = DispatchSemaphore(value: 0)
    }

    let path: String
    let teamBinding: String
    let capability: String
    private let listenerFD: Int32
    private let state: State
    private let lifecycleLock = NSLock()
    private var stopped = false

    init(
        name: String,
        teamBinding: String = String(repeating: "a", count: 64),
        errorCode: String? = nil,
        responseID: String = "coderouter-handoff-arm",
        responseMutation: CLICoderouterMockResponseMutation = .none
    ) throws {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let path = "/tmp/cli-\(name.prefix(8))-\(shortID).sock"
        let listenerFD = try Self.bindUnixSocket(at: path)
        self.path = path
        self.teamBinding = teamBinding
        let capabilityNonce = Data(repeating: 0x41, count: 32)
        let capabilityTag = Data(repeating: 0x42, count: 32)
        guard let capabilityNonceText = SocketClientCapabilityProof
            .encodeBase64URL32(capabilityNonce),
              let capabilityTagText = SocketClientCapabilityProof
                  .encodeBase64URL32(capabilityTag) else {
            throw NSError(domain: "cmux.tests", code: 1)
        }
        self.capability = "v1.\(capabilityNonceText).\(capabilityTagText)"
        self.listenerFD = listenerFD
        self.state = State()

        let state = self.state
        let capability = self.capability
        CLIMockAcceptLoopRegistry.shared.start(
            listenerFD: listenerFD,
            onConnection: { clientFD in
                defer {
                    Darwin.close(clientFD)
                    state.handled.signal()
                }
                guard let line = Self.readSingleRequest(from: clientFD) else {
                    return
                }
                state.lock.lock()
                state.commands.append(line)
                state.lock.unlock()
                let response = Self.response(
                    for: line,
                    capability: capability,
                    teamBinding: teamBinding,
                    errorCode: errorCode,
                    responseID: responseID,
                    responseMutation: responseMutation
                )
                _ = cliMockWriteAll(
                    Self.responseFrame(
                        response,
                        mutation: responseMutation
                    ),
                    to: clientFD
                )
            },
            onListenerClosed: {
                state.handled.signal()
            }
        )
    }

    func waitForRequest(timeout: TimeInterval = 5) -> Bool {
        state.handled.wait(timeout: .now() + timeout) == .success
    }

    func commandSnapshot() -> [String] {
        state.lock.lock()
        defer { state.lock.unlock() }
        return state.commands
    }

    func stop() {
        lifecycleLock.lock()
        guard !stopped else {
            lifecycleLock.unlock()
            return
        }
        stopped = true
        lifecycleLock.unlock()
        CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
        Darwin.close(listenerFD)
        unlink(path)
    }

    deinit { stop() }

    var capabilityEnvironment: [String: String] {
        ["CMUX_SOCKET_CAPABILITY": capability]
    }

    private static func readSingleRequest(from fileDescriptor: Int32) -> String? {
        var data = Data()
        while data.count <= 4_096 {
            var byte: UInt8 = 0
            let count = Darwin.read(fileDescriptor, &byte, 1)
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if count == 0 { return nil }
            data.append(byte)
            if byte == 0x0A {
                guard data.count <= 4_096 else { return nil }
                return String(data: Data(data.dropLast()), encoding: .utf8)
            }
        }
        return nil
    }

    private static func responseFrame(
        _ response: String,
        mutation: CLICoderouterMockResponseMutation
    ) -> String {
        switch mutation {
        case .missingNewline:
            response
        case .oversizedFrame:
            String(repeating: "x", count: 4_096) + "\n"
        case .secondFrame:
            response + "\n" + response + "\n"
        case .trailingWhitespace:
            response + "\n "
        default:
            response + "\n"
        }
    }

    private static func response(
        for requestLine: String,
        capability: String,
        teamBinding: String,
        errorCode: String?,
        responseID: String,
        responseMutation: CLICoderouterMockResponseMutation
    ) -> String {
        guard let data = requestLine.data(using: .utf8),
              let request = try? JSONSerialization.jsonObject(with: data)
                  as? [String: Any],
              request["id"] as? String
                  == SocketClientCapabilityProof.requestID,
              request["method"] as? String
                  == SocketClientCapabilityProof.method,
              let params = request["params"] as? [String: Any],
              let nonceText = params["capabilityNonce"] as? String,
              let nonce = SocketClientCapabilityProof.decodeBase64URL32(
                  nonceText
              ),
              let challengeText = params["clientChallenge"] as? String,
              let challenge = SocketClientCapabilityProof.decodeBase64URL32(
                  challengeText
              ),
              let processIDNumber = params["clientProcessID"] as? NSNumber,
              let processStartText = params[
                  "clientProcessStartAbsoluteTime"
              ] as? String,
              let processStart = SocketClientCapabilityProof
                  .decodeProcessStartTime(processStartText),
              let clientProof = params["clientProof"] as? String,
              SocketClientCapabilityProof.verifiesClientProof(
                  clientProof,
                  capability: capability,
                  nonce: nonce,
                  challenge: challenge,
                  processID: pid_t(processIDNumber.int32Value),
                  processStartAbsoluteTime: processStart
              ) else {
            return #"{"id":"\#(responseID)","ok":false,"error":{"code":"invalid_proof","message":"invalid"}}"#
        }
        if let errorCode {
            let generatedProof = SocketClientCapabilityProof.serverErrorProof(
                capability: capability,
                nonce: nonce,
                challenge: challenge,
                processID: pid_t(processIDNumber.int32Value),
                processStartAbsoluteTime: processStart,
                code: errorCode
            ) ?? String(repeating: "0", count: 64)
            let serverProof = responseMutation == .tamperProof
                ? String(repeating: "f", count: 64)
                : generatedProof
            if responseMutation == .unsignedError {
                return #"{"id":"\#(responseID)","ok":false,"error":{"code":"\#(errorCode)","message":"raw-arm-secret-must-not-leak"}}"#
            }
            let payloadExtra = responseMutation == .addPayloadKey
                ? #","unexpected":true"#
                : ""
            let envelopeExtra = responseMutation == .addEnvelopeKey
                ? #","unexpected":true"#
                : ""
            return #"{"id":"\#(responseID)","ok":false,"error":{"code":"\#(errorCode)","message":"raw-arm-secret-must-not-leak","data":{"serverProof":"\#(serverProof)"}\#(payloadExtra)}\#(envelopeExtra)}"#
        }
        let generatedProof = SocketClientCapabilityProof.serverProof(
            capability: capability,
            nonce: nonce,
            challenge: challenge,
            processID: pid_t(processIDNumber.int32Value),
            processStartAbsoluteTime: processStart,
            teamBinding: teamBinding
        ) ?? String(repeating: "0", count: 64)
        let serverProof = responseMutation == .tamperProof
            ? String(repeating: "f", count: 64)
            : generatedProof
        let payloadExtra = responseMutation == .addPayloadKey
            ? #", "unexpected":true"#
            : ""
        let envelopeExtra = responseMutation == .addEnvelopeKey
            ? #", "unexpected":true"#
            : ""
        return #"{"id":"\#(responseID)","ok":true,"result":{"armed":true,"protocolVersion":2,"teamBinding":"\#(teamBinding)","serverProof":"\#(serverProof)"\#(payloadExtra)}\#(envelopeExtra)}"#
    }

    private static func bindUnixSocket(at path: String) throws -> Int32 {
        unlink(path)
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "cmux.tests", code: Int(errno), userInfo: [
                NSLocalizedDescriptionKey: "failed to create handoff socket",
            ])
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(ENAMETOOLONG), userInfo: nil)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { buffer in
                for (index, byte) in bytes.enumerated() {
                    buffer[index] = CChar(bitPattern: byte)
                }
                buffer[bytes.count] = 0
            }
        }
#if os(macOS)
        address.sun_len = UInt8(min(MemoryLayout<sockaddr_un>.size, 255))
#endif
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 1) == 0 else {
            let bindError = errno
            Darwin.close(fd)
            throw NSError(domain: "cmux.tests", code: Int(bindError), userInfo: nil)
        }
        _ = chmod(path, 0o600)
        return fd
    }
}

extension CLINotifyProcessIntegrationRegressionTests {
    func testTopLevelLoginAliasesAuthLogin() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("auth-login")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
            case "auth.status":
                return self.v2Response(id: id, ok: true, result: ["signed_in": false])
            case "auth.begin_sign_in":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "signed_in": true,
                        "user": ["email": "dev@example.com"],
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["login"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "Opening sign-in popup on the cmux web app.\nSigned in as dev@example.com.\n")
        XCTAssertTrue(
            state.commands.contains { $0.contains(#""method":"auth.begin_sign_in""#) },
            "Expected login alias to call auth.begin_sign_in, saw \(state.commands)"
        )
    }

    func testTopLevelLogoutAliasesAuthLogout() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("auth-logout")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
            case "auth.status":
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "signed_in": true,
                        "user": ["email": "dev@example.com"],
                    ]
                )
            case "auth.sign_out":
                return self.v2Response(id: id, ok: true, result: ["signed_in": false])
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: ["logout"],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "Signed out.\n")
        XCTAssertTrue(
            state.commands.contains { $0.contains(#""method":"auth.sign_out""#) },
            "Expected logout alias to call auth.sign_out, saw \(state.commands)"
        )
    }

}

@Suite("CodeRouter CLI aliases")
struct CLICoderouterAliasTests {
    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    @Test("validates the exact Darwin handoff socket path limit")
    func validatesHandoffSocketPathLimit() {
        let pathWith103Bytes = "/" + String(repeating: "a", count: 102)
        let pathWith104Bytes = "/" + String(repeating: "a", count: 103)
        #expect(pathWith103Bytes.utf8.count == 103)
        #expect(pathWith104Bytes.utf8.count == 104)
        #expect(CMUXCLI.coderouterHandoffSocketPathIsValid(pathWith103Bytes))
        #expect(!CMUXCLI.coderouterHandoffSocketPathIsValid(pathWith104Bytes))
        #expect(!CMUXCLI.coderouterHandoffSocketPathIsValid("relative.sock"))
        #expect(!CMUXCLI.coderouterHandoffSocketPathIsValid("/tmp/cmux\n.sock"))
        #expect(!CMUXCLI.coderouterHandoffSocketPathIsValid("/tmp/cmux\u{200B}.sock"))
        #expect(CMUXCLI.coderouterHandoffSocketPathIsValid("/tmp/cmux\u{E0101}.sock"))
    }

    @Test("validates the exact raw arm response schema")
    func validatesExactRawArmResponseSchema() {
        let binding = String(repeating: "a", count: 64)
        let proof = String(repeating: "b", count: 64)
        let validSuccess = #"{"id":"coderouter-handoff-arm","ok":true,"result":{"armed":true,"protocolVersion":2,"teamBinding":"\#(binding)","serverProof":"\#(proof)"}}"#
        let validError = #"{"id":"coderouter-handoff-arm","ok":false,"error":{"code":"team_required","message":"ignored","data":{"serverProof":"\#(proof)"}}}"#
        #expect(CMUXCLI.coderouterHandoffResponseRawShapeIsValid(validSuccess))
        #expect(CMUXCLI.coderouterHandoffResponseRawShapeIsValid(validError))
        #expect(!CMUXCLI.coderouterHandoffResponseRawShapeIsValid(" \(validSuccess)"))
        #expect(!CMUXCLI.coderouterHandoffResponseRawShapeIsValid("\(validError)\u{00a0}"))

        let numericOK = validSuccess.replacingOccurrences(
            of: #""ok":true"#,
            with: #""ok":1"#
        )
        let numericArmed = validSuccess.replacingOccurrences(
            of: #""armed":true"#,
            with: #""armed":1"#
        )
        let floatVersion = validSuccess.replacingOccurrences(
            of: #""protocolVersion":2"#,
            with: #""protocolVersion":2.0"#
        )
        let exponentVersion = validSuccess.replacingOccurrences(
            of: #""protocolVersion":2"#,
            with: #""protocolVersion":2e0"#
        )
        let duplicateResultKey = validSuccess.replacingOccurrences(
            of: #""armed":true"#,
            with: #""armed":true,"armed":true"#
        )
        let escapedDuplicateResultKey = validSuccess.replacingOccurrences(
            of: #""armed":true"#,
            with: #""\u0061rmed":false,"armed":true"#
        )
        let duplicateTopLevelKey = validSuccess.replacingOccurrences(
            of: #""ok":true"#,
            with: #""ok":true,"ok":true"#
        )
        let unknownResultKey = validSuccess.replacingOccurrences(
            of: #""armed":true"#,
            with: #""armed":true,"unexpected":true"#
        )
        let duplicateErrorKey = validError.replacingOccurrences(
            of: #""code":"team_required""#,
            with: #""code":"team_required","code":"team_required""#
        )
        let unknownDataKey = validError.replacingOccurrences(
            of: #""serverProof":"\#(proof)""#,
            with: #""serverProof":"\#(proof)","unexpected":true"#
        )

        #expect(!CMUXCLI.coderouterHandoffResponseRawShapeIsValid(numericOK))
        #expect(!CMUXCLI.coderouterHandoffResponseRawShapeIsValid(numericArmed))
        #expect(!CMUXCLI.coderouterHandoffResponseRawShapeIsValid(floatVersion))
        #expect(!CMUXCLI.coderouterHandoffResponseRawShapeIsValid(exponentVersion))
        #expect(!CMUXCLI.coderouterHandoffResponseRawShapeIsValid(duplicateTopLevelKey))
        #expect(!CMUXCLI.coderouterHandoffResponseRawShapeIsValid(duplicateResultKey))
        #expect(!CMUXCLI.coderouterHandoffResponseRawShapeIsValid(escapedDuplicateResultKey))
        #expect(!CMUXCLI.coderouterHandoffResponseRawShapeIsValid(unknownResultKey))
        #expect(!CMUXCLI.coderouterHandoffResponseRawShapeIsValid(duplicateErrorKey))
        #expect(!CMUXCLI.coderouterHandoffResponseRawShapeIsValid(unknownDataKey))
    }

    @Test("accepts a valid HMAC response followed by EOF and builds exact argv")
    func armsOnceAndBuildsExactHiddenArgv() throws {
        let handoffServer = try CLICoderouterMockHandoffServer(name: "argv")
        defer { handoffServer.stop() }
        let cli = CMUXCLI(
            args: ["cmux"],
            coderouterArmServerPeerVerifier: mockServerPeerVerifier()
        )
        let handoff = try cli.armCoderouterHandoff(
            explicitSocketPath: handoffServer.path,
            explicitPassword: nil,
            environment: handoffServer.capabilityEnvironment,
            bundleIdentifier: "com.cmuxterm.app"
        )
        let routedArguments = CMUXCLI.coderouterLaunchArguments(
            commandArgs: [
                "codex",
                "--provider",
                "codex go",
                "--",
                "echo; touch should-not-run",
                "--help",
            ],
            handoff: handoff
        )

        #expect(handoffServer.waitForRequest(), "The routed alias must arm through the socket")
        let socketCommands = handoffServer.commandSnapshot()
        #expect(socketCommands.count == 1)
        #expect(socketCommands.contains { $0.contains(#""id":"coderouter-handoff-arm""#) })
        #expect(socketCommands.contains { $0.contains(#""method":"coderouter.handoff.arm""#) })
        #expect(socketCommands.contains { $0.contains(#""protocolVersion":2"#) })
        #expect(!socketCommands.contains { $0.contains(#""method":"coderouter.handoff""#) })
        #expect(
            routedArguments == [
                "__cmux-handoff-v2",
                handoffServer.path,
                handoffServer.teamBinding,
                "--",
                "codex",
                "--provider",
                "codex go",
                "--",
                "echo; touch should-not-run",
                "--help",
            ]
        )
    }

    @Test("production peer verification rejects an unsigned server before write")
    func productionPeerVerificationRejectsUnsignedServerBeforeWrite() throws {
        let handoffServer = try CLICoderouterMockHandoffServer(name: "peer-auth")
        defer { handoffServer.stop() }
        let cli = CMUXCLI(args: ["cmux"])

        #expect(throws: CLIError.self) {
            try cli.armCoderouterHandoff(
                explicitSocketPath: handoffServer.path,
                explicitPassword: "must-not-leak-password",
                environment: handoffServer.capabilityEnvironment,
                bundleIdentifier: "com.cmuxterm.app"
            )
        }
        #expect(handoffServer.waitForRequest())
        #expect(handoffServer.commandSnapshot().isEmpty, "Peer verification must finish before any write")
    }

    @Test("arm proves the terminal capability without sending it")
    func armProvesCapabilityWithoutSendingIt() throws {
        let handoffServer = try CLICoderouterMockHandoffServer(name: "cap-arm")
        defer { handoffServer.stop() }
        let cli = CMUXCLI(
            args: ["cmux"],
            coderouterArmServerPeerVerifier: mockServerPeerVerifier()
        )

        _ = try cli.armCoderouterHandoff(
            explicitSocketPath: handoffServer.path,
            explicitPassword: "password-sentinel-must-not-cross-socket",
            environment: handoffServer.capabilityEnvironment,
            bundleIdentifier: "com.cmuxterm.app"
        )

        #expect(handoffServer.waitForRequest())
        let commands = handoffServer.commandSnapshot()
        #expect(commands.count == 1)
        #expect(!commands[0].contains(handoffServer.capability))
        let capabilityParts = handoffServer.capability.split(separator: ".")
        #expect(capabilityParts.count == 3)
        #expect(!commands[0].contains(String(capabilityParts[2])))
        #expect(!commands[0].contains("password-sentinel-must-not-cross-socket"))
        #expect(!commands[0].contains("auth "))
        #expect(!commands[0].hasPrefix("_cmux_capability_v1 "))
        #expect(commands[0].contains(#""id":"coderouter-handoff-arm""#))
        #expect(commands[0].contains(#""capabilityNonce""#))
        #expect(commands[0].contains(#""clientChallenge""#))
        #expect(commands[0].contains(#""clientProof""#))
        let requestData = try #require(commands[0].data(using: .utf8))
        let request = try #require(
            JSONSerialization.jsonObject(with: requestData) as? [String: Any]
        )
        #expect(Set(request.keys) == ["id", "method", "params"])
        let params = try #require(request["params"] as? [String: Any])
        #expect(Set(params.keys) == [
            "protocolVersion",
            "capabilityNonce",
            "clientChallenge",
            "clientProcessID",
            "clientProcessStartAbsoluteTime",
            "clientProof",
        ])
    }

    @Test("each arm request uses a fresh challenge")
    func armChallengeIsFresh() throws {
        let handoffServer = try CLICoderouterMockHandoffServer(
            name: "challenge"
        )
        defer { handoffServer.stop() }
        let cli = CMUXCLI(
            args: ["cmux"],
            coderouterArmServerPeerVerifier: mockServerPeerVerifier()
        )

        for _ in 0..<2 {
            _ = try cli.armCoderouterHandoff(
                explicitSocketPath: handoffServer.path,
                explicitPassword: nil,
                environment: handoffServer.capabilityEnvironment,
                bundleIdentifier: "com.cmuxterm.app"
            )
            #expect(handoffServer.waitForRequest())
        }
        let challenges = try handoffServer.commandSnapshot().map { command in
            let data = try #require(command.data(using: .utf8))
            let request = try #require(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            let params = try #require(request["params"] as? [String: Any])
            return try #require(params["clientChallenge"] as? String)
        }
        #expect(challenges.count == 2)
        #expect(challenges[0] != challenges[1])
    }

    @Test("missing capability does not connect or use a password fallback")
    func missingCapabilityFailsBeforeConnect() throws {
        let handoffServer = try CLICoderouterMockHandoffServer(
            name: "no-capability"
        )
        defer { handoffServer.stop() }
        let cli = CMUXCLI(
            args: ["cmux"],
            coderouterArmServerPeerVerifier: mockServerPeerVerifier()
        )

        #expect(throws: CLIError.self) {
            try cli.armCoderouterHandoff(
                explicitSocketPath: handoffServer.path,
                explicitPassword: "password-must-not-be-a-fallback",
                environment: [:],
                bundleIdentifier: "com.cmuxterm.app"
            )
        }
        #expect(!handoffServer.waitForRequest(timeout: 0.2))
        #expect(handoffServer.commandSnapshot().isEmpty)
    }

    @Test("arm rejects a mismatched response id")
    func armRejectsMismatchedResponseID() throws {
        let handoffServer = try CLICoderouterMockHandoffServer(
            name: "wrong-id",
            responseID: "different-request"
        )
        defer { handoffServer.stop() }
        let cli = CMUXCLI(
            args: ["cmux"],
            coderouterArmServerPeerVerifier: mockServerPeerVerifier()
        )

        #expect(throws: CLIError.self) {
            try cli.armCoderouterHandoff(
                explicitSocketPath: handoffServer.path,
                explicitPassword: nil,
                environment: handoffServer.capabilityEnvironment,
                bundleIdentifier: "com.cmuxterm.app"
            )
        }
        #expect(handoffServer.waitForRequest())
        #expect(handoffServer.commandSnapshot().count == 1)
    }

    @Test("generated v2 request ids must match the response")
    func generatedV2RequestIDMustMatchResponse() throws {
        let server = try CLICoderouterMockHandoffServer(
            name: "generated-id",
            responseID: "not-the-generated-id"
        )
        defer { server.stop() }
        let client = SocketClient(path: server.path)
        try client.connect()
        defer { client.close() }

        #expect(throws: CLIError.self) {
            try client.sendV2(method: "test.generated-id")
        }
        #expect(server.waitForRequest())
        #expect(server.commandSnapshot().count == 1)
    }

    @Test("the short alias still prefers coderouter when both names exist")
    func crAliasPrefersCoderouter() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cr-preference-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            printf 'canonical coderouter\\n'
            exit 41
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )
        try writeExecutable(
            """
            #!/bin/sh
            printf 'the cr executable was selected\\n' >&2
            exit 99
            """,
            at: root.appendingPathComponent("cr", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["cr", "--version"],
            environment: [
                "PATH": root.path,
                "CMUX_SOCKET_PATH": makeSocketPath("missing"),
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 41, Comment(rawValue: result.stderr))
        #expect(result.stdout == "canonical coderouter\n")
        #expect(result.stderr.isEmpty)
    }

    @Test("alias exec preserves standard input, output, error, and exit status")
    func aliasExecPreservesStdioAndExitStatus() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-stdio-\(UUID().uuidString)", isDirectory: true)
        let stdinURL = root.appendingPathComponent("stdin.txt", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            /bin/cat > "$CODEROUTER_STDIN_FILE"
            printf 'coderouter stdout\\n'
            printf 'coderouter stderr\\n' >&2
            exit 37
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "--version"],
            environment: [
                "PATH": root.path,
                "CODEROUTER_STDIN_FILE": stdinURL.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            standardInput: "interactive input\n"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 37, Comment(rawValue: result.stderr))
        #expect(result.stdout == "coderouter stdout\n")
        #expect(result.stderr == "coderouter stderr\n")
        #expect(try String(contentsOf: stdinURL, encoding: .utf8) == "interactive input\n")
    }

    @Test("an npm launcher resolves to the native vendor executable")
    func npmLauncherUsesNativeVendorExecutable() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-npm-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        #if arch(arm64)
        let npmTarget = "darwin-arm64"
        #elseif arch(x86_64)
        let npmTarget = "darwin-x64"
        #else
        return
        #endif

        let packageRoot = root.appendingPathComponent("package", isDirectory: true)
        let binDirectory = packageRoot.appendingPathComponent("bin", isDirectory: true)
        let vendorDirectory = packageRoot
            .appendingPathComponent("vendor", isDirectory: true)
            .appendingPathComponent(npmTarget, isDirectory: true)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: vendorDirectory, withIntermediateDirectories: true)
        let launcherURL = binDirectory.appendingPathComponent("coderouter.js", isDirectory: false)
        try writeExecutable(
            """
            #!/bin/sh
            printf 'javascript-launcher-ran\\n'
            exit 98
            """,
            at: launcherURL
        )
        try writeExecutable(
            """
            #!/bin/sh
            if [ "${1-}" = "capabilities" ] && [ "${2-}" = "--json" ]; then
              printf '%s\\n' '{"product":"coderouter","protocolVersion":2,"authModes":["cmux-socket-v1"]}'
              exit 0
            fi
            printf 'native-vendor:%s\\n' "$*"
            """,
            at: vendorDirectory.appendingPathComponent("coderouter", isDirectory: false)
        )
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("coderouter", isDirectory: false),
            withDestinationURL: launcherURL
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "--version"],
            environment: [
                "PATH": root.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "native-vendor:--version\n")
        #expect(!result.stdout.contains("javascript-launcher-ran"))
        #expect(result.stderr.isEmpty)
    }

    @Test("alias exec keeps normal termination signal behavior")
    func aliasExecKeepsNormalTerminationSignalBehavior() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-signal-\(UUID().uuidString)", isDirectory: true)
        let signalURL = root.appendingPathComponent("signal.txt", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            if [ "${1-}" = "capabilities" ] && [ "${2-}" = "--json" ]; then
              printf '%s\\n' '{"product":"coderouter","protocolVersion":2,"authModes":["cmux-socket-v1"]}'
              exit 0
            fi
            trap 'printf received > "$CODEROUTER_SIGNAL_FILE"; exit 42' TERM
            kill -TERM "$$"
            /bin/sleep 1
            exit 90
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "--version"],
            environment: [
                "PATH": root.path,
                "CODEROUTER_SIGNAL_FILE": signalURL.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 42, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: signalURL, encoding: .utf8) == "received")
    }

    @Test("capabilities stays credential-free when cmux is absent")
    func capabilitiesDoesNotTouchControlSocket() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-capabilities-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            printf 'capabilities-ok\\n'
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "capabilities", "--json"],
            environment: [
                "PATH": root.path,
                "CMUX_SOCKET_PATH": makeSocketPath("missing"),
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "capabilities-ok\n")
        #expect(result.stderr.isEmpty)
    }

    @Test("closes a high inherited descriptor after the soft limit is reduced")
    func closesHighInheritedDescriptorBeyondCurrentLimit() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-fd-boundary-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let sourceFD = Darwin.open("/dev/null", O_RDONLY)
        #expect(sourceFD >= 0)
        guard sourceFD >= 0 else { return }
        defer { Darwin.close(sourceFD) }
        let sentinelFD = fcntl(sourceFD, F_DUPFD, 1_024)
        #expect(sentinelFD >= 1_024)
        guard sentinelFD >= 1_024 else { return }
        defer { Darwin.close(sentinelFD) }
        let descriptorFlags = fcntl(sentinelFD, F_GETFD)
        #expect(descriptorFlags >= 0)
        _ = fcntl(sentinelFD, F_SETFD, descriptorFlags & ~FD_CLOEXEC)

        try writeExecutable(
            """
            #!/bin/sh
            if [ -e "/dev/fd/$CODEROUTER_SENTINEL_FD" ]; then
              printf 'sentinel-open\\n'
            else
              printf 'sentinel-closed\\n'
            fi
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )
        let wrapperURL = root.appendingPathComponent("cmux-low-limit", isDirectory: false)
        try writeExecutable(
            """
            #!/bin/sh
            ulimit -n 256
            exec "$CMUX_UNDER_TEST" "$@"
            """,
            at: wrapperURL
        )

        let result = runCLI(
            cliPath: wrapperURL.path,
            arguments: ["coderouter", "--version"],
            environment: [
                "PATH": root.path,
                "CMUX_UNDER_TEST": cliPath,
                "CODEROUTER_SENTINEL_FD": String(sentinelFD),
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "sentinel-closed\n")
        #expect(result.stderr.isEmpty)
    }

    @Test("does not pass inherited descriptor three to CodeRouter")
    func closesInheritedDescriptorThree() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-fd3-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            if (: <&3) 2>/dev/null; then
              printf 'fd3-open\\n'
              exit 92
            fi
            printf 'fd3-closed\\n'
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )
        let wrapperURL = root.appendingPathComponent("cmux-open-fd3", isDirectory: false)
        try writeExecutable(
            """
            #!/bin/sh
            exec 3</dev/null
            exec "$CMUX_UNDER_TEST" "$@"
            """,
            at: wrapperURL
        )

        let result = runCLI(
            cliPath: wrapperURL.path,
            arguments: ["coderouter", "--version"],
            environment: [
                "PATH": root.path,
                "CMUX_UNDER_TEST": cliPath,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "fd3-closed\n")
        #expect(result.stderr.isEmpty)
    }

    @Test("a closed standard input stays closed without blocking alias exec")
    func closedStandardInputStaysClosed() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-closed-stdin-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            if (: <&0) 2>/dev/null; then
              printf 'stdin-open\\n'
              exit 91
            fi
            printf 'stdin-closed\\n'
            exit 31
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )
        let wrapperURL = root.appendingPathComponent("cmux-closed-stdin", isDirectory: false)
        try writeExecutable(
            """
            #!/bin/sh
            exec 0<&-
            exec "$CMUX_UNDER_TEST" "$@"
            """,
            at: wrapperURL
        )

        let result = runCLI(
            cliPath: wrapperURL.path,
            arguments: ["coderouter", "--version"],
            environment: [
                "PATH": root.path,
                "CMUX_UNDER_TEST": cliPath,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 31, Comment(rawValue: result.stderr))
        #expect(result.stdout == "stdin-closed\n")
        #expect(result.stderr.isEmpty)
    }

    @Test("management commands use cr without requesting a handoff")
    func crFallbackManagementCommandDoesNotRequestHandoff() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let handoffServer = try CLICoderouterMockHandoffServer(name: "fallback")
        defer { handoffServer.stop() }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-cr-alias-\(UUID().uuidString)", isDirectory: true)
        let argsURL = root.appendingPathComponent("args.txt", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            printf '<%s>\\n' "$@" > "$CR_ARGS_FILE"
            printf 'cr fallback\\n'
            exit 23
            """,
            at: root.appendingPathComponent("cr", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["cr", "login", "--device-auth"],
            environment: [
                "PATH": root.path,
                "CR_ARGS_FILE": argsURL.path,
                "CMUX_SOCKET_PATH": handoffServer.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!handoffServer.waitForRequest(timeout: 0.2), "Management commands must not arm")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 23, Comment(rawValue: result.stderr))
        #expect(result.stdout == "cr fallback\n")
        #expect(result.stderr.isEmpty)
        #expect(
            try String(contentsOf: argsURL, encoding: .utf8)
                == "<login>\n<--device-auth>\n"
        )
    }

    @Test("only exact top-level agent names use socket handoff")
    func routedCommandClassificationIsExact() throws {
        #expect(CMUXCLI.coderouterCommandRequiresHandoff(["codex"]))
        #expect(CMUXCLI.coderouterCommandRequiresHandoff(["opencode", "--help"]))
        #expect(CMUXCLI.coderouterCommandRequiresHandoff(["pi", "arg"]))
        #expect(!CMUXCLI.coderouterCommandRequiresHandoff([]))
        #expect(!CMUXCLI.coderouterCommandRequiresHandoff(["login"]))
        #expect(!CMUXCLI.coderouterCommandRequiresHandoff(["capabilities", "--json"]))
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let handoffServer = try CLICoderouterMockHandoffServer(name: "classification")
        defer { handoffServer.stop() }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-classification-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            printf '<%s>\\n' "$@"
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )

        let cases: [[String]] = [
            ["codex-helper"],
            ["Codex"],
            ["--", "codex"],
        ]
        for commandArguments in cases {
            let result = runCLI(
                cliPath: cliPath,
                arguments: ["coderouter"] + commandArguments,
                environment: [
                    "PATH": root.path,
                    "CMUX_SOCKET_PATH": handoffServer.path,
                    "CMUX_CLI_SENTRY_DISABLED": "1",
                ]
            )
            #expect(!result.timedOut, Comment(rawValue: result.stderr))
            #expect(result.status == 0, Comment(rawValue: result.stderr))
            #expect(
                result.stdout
                    == commandArguments.map { "<\($0)>\n" }.joined(),
                Comment(rawValue: result.stdout)
            )
        }
        #expect(!handoffServer.waitForRequest(timeout: 0.2), "Near matches must not arm")
    }

    @Test("reports a signed-out arm failure only after proof verification")
    func reportsSignedOutArmFailureSafely() throws {
        let error = try injectedArmError(errorCode: "not_authenticated", name: "signed-out")
        #expect(error.message.contains("requires a signed-in cmux account"))
        #expect(error.message.contains("cmux auth login"))
        #expect(!error.message.contains("raw-arm-secret"))
    }

    @Test("reports missing-team arm failure without raw server details")
    func reportsMissingTeamArmFailureSafely() throws {
        let error = try injectedArmError(errorCode: "team_required", name: "team-required")
        #expect(error.message.contains("requires a selected cmux team"))
        #expect(error.message.contains("Select a team in cmux"))
        #expect(!error.message.contains("raw-arm-secret"))
    }

    @Test("does not map unsigned or tampered arm errors")
    func unsignedOrTamperedArmErrorsAreGeneric() throws {
        let unsignedError = try injectedArmError(
            errorCode: "team_required",
            name: "unsigned-team",
            responseMutation: .unsignedError
        )
        #expect(unsignedError.message.contains("Could not prepare the CodeRouter handoff"))
        #expect(!unsignedError.message.contains("selected cmux team"))

        let tamperedError = try injectedArmError(
            errorCode: "team_required",
            name: "tamper-team",
            responseMutation: .tamperProof
        )
        #expect(tamperedError.message.contains("Could not prepare the CodeRouter handoff"))
        #expect(!tamperedError.message.contains("selected cmux team"))
    }

    @Test("rejects extra arm response fields")
    func rejectsExtraArmResponseFields() throws {
        let successEnvelope = try CLICoderouterMockHandoffServer(
            name: "extra-success-envelope",
            responseMutation: .addEnvelopeKey
        )
        defer { successEnvelope.stop() }
        let cli = CMUXCLI(
            args: ["cmux"],
            coderouterArmServerPeerVerifier: mockServerPeerVerifier()
        )
        #expect(throws: CLIError.self) {
            try cli.armCoderouterHandoff(
                explicitSocketPath: successEnvelope.path,
                explicitPassword: nil,
                environment: successEnvelope.capabilityEnvironment,
                bundleIdentifier: "com.cmuxterm.app"
            )
        }

        let successResult = try CLICoderouterMockHandoffServer(
            name: "extra-success-result",
            responseMutation: .addPayloadKey
        )
        defer { successResult.stop() }
        #expect(throws: CLIError.self) {
            try cli.armCoderouterHandoff(
                explicitSocketPath: successResult.path,
                explicitPassword: nil,
                environment: successResult.capabilityEnvironment,
                bundleIdentifier: "com.cmuxterm.app"
            )
        }

        let errorPayload = try injectedArmError(
            errorCode: "team_required",
            name: "extra-error",
            responseMutation: .addPayloadKey
        )
        #expect(errorPayload.message.contains("Could not prepare the CodeRouter handoff"))
        #expect(!errorPayload.message.contains("selected cmux team"))
    }

    @Test("rejects a tampered success proof")
    func rejectsTamperedSuccessProof() throws {
        let handoffServer = try CLICoderouterMockHandoffServer(
            name: "bad-proof",
            responseMutation: .tamperProof
        )
        defer { handoffServer.stop() }
        let cli = CMUXCLI(
            args: ["cmux"],
            coderouterArmServerPeerVerifier: mockServerPeerVerifier()
        )
        #expect(throws: CLIError.self) {
            try cli.armCoderouterHandoff(
                explicitSocketPath: handoffServer.path,
                explicitPassword: nil,
                environment: handoffServer.capabilityEnvironment,
                bundleIdentifier: "com.cmuxterm.app"
            )
        }
    }

    @Test("requires one closed 4096-byte arm response frame")
    func rejectsInvalidArmResponseFraming() throws {
        let cases: [(String, CLICoderouterMockResponseMutation)] = [
            ("no-newline", .missingNewline),
            ("over-limit", .oversizedFrame),
            ("second-frame", .secondFrame),
            ("trailing-space", .trailingWhitespace),
        ]
        let cli = CMUXCLI(
            args: ["cmux"],
            coderouterArmServerPeerVerifier: mockServerPeerVerifier()
        )

        for (name, mutation) in cases {
            let handoffServer = try CLICoderouterMockHandoffServer(
                name: name,
                responseMutation: mutation
            )
            #expect(throws: CLIError.self) {
                try cli.armCoderouterHandoff(
                    explicitSocketPath: handoffServer.path,
                    explicitPassword: nil,
                    environment: handoffServer.capabilityEnvironment,
                    bundleIdentifier: "com.cmuxterm.app"
                )
            }
            #expect(handoffServer.waitForRequest())
            #expect(handoffServer.commandSnapshot().count == 1)
            handoffServer.stop()
        }
    }

    @Test("rejects an oversized arm request before write")
    func rejectsOversizedArmRequestBeforeWrite() throws {
        let handoffServer = try CLICoderouterMockHandoffServer(
            name: "large-request"
        )
        defer { handoffServer.stop() }
        let client = SocketClient(path: handoffServer.path)
        try client.connect()

        #expect(throws: CLIError.self) {
            try client.sendV2Envelope(
                method: SocketClientCapabilityProof.method,
                params: ["padding": String(repeating: "x", count: 4_096)],
                requestID: SocketClientCapabilityProof.requestID,
                includeCapability: false,
                strictFrameMaximumRawBytes: 4_096
            )
        }
        client.close()
        #expect(handoffServer.waitForRequest())
        #expect(handoffServer.commandSnapshot().isEmpty)
    }

    @Test("rejects a non-canonical team binding before exec")
    func rejectsInvalidTeamBindingBeforeExec() throws {
        let handoffServer = try CLICoderouterMockHandoffServer(
            name: "binding",
            teamBinding: String(repeating: "A", count: 64)
        )
        defer { handoffServer.stop() }
        let cli = CMUXCLI(
            args: ["cmux"],
            coderouterArmServerPeerVerifier: mockServerPeerVerifier()
        )

        #expect(throws: CLIError.self) {
            try cli.armCoderouterHandoff(
                explicitSocketPath: handoffServer.path,
                explicitPassword: nil,
                environment: handoffServer.capabilityEnvironment,
                bundleIdentifier: "com.cmuxterm.app"
            )
        }
        #expect(handoffServer.waitForRequest(), "The client must receive the arm result")
        #expect(handoffServer.commandSnapshot().count == 1)
    }

    @Test("rejects an executable without secure handoff support before arm")
    func rejectsUnsupportedExecutableBeforeArm() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let handoffServer = try CLICoderouterMockHandoffServer(name: "old-cli")
        defer { handoffServer.stop() }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-old-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            if [ "${1-}" = "capabilities" ]; then
              printf '{"product":"coderouter","protocolVersion":%s,"authModes":[]}\\n' "${CODEROUTER_PROTOCOL_VALUE-0}"
              exit 0
            fi
            printf 'must-not-run\\n'
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "codex"],
            environment: [
                "PATH": root.path,
                "CMUX_SOCKET_PATH": handoffServer.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!handoffServer.waitForRequest(timeout: 0.2), "An unsupported CLI must not arm")
        #expect(!result.timedOut)
        #expect(result.status != 0)
        #expect(!result.stdout.contains("must-not-run"))
        #expect(!result.stderr.contains(root.path))
        #expect(result.stderr.contains("does not support secure cmux handoff"))

        let booleanResult = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "codex"],
            environment: [
                "PATH": root.path,
                "CODEROUTER_PROTOCOL_VALUE": "true",
                "CMUX_SOCKET_PATH": handoffServer.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )
        #expect(booleanResult.status != 0)
        #expect(!booleanResult.stdout.contains("must-not-run"))
        #expect(
            !handoffServer.waitForRequest(timeout: 0.2),
            "Boolean protocol versions must not arm"
        )
    }

    @Test("rejects an unrelated cr executable before arm")
    func rejectsUnrelatedFallbackBeforeArm() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let handoffServer = try CLICoderouterMockHandoffServer(name: "wrong-cr")
        defer { handoffServer.stop() }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-unrelated-cr-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            if [ "${1-}" = "capabilities" ]; then
              printf '%s\\n' '{"product":"unrelated","protocolVersion":2,"authModes":["cmux-socket-v1"]}'
              exit 0
            fi
            printf 'must-not-run\\n'
            """,
            at: root.appendingPathComponent("cr", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["cr", "pi"],
            environment: [
                "PATH": root.path,
                "CMUX_SOCKET_PATH": handoffServer.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!handoffServer.waitForRequest(timeout: 0.2), "An unrelated cr must not arm")
        #expect(!result.timedOut)
        #expect(result.status != 0)
        #expect(!result.stdout.contains("must-not-run"))
    }

    @Test("rejects an unsigned executable before capability execution or arm")
    func rejectsUnsignedExecutableBeforeArm() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let handoffServer = try CLICoderouterMockHandoffServer(name: "unsigned")
        defer { handoffServer.stop() }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-unsigned-coderouter-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            if [ "${1-}" = "capabilities" ]; then
              printf '%s\\n' '{"product":"coderouter","protocolVersion":2,"authModes":["cmux-socket-v1"]}'
              exit 0
            fi
            printf 'must-not-run\\n'
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "codex"],
            environment: [
                "PATH": root.path,
                "CMUX_SOCKET_PATH": handoffServer.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            allowUnsignedCoderouter: false
        )

        #expect(!handoffServer.waitForRequest(timeout: 0.2), "Unsigned code must not arm")
        #expect(!result.timedOut)
        #expect(result.status != 0)
        #expect(!result.stdout.contains("must-not-run"))
        #expect(result.stderr.contains("does not support secure cmux handoff"))
    }

    @Test("bounds capability probe time and output before arm")
    func boundsCapabilityProbeBeforeArm() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let handoffServer = try CLICoderouterMockHandoffServer(name: "probe-bound")
        defer { handoffServer.stop() }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-probe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            if [ "${1-}" = "capabilities" ]; then
              if [ "${CODEROUTER_CAPABILITY_TEST_MODE-}" = "slow" ]; then
                /bin/sleep 10
              else
                /usr/bin/yes x | /usr/bin/head -c 20000
              fi
              exit 0
            fi
            printf 'must-not-run\\n'
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )

        let started = Date()
        let slowResult = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "codex"],
            environment: [
                "PATH": root.path,
                "CODEROUTER_CAPABILITY_TEST_MODE": "slow",
                "CMUX_SOCKET_PATH": handoffServer.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )
        #expect(Date().timeIntervalSince(started) < 4)
        #expect(!slowResult.timedOut)
        #expect(slowResult.status != 0)

        let oversizedResult = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "codex"],
            environment: [
                "PATH": root.path,
                "CODEROUTER_CAPABILITY_TEST_MODE": "oversized",
                "CMUX_SOCKET_PATH": handoffServer.path,
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )
        #expect(!oversizedResult.timedOut)
        #expect(oversizedResult.status != 0)
        #expect(!handoffServer.waitForRequest(timeout: 0.2), "Invalid probes must not arm")
    }

    @Test("localizes the alias help entry")
    func aliasHelpUsesRequestedLocalization() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let result = runCLI(
            cliPath: cliPath,
            arguments: ["--help"],
            environment: [
                "AppleLanguages": "(ja)",
                "AppleLocale": "ja_JP",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(
            result.stdout.contains("インストール済み CodeRouter CLI のエイリアス"),
            Comment(rawValue: result.stdout)
        )
        #expect(
            !result.stdout.contains("aliases for the installed CodeRouter CLI"),
            Comment(rawValue: result.stdout)
        )
    }

    @Test("does not leak cmux control environment to the child")
    func childEnvironmentExcludesCmuxControlValues() throws {
        let routedEnvironment = CMUXCLI.coderouterChildEnvironment(
            [
                "PATH": "/usr/bin",
                "CODEROUTER_API_URL": "https://must-not-cross.example",
                "CODEROUTER_DATA_DIR": "/tmp/must-not-cross",
                "CODEROUTER_HANDOFF_FD": "3",
                "CODEROUTER_CMUX_HANDOFF_SOCKET": "/tmp/stale.sock",
                "AWS_REGION": "us-west-2",
                "AWS_PROFILE": "dev-profile",
                "GOOGLE_CLOUD_PROJECT": "project-config",
                "SSH_AUTH_SOCK": "/tmp/ssh-agent.sock",
                "HTTP_PROXY": "http://proxy-secret.example",
                "HTTPS_PROXY": "https://proxy-secret.example",
                "https_proxy": "https://lowercase-proxy-secret.example",
                "ALL_PROXY": "socks5://proxy-secret.example",
                "NO_PROXY": "internal-secret.example",
                "SSL_CERT_FILE": "/tmp/custom-ca-secret.pem",
                "SSL_CERT_DIR": "/tmp/custom-ca-secret-dir",
                "SSLKEYLOGFILE": "/tmp/ssl-key-log-secret",
                "CURL_CA_BUNDLE": "/tmp/curl-ca-secret.pem",
                "REQUESTS_CA_BUNDLE": "/tmp/requests-ca-secret.pem",
            ],
            forHandoff: true
        )
        #expect(routedEnvironment["PATH"] == "/usr/bin")
        #expect(routedEnvironment["CODEROUTER_API_URL"] == nil)
        #expect(routedEnvironment["CODEROUTER_DATA_DIR"] == nil)
        #expect(routedEnvironment["CODEROUTER_HANDOFF_FD"] == nil)
        #expect(routedEnvironment["CODEROUTER_CMUX_HANDOFF_SOCKET"] == nil)
        #expect(routedEnvironment["AWS_REGION"] == "us-west-2")
        #expect(routedEnvironment["AWS_PROFILE"] == "dev-profile")
        #expect(routedEnvironment["GOOGLE_CLOUD_PROJECT"] == "project-config")
        #expect(routedEnvironment["SSH_AUTH_SOCK"] == "/tmp/ssh-agent.sock")
        #expect(routedEnvironment["HTTP_PROXY"] == nil)
        #expect(routedEnvironment["HTTPS_PROXY"] == nil)
        #expect(routedEnvironment["https_proxy"] == nil)
        #expect(routedEnvironment["ALL_PROXY"] == nil)
        #expect(routedEnvironment["NO_PROXY"] == nil)
        #expect(routedEnvironment["SSL_CERT_FILE"] == nil)
        #expect(routedEnvironment["SSL_CERT_DIR"] == nil)
        #expect(routedEnvironment["SSLKEYLOGFILE"] == nil)
        #expect(routedEnvironment["CURL_CA_BUNDLE"] == nil)
        #expect(routedEnvironment["REQUESTS_CA_BUNDLE"] == nil)
        let managementEnvironment = CMUXCLI.coderouterChildEnvironment(
            ["HTTPS_PROXY": "https://proxy-preserved.example"],
            forHandoff: false
        )
        #expect(
            managementEnvironment["HTTPS_PROXY"]
                == "https://proxy-preserved.example"
        )

        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-environment-\(UUID().uuidString)", isDirectory: true)
        let environmentURL = root.appendingPathComponent("environment.txt", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try writeExecutable(
            """
            #!/bin/sh
            /usr/bin/env | /usr/bin/sort > "$CODEROUTER_ENV_FILE"
            printf 'environment captured\\n'
            """,
            at: root.appendingPathComponent("coderouter", isDirectory: false)
        )

        let result = runCLI(
            cliPath: cliPath,
            // Use the credential-free top-level provider version form so this
            // environment-boundary test does not need a live cmux socket.
            arguments: ["coderouter", "--version"],
            environment: [
                "PATH": root.path,
                "CODEROUTER_ENV_FILE": environmentURL.path,
                "CODEROUTER_TEST_MARKER": "preserved",
                "CMUX": "cmux-root-secret",
                "CMUXD": "cmuxd-root-secret",
                "CMUX_SOCKET": "/tmp/cmux-private.sock",
                "CMUX_SOCKET_PATH": "/tmp/cmux-private-path.sock",
                "CMUX_SOCKET_CAPABILITY": "capability-secret",
                "CMUX_SOCKET_PASSWORD": "password-secret",
                "CMUX_AUTH_CREDENTIALS_FILE": "/tmp/cmux-credentials",
                "CMUX_WORKSPACE_ID": "workspace-secret",
                "CMUX_SURFACE_ID": "surface-secret",
                "CMUXD_UNIX_PATH": "/tmp/cmuxd-private.sock",
                "STACK_ACCESS_TOKEN": "stack-access-secret",
                "STACK_REFRESH_TOKEN": "stack-refresh-secret",
                "OPENAI_API_KEY": "openai-secret",
                "GITHUB_PAT": "github-pat-secret",
                "GITHUB_TOKEN": "github-token-secret",
                "CUSTOM_SECRET_TOKEN": "custom-secret-token",
                "CODEROUTER_CMUX_HANDOFF_SOCKET": "/tmp/stale-handoff.sock",
                "CODEROUTER_HANDOFF_FD": "3",
                "CODEROUTER_HANDOFF_LEASE": "stale-handoff-lease",
                "CODEROUTER_HANDOFF_TEST_ORIGIN": "http://127.0.0.1:43123",
                "DYLD_LIBRARY_PATH": "/tmp/dyld-secret",
                "NPM_CONFIG__AUTH": "npm-auth-secret",
                "NPM_TOKEN": "npm-token-secret",
                "DOCKER_AUTH_CONFIG": "docker-auth-secret",
                "CI_JOB_JWT_V2": "ci-jwt-secret",
                "SSH_AUTH_SOCK": "/tmp/ssh-agent-preserved.sock",
                "AWS_REGION": "us-west-2",
                "AWS_PROFILE": "dev-profile",
                "AWS_ACCESS_KEY_ID": "aws-access-id-secret",
                "AWS_SECRET_ACCESS_KEY": "aws-secret-access-secret",
                "AWS_SESSION_TOKEN": "aws-session-token-secret",
                "AZURE_CONFIG_DIR": "/tmp/azure-config",
                "GCP_PROJECT": "gcp-project-config",
                "GOOGLE_CLOUD_PROJECT": "google-project-config",
                "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/google-secret.json",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stdout == "environment captured\n")
        #expect(result.stderr.isEmpty)
        let childEnvironment = try String(contentsOf: environmentURL, encoding: .utf8)
        let childEnvironmentLines = childEnvironment.split(separator: "\n").map(String.init)
        #expect(
            !childEnvironmentLines.contains { line in
                line.hasPrefix("CMUX_") || line.hasPrefix("CMUXD_")
            },
            Comment(rawValue: childEnvironment)
        )
        #expect(childEnvironmentLines.contains("CODEROUTER_TEST_MARKER=preserved"))
        #expect(!childEnvironment.contains("cmux-root-secret"))
        #expect(!childEnvironment.contains("cmuxd-root-secret"))
        #expect(!childEnvironment.contains("capability-secret"))
        #expect(!childEnvironment.contains("password-secret"))
        #expect(!childEnvironment.contains("workspace-secret"))
        #expect(!childEnvironment.contains("surface-secret"))
        #expect(!childEnvironment.contains("stack-access-secret"))
        #expect(!childEnvironment.contains("stack-refresh-secret"))
        #expect(!childEnvironment.contains("openai-secret"))
        #expect(!childEnvironment.contains("github-pat-secret"))
        #expect(!childEnvironment.contains("github-token-secret"))
        #expect(!childEnvironment.contains("custom-secret-token"))
        #expect(!childEnvironment.contains("stale-handoff.sock"))
        #expect(!childEnvironment.contains("stale-handoff-lease"))
        #expect(!childEnvironment.contains("127.0.0.1:43123"))
        #expect(!childEnvironment.contains("dyld-secret"))
        #expect(!childEnvironment.contains("npm-auth-secret"))
        #expect(!childEnvironment.contains("npm-token-secret"))
        #expect(!childEnvironment.contains("docker-auth-secret"))
        #expect(!childEnvironment.contains("ci-jwt-secret"))
        #expect(!childEnvironment.contains("aws-access-id-secret"))
        #expect(!childEnvironment.contains("aws-secret-access-secret"))
        #expect(!childEnvironment.contains("aws-session-token-secret"))
        #expect(!childEnvironment.contains("google-secret"))
        #expect(childEnvironmentLines.contains("SSH_AUTH_SOCK=/tmp/ssh-agent-preserved.sock"))
        #expect(childEnvironmentLines.contains("AWS_REGION=us-west-2"))
        #expect(childEnvironmentLines.contains("AWS_PROFILE=dev-profile"))
        #expect(childEnvironmentLines.contains("AZURE_CONFIG_DIR=/tmp/azure-config"))
        #expect(childEnvironmentLines.contains("GCP_PROJECT=gcp-project-config"))
        #expect(childEnvironmentLines.contains("GOOGLE_CLOUD_PROJECT=google-project-config"))
    }

    @Test("keeps launch diagnostics internal")
    func launchFailureDoesNotExposePathOrSystemError() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let handoffServer = try CLICoderouterMockHandoffServer(name: "failure")
        defer { handoffServer.stop() }
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-launch-failure-\(UUID().uuidString)", isDirectory: true)
        let executableURL = root.appendingPathComponent("coderouter", isDirectory: false)
        let debugLogURL = root.appendingPathComponent("debug.log", isDirectory: false)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        // An executable file without a recognized format makes execve fail after
        // PATH resolution, exercising the internal diagnostic path.
        try writeExecutable("not an executable format\n", at: executableURL)

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "launch"],
            environment: [
                "PATH": root.path,
                "CMUX_SOCKET_PATH": handoffServer.path,
                "CMUX_DEBUG_LOG": debugLogURL.path,
            ]
        )

        #expect(!handoffServer.waitForRequest(timeout: 0.2), "A management launch must not arm")
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 127, Comment(rawValue: result.stderr))
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("Could not start the required CLI"))
        #expect(!result.stderr.contains(root.path))
        #expect(!result.stderr.contains("Exec format error"))

#if DEBUG
        let debugLog = try String(contentsOf: debugLogURL, encoding: .utf8)
        #expect(debugLog.contains("cli.coderouter.exec_failed"))
        #expect(debugLog.contains(executableURL.path))
        #expect(debugLog.contains("errno="))
#endif
    }

    @Test("reports an actionable error when neither executable exists")
    func missingExecutableIsActionable() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: BundledCLILinkageTests.self
        )
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-coderouter-missing-\(UUID().uuidString)", isDirectory: true)
        let socketPath = makeSocketPath("missing")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let result = runCLI(
            cliPath: cliPath,
            arguments: ["coderouter", "login"],
            environment: [
                "PATH": root.path,
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_SOCKET_CAPABILITY": "missing-capability",
                "CMUX_SOCKET_PASSWORD": "missing-password",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ]
        )

        #expect(!result.timedOut)
        #expect(result.status == 127, Comment(rawValue: result.stderr))
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("Required CLI not found"))
        #expect(result.stderr.contains("Install the command"))
        #expect(!result.stderr.contains("CodeRouter"))
        #expect(!result.stderr.contains("coderouter"))
        #expect(!result.stderr.contains("PATH"))
        #expect(!result.stderr.contains(root.path))
        #expect(!result.stderr.contains(socketPath))
        #expect(!result.stderr.contains("missing-capability"))
        #expect(!result.stderr.contains("missing-password"))
    }

    private func runCLI(
        cliPath: String,
        arguments: [String],
        environment: [String: String],
        standardInput: String? = nil,
        allowUnsignedCoderouter: Bool = true
    ) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = arguments
        var childEnvironment = ProcessInfo.processInfo.environment
        for key in childEnvironment.keys where key.hasPrefix("CMUX_") || key.hasPrefix("CMUXD_") {
            childEnvironment.removeValue(forKey: key)
        }
        childEnvironment.merge(environment) { _, newValue in newValue }
        if allowUnsignedCoderouter {
            childEnvironment["CMUX_CODEROUTER_TEST_ALLOW_UNSIGNED"] = "1"
        }
        childEnvironment["AppleLanguages"] = childEnvironment["AppleLanguages"] ?? "(en)"
        childEnvironment["AppleLocale"] = childEnvironment["AppleLocale"] ?? "en_US"
        process.environment = childEnvironment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdinPipe: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            stdinPipe = nil
        }

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return ProcessResult(
                status: 127,
                stdout: "",
                stderr: error.localizedDescription,
                timedOut: false
            )
        }
        if let standardInput, let stdinPipe,
           let data = standardInput.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
            try? stdinPipe.fileHandleForWriting.close()
        }
        let timedOut: Bool
        switch finished.wait(timeout: .now() + 5) {
        case .success:
            timedOut = false
        case .timedOut:
            timedOut = true
            process.terminate()
            if finished.wait(timeout: .now() + 1) == .timedOut {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        return ProcessResult(
            status: timedOut ? 124 : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut
        )
    }

    private func injectedArmError(
        errorCode: String,
        name: String,
        responseMutation: CLICoderouterMockResponseMutation = .none
    ) throws -> CLIError {
        let handoffServer = try CLICoderouterMockHandoffServer(
            name: name,
            errorCode: errorCode,
            responseMutation: responseMutation
        )
        defer { handoffServer.stop() }
        let cli = CMUXCLI(
            args: ["cmux"],
            coderouterArmServerPeerVerifier: mockServerPeerVerifier()
        )
        do {
            _ = try cli.armCoderouterHandoff(
                explicitSocketPath: handoffServer.path,
                explicitPassword: nil,
                environment: handoffServer.capabilityEnvironment,
                bundleIdentifier: "com.cmuxterm.app"
            )
            Issue.record("Expected arm to fail")
            return CLIError(message: "arm unexpectedly succeeded")
        } catch let error as CLIError {
            #expect(handoffServer.waitForRequest(), "The client must receive the arm error")
            #expect(handoffServer.commandSnapshot().count == 1)
            return error
        }
    }

    private func mockServerPeerVerifier() -> CoderouterArmServerPeerVerifier {
        let identity = SocketClient.CoderouterArmServerIdentity(
            auditTokenBytes: [0],
            processID: 1
        )
        return CoderouterArmServerPeerVerifier(
            verifyBeforeRequest: { _ in identity },
            reverifyBeforeArmRequest: { _, expectedIdentity in
                expectedIdentity == identity
            }
        )
    }

    private func writeExecutable(_ contents: String, at url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return "/tmp/cli-\(name.prefix(3))-\(shortID).sock"
    }
}
