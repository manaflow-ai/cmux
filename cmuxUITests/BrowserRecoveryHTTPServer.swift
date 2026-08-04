import Darwin
import Foundation

final class BrowserRecoveryHTTPServer {
    let port: UInt16
    let baseURL: URL

    private let serverArguments: [String]
    private let managesProcess: Bool
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private var outputBuffer = Data()
    private var process: Process?
    private var hasHeldRequest = false

    convenience init() throws {
        let port = try Self.availablePort()
        self.init(port: port, serverArguments: ["recovery"])
    }

    convenience init(fixtureDirectory: URL, strictCSPFixture: String) throws {
        if let externalBaseURL = try Self.externalFixtureBaseURL(fixtureDirectory: fixtureDirectory) {
            guard let externalPort = externalBaseURL.port else {
                throw ServerError.invalidExternalFixtureBaseURL(externalBaseURL.absoluteString)
            }
            self.init(
                port: UInt16(externalPort),
                baseURL: externalBaseURL,
                serverArguments: [],
                managesProcess: false
            )
            return
        }

        let port = try Self.availablePort()
        self.init(port: port, serverArguments: [
            "fixtures",
            fixtureDirectory.path,
            strictCSPFixture,
        ])
    }

    private init(
        port: UInt16,
        baseURL: URL? = nil,
        serverArguments: [String],
        managesProcess: Bool = true
    ) {
        self.port = port
        self.baseURL = baseURL ?? URL(string: "http://127.0.0.1:\(port)/")!
        self.serverArguments = serverArguments
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
        process.arguments = [
            "-u",
            "-c",
            Self.serverScript,
            String(port),
        ] + serverArguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = Pipe()
        try process.run()
        self.process = process

        guard try nextSignal(timeoutMilliseconds: 5_000) == "READY" else {
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

    private static func externalFixtureBaseURL(fixtureDirectory: URL) throws -> URL? {
        let key = "CMUX_UI_TEST_BROWSER_FIXTURE_BASE_URL"
        if let rawValue = ProcessInfo.processInfo.environment[key], !rawValue.isEmpty {
            return try validateExternalFixtureBaseURL(rawValue)
        }

        // xcodebuild does not pass arbitrary shell environment variables into
        // its hosted XCTest process. CI writes the same URL beside the fixture
        // files, which are already readable through their #filePath directory.
        let markerURL = fixtureDirectory.appendingPathComponent(".cmux-ui-test-base-url")
        guard FileManager.default.fileExists(atPath: markerURL.path) else {
            return nil
        }
        let rawValue = try String(contentsOf: markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try validateExternalFixtureBaseURL(rawValue)
    }

    private static func validateExternalFixtureBaseURL(_ rawValue: String) throws -> URL {
        guard let url = URL(string: rawValue),
              url.scheme == "http",
              url.host == "127.0.0.1",
              let port = url.port,
              (1...Int(UInt16.max)).contains(port) else {
            throw ServerError.invalidExternalFixtureBaseURL(rawValue)
        }
        return url
    }

    private enum ServerError: Error {
        case couldNotReservePort
        case invalidExternalFixtureBaseURL(String)
        case signalStreamClosed
        case signalTimedOut
        case unexpectedSignal
    }

    private static let serverScript = #"""
import sys
from pathlib import Path
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import unquote, urlparse

port = int(sys.argv[1])
mode = sys.argv[2]
fixture_root = Path(sys.argv[3]).resolve() if mode == 'fixtures' else None
strict_csp_fixture = sys.argv[4] if mode == 'fixtures' else None

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if mode == 'recovery':
            print('REQUEST', flush=True)
            if sys.stdin.readline().strip() != 'RELEASE':
                self.send_error(500)
                return
            body = b'<!doctype html><body data-cmux-recovered="true">recovered</body>'
        else:
            fixture_name = unquote(urlparse(self.path).path).lstrip('/')
            if not fixture_name or '/' in fixture_name:
                self.send_error(404)
                return
            fixture_path = (fixture_root / fixture_name).resolve()
            if fixture_path.parent != fixture_root or not fixture_path.is_file():
                self.send_error(404)
                return
            body = fixture_path.read_bytes()

        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        if mode == 'fixtures' and fixture_name == strict_csp_fixture:
            self.send_header(
                'Content-Security-Policy',
                "default-src 'none'; script-src 'nonce-cmux-fixture'; object-src 'none'",
            )
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
