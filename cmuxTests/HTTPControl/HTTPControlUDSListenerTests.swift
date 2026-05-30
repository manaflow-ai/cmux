// SPDX-License-Identifier: MIT
//
// Task 1.18 / D12 — exercises the AF_UNIX listener via raw POSIX
// `socket(2)` + `connect(2)`, confirms the bound socket file is mode
// 0600, and round-trips one `GET /v1/surfaces` request through the
// listener's same RouteTable as the TCP path.

import Darwin
import Foundation
import Testing
import CmuxTerminalAccess
@testable import cmux

@Suite struct HTTPControlUDSListenerTests {
    @Test func udsListenerHandlesGetSurfaces() async throws {
        let path = "/tmp/cmux-http-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let stub = StubTerminalAccessService()
        await stub.setSurfaces([
            SurfaceInfo(
                handle: .ref(kind: "surface", ordinal: 1),
                uuid: UUID(),
                workspaceRef: "w:1",
                title: "t",
                cols: 80,
                rows: 24,
                altScreen: false,
                focused: true,
                semanticAvailable: false
            )
        ])
        var table = RouteTable()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: stub)

        let server = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: "tok"),
            // UDS path uses port 0 in the allowlist; clients send
            // `Host: localhost:0`.
            hostAllowlistFor: { _ in HostAllowlist(port: 0) }
        )
        try server.startUDS(path: path)
        defer { server.stop() }

        // D12 — socket file must be mode 0600.
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.uint16Value == 0o600)

        // Connect via raw POSIX socket(2)/connect(2).
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        let pathBytes = Array(path.utf8)
        try #require(pathBytes.count < maxLen)
        let connected = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr -> Int32 in
            for (i, byte) in pathBytes.enumerated() {
                ptr.advanced(by: i).pointee = Int8(bitPattern: byte)
            }
            ptr.advanced(by: pathBytes.count).pointee = 0
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        fd,
                        $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
        }
        #expect(connected == 0)

        // Send one well-formed request.
        let req = "GET /v1/surfaces HTTP/1.1\r\n"
            + "Host: localhost:0\r\n"
            + "Authorization: Bearer tok\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        let reqBytes = Array(req.utf8)
        let sent = reqBytes.withUnsafeBufferPointer { buf -> Int in
            Darwin.send(fd, buf.baseAddress!, buf.count, 0)
        }
        #expect(sent == reqBytes.count)

        // Receive the full response.
        var received = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                Darwin.recv(fd, p.baseAddress!, p.count, 0)
            }
            if n <= 0 { break }
            received.append(contentsOf: buf.prefix(n))
        }
        let resp = String(decoding: received, as: UTF8.self)
        #expect(resp.contains("200"))
        #expect(resp.contains("surface:1"))
    }

    @Test func udsListenerRejectsMissingBearer() async throws {
        let path = "/tmp/cmux-http-test-\(UUID().uuidString).sock"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let stub = StubTerminalAccessService()
        var table = RouteTable()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: stub)
        let server = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: "tok"),
            hostAllowlistFor: { _ in HostAllowlist(port: 0) }
        )
        try server.startUDS(path: path)
        defer { server.stop() }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr -> Int32 in
            for (i, byte) in pathBytes.enumerated() {
                ptr.advanced(by: i).pointee = Int8(bitPattern: byte)
            }
            ptr.advanced(by: pathBytes.count).pointee = 0
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(
                        fd, $0,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
        }
        let req = "GET /v1/surfaces HTTP/1.1\r\n"
            + "Host: localhost:0\r\n"
            + "Connection: close\r\n"
            + "\r\n"
        let reqBytes = Array(req.utf8)
        _ = reqBytes.withUnsafeBufferPointer { buf -> Int in
            Darwin.send(fd, buf.baseAddress!, buf.count, 0)
        }
        var received = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let n = buf.withUnsafeMutableBufferPointer { p -> Int in
                Darwin.recv(fd, p.baseAddress!, p.count, 0)
            }
            if n <= 0 { break }
            received.append(contentsOf: buf.prefix(n))
        }
        let resp = String(decoding: received, as: UTF8.self)
        #expect(resp.contains("401"))
    }
}
