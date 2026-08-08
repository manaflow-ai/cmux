import Darwin
import Foundation

final class BrowserRecoveryHTTPServer {
    let port: UInt16
    let baseURL: URL

    private struct ExternalFixtureConfiguration {
        let baseURL: URL
        let strictCSPFixture: String
    }

    private let pythonArguments: [String]
    private let managesProcess: Bool
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private var outputBuffer = Data()
    private var process: Process?
    private var hasHeldRequest = false

    convenience init() throws {
        let port = try Self.availablePort()
        self.init(
            port: port,
            pythonArguments: ["-u", "-c", Self.recoveryServerScript, String(port)]
        )
    }

    convenience init(fixtureDirectory: URL, strictCSPFixture: String) throws {
        try Self.validateStrictCSPFixture(strictCSPFixture, in: fixtureDirectory)
        if let externalConfiguration = try Self.externalFixtureConfiguration(
            fixtureDirectory: fixtureDirectory
        ) {
            guard externalConfiguration.strictCSPFixture == strictCSPFixture else {
                throw ServerError.externalStrictCSPFixtureMismatch(
                    expected: strictCSPFixture,
                    actual: externalConfiguration.strictCSPFixture
                )
            }
            guard let externalPort = externalConfiguration.baseURL.port else {
                throw ServerError.invalidExternalFixtureBaseURL(
                    externalConfiguration.baseURL.absoluteString
                )
            }
            self.init(
                port: UInt16(externalPort),
                baseURL: externalConfiguration.baseURL,
                pythonArguments: [],
                managesProcess: false
            )
            return
        }

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureServerScript = repositoryRoot
            .appendingPathComponent("scripts/ci/serve-browser-fixtures.py")
        guard FileManager.default.isReadableFile(atPath: fixtureServerScript.path) else {
            throw ServerError.fixtureServerScriptMissing(fixtureServerScript.path)
        }
        let port = try Self.availablePort()
        self.init(port: port, pythonArguments: [
            "-u",
            fixtureServerScript.path,
            fixtureDirectory.path,
            "--strict-csp-fixture",
            strictCSPFixture,
            "--port",
            String(port),
        ])
    }

    private init(
        port: UInt16,
        baseURL: URL? = nil,
        pythonArguments: [String],
        managesProcess: Bool = true
    ) {
        self.port = port
        self.baseURL = baseURL ?? URL(string: "http://127.0.0.1:\(port)/")!
        self.pythonArguments = pythonArguments
        self.managesProcess = managesProcess
    }

    deinit {
        stop()
    }

    func start() throws {
        guard managesProcess else { return }
        guard process == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = pythonArguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        try process.run()
        self.process = process

        let readySignal = try nextSignal(timeoutMilliseconds: 5_000)
        guard readySignal == "READY" || readySignal == "READY \(port)" else {
            throw ServerError.unexpectedSignal
        }
    }

    func waitForRequest() throws {
        guard try nextSignal(timeoutMilliseconds: 15_000) == "REQUEST" else {
            throw ServerError.unexpectedSignal
        }
        hasHeldRequest = true
    }

    func releaseResponse() throws {
        guard hasHeldRequest else { return }
        hasHeldRequest = false
        try inputPipe.fileHandleForWriting.write(contentsOf: Data("RELEASE\n".utf8))
    }

    func stop() {
        guard managesProcess else { return }
        guard let process else { return }
        self.process = nil
        try? releaseResponse()
        if process.isRunning {
            process.terminate()
        }
    }

    private func nextSignal(timeoutMilliseconds: Int32) throws -> String {
        while true {
            if let newline = outputBuffer.firstIndex(of: 0x0A) {
                let line = outputBuffer[..<newline]
                outputBuffer.removeSubrange(...newline)
                return String(decoding: line, as: UTF8.self)
            }

            var readiness = pollfd(
                fd: outputPipe.fileHandleForReading.fileDescriptor,
                events: Int16(POLLIN),
                revents: 0
            )
            guard Darwin.poll(&readiness, 1, timeoutMilliseconds) > 0 else {
                throw ServerError.signalTimedOut
            }

            var bytes = [UInt8](repeating: 0, count: 128)
            let count = Darwin.read(readiness.fd, &bytes, bytes.count)
            guard count > 0 else {
                throw ServerError.signalStreamClosed
            }
            outputBuffer.append(contentsOf: bytes[..<count])
        }
    }

    private static func availablePort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServerError.couldNotReservePort }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let didBind = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard didBind == 0 else { throw ServerError.couldNotReservePort }

        var resolvedAddress = sockaddr_in()
        var resolvedLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let didResolve = withUnsafeMutablePointer(to: &resolvedAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                getsockname(descriptor, socketAddress, &resolvedLength)
            }
        }
        guard didResolve == 0 else { throw ServerError.couldNotReservePort }
        return UInt16(bigEndian: resolvedAddress.sin_port)
    }

    private static func validateStrictCSPFixture(_ fixtureName: String, in fixtureDirectory: URL) throws {
        guard !fixtureName.isEmpty,
              !fixtureName.contains("/"),
              !fixtureName.contains("\\") else {
            throw ServerError.invalidStrictCSPFixture(fixtureName)
        }
        let fixtureURL = fixtureDirectory.appendingPathComponent(fixtureName)
        guard FileManager.default.isReadableFile(atPath: fixtureURL.path) else {
            throw ServerError.strictCSPFixtureMissing(fixtureURL.path)
        }
    }

    private static func externalFixtureConfiguration(
        fixtureDirectory: URL
    ) throws -> ExternalFixtureConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let baseURLKey = "CMUX_UI_TEST_BROWSER_FIXTURE_BASE_URL"
        let strictFixtureKey = "CMUX_UI_TEST_BROWSER_STRICT_CSP_FIXTURE"
        if let rawBaseURL = environment[baseURLKey], !rawBaseURL.isEmpty {
            guard let strictFixture = environment[strictFixtureKey], !strictFixture.isEmpty else {
                throw ServerError.invalidExternalFixtureConfiguration(
                    "\(strictFixtureKey) is required when \(baseURLKey) is set"
                )
            }
            return ExternalFixtureConfiguration(
                baseURL: try validateExternalFixtureBaseURL(rawBaseURL),
                strictCSPFixture: strictFixture
            )
        }

        // xcodebuild does not pass arbitrary shell environment variables into
        // its hosted XCTest process. The external server writes its authoritative
        // URL and strict-CSP fixture beside the source fixtures instead.
        let markerURL = fixtureDirectory.appendingPathComponent(".cmux-ui-test-base-url")
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: markerURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawBaseURL = object["base_url"] as? String,
              let strictFixture = object["strict_csp_fixture"] as? String,
              !strictFixture.isEmpty else {
            throw ServerError.invalidExternalFixtureConfiguration(markerURL.path)
        }
        return ExternalFixtureConfiguration(
            baseURL: try validateExternalFixtureBaseURL(rawBaseURL),
            strictCSPFixture: strictFixture
        )
    }

    private static func validateExternalFixtureBaseURL(_ rawValue: String) throws -> URL {
        guard let url = URL(string: rawValue),
              url.scheme == "http",
              url.host == "127.0.0.1",
              let port = url.port,
              (1...Int(UInt16.max)).contains(port),
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.path == "/" else {
            throw ServerError.invalidExternalFixtureBaseURL(rawValue)
        }
        return url
    }

    private enum ServerError: Error {
        case couldNotReservePort
        case externalStrictCSPFixtureMismatch(expected: String, actual: String)
        case fixtureServerScriptMissing(String)
        case invalidExternalFixtureBaseURL(String)
        case invalidExternalFixtureConfiguration(String)
        case invalidStrictCSPFixture(String)
        case signalStreamClosed
        case signalTimedOut
        case strictCSPFixtureMissing(String)
        case unexpectedSignal
    }

    private static let recoveryServerScript = #"""
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        print('REQUEST', flush=True)
        if sys.stdin.readline().strip() != 'RELEASE':
            self.send_error(500)
            return
        body = b'<!doctype html><body data-cmux-recovered="true">recovered</body>'

        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass

server = HTTPServer(('127.0.0.1', port), Handler)
print('READY', flush=True)
server.serve_forever()
"""#
}
