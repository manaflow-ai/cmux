import Darwin
import Foundation

final class BrowserRecoveryHTTPServer {
    let port: UInt16

    private let responseDelay: TimeInterval
    private var process: Process?

    init(responseDelay: TimeInterval) throws {
        self.port = try Self.availablePort()
        self.responseDelay = responseDelay
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
            String(responseDelay),
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        self.process = process

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if Self.canConnect(to: port) {
                return
            }
            if !process.isRunning {
                throw ServerError.exitedBeforeListening
            }
            usleep(20_000)
        }
        throw ServerError.didNotStartListening
    }

    func stop() {
        guard let process else { return }
        self.process = nil
        if process.isRunning {
            process.terminate()
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

    private static func canConnect(to port: UInt16) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private enum ServerError: Error {
        case couldNotReservePort
        case didNotStartListening
        case exitedBeforeListening
    }

    private static let serverScript = #"""
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

port = int(sys.argv[1])
delay = float(sys.argv[2])

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(delay)
        body = b'<!doctype html><body data-cmux-recovered="true">recovered</body>'
        self.send_response(200)
        self.send_header('Content-Type', 'text/html; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass

HTTPServer(('127.0.0.1', port), Handler).serve_forever()
"""#
}
