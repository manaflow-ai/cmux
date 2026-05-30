import CmuxTerminalAccess
import Foundation
import Testing
@testable import cmux

@Suite struct HTTPControlInputRouteTests {
    private func makeServer(
        _ stub: StubTerminalAccessService,
        allowRaw: Bool = false
    ) throws -> (HTTPControlServer, UInt16) {
        var table = RouteTable()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: stub)
        HTTPControlRoutes.registerInputWrite(
            into: &table,
            service: stub,
            allowRaw: { allowRaw }
        )
        let server = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: "tok"),
            hostAllowlistFor: { HostAllowlist(port: Int($0)) }
        )
        let port = try server.startTCP(port: 0)
        return (server, port)
    }

    private func seededSurface() -> SurfaceInfo {
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
    }

    @Test func textSubmit() async throws {
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([seededSurface()])
        let (server, port) = try makeServer(stub)
        defer { server.stop() }
        let body = "{\"type\":\"text\",\"text\":\"ls\",\"submit\":true}"
        let req = "POST /v1/surfaces/surface:1/input HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("200 OK"))
        let last = await stub.lastInput
        guard case .text(let t, let submit) = last?.payload else {
            Issue.record("expected text")
            return
        }
        #expect(t == "ls")
        #expect(submit == true)
    }

    @Test func keysParsed() async throws {
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([seededSurface()])
        let (server, port) = try makeServer(stub)
        defer { server.stop() }
        let body = "{\"type\":\"keys\",\"keys\":[\"Ctrl+C\",\"Enter\",\"F5\"]}"
        let req = "POST /v1/surfaces/surface:1/input HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("200 OK"))
        let last = await stub.lastInput
        guard case .keys(let events) = last?.payload else {
            Issue.record("expected keys")
            return
        }
        #expect(events.count == 3)
    }

    @Test func rawDisabledReturns403() async throws {
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([seededSurface()])
        let (server, port) = try makeServer(stub, allowRaw: false)
        defer { server.stop() }
        let body = "{\"type\":\"raw\",\"bytes_base64\":\"YWI=\"}"
        let req = "POST /v1/surfaces/surface:1/input HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("403"))
    }

    @Test func rawEnabledWritesBytes() async throws {
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([seededSurface()])
        let (server, port) = try makeServer(stub, allowRaw: true)
        defer { server.stop() }
        let body = "{\"type\":\"raw\",\"bytes_base64\":\"YWI=\"}"
        let req = "POST /v1/surfaces/surface:1/input HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("200 OK"))
        let last = await stub.lastInput
        guard case .raw(let d) = last?.payload else {
            Issue.record("expected raw")
            return
        }
        #expect(d == Data([0x61, 0x62]))
    }

    @Test func unknownTypeReturns400() async throws {
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([seededSurface()])
        let (server, port) = try makeServer(stub)
        defer { server.stop() }
        let body = "{\"type\":\"nope\"}"
        let req = "POST /v1/surfaces/surface:1/input HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("400"))
    }

    @Test func focusFlagPropagates() async throws {
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([seededSurface()])
        let (server, port) = try makeServer(stub)
        defer { server.stop() }
        let body = "{\"type\":\"text\",\"text\":\"x\",\"focus\":true}"
        let req = "POST /v1/surfaces/surface:1/input HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("200 OK"))
        let last = await stub.lastInput
        #expect(last?.focusSurface == true)
    }
}
