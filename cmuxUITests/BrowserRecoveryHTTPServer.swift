import Darwin
import Foundation

final class BrowserRecoveryHTTPServer {
    let port: UInt16

    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private var outputBuffer = Data()
    private var process: Process?
    private var hasHeldRequest = false

    init() throws {
        self.port = try Self.availablePort()
    }

    deinit {
        stop()
    }

    func start() throws {
        guard process == nil else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-u",
            "-c",
            Self.serverScript,
            String(port),
        ]
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

    private enum ServerError: Error {
        case couldNotReservePort
        case signalStreamClosed
        case signalTimedOut
        case unexpectedSignal
    }

    private static let serverScript = #"""
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
