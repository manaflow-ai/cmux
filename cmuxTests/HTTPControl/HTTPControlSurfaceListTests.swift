import CmuxTerminalAccess
import Foundation
import Network
import Testing
@testable import cmux

@Suite struct HTTPControlSurfaceListTests {
    @Test func listSurfacesHappyPath() async throws {
        let stub = StubTerminalAccessService()
        await stub.setSurfaces([
            SurfaceInfo(
                handle: .ref(kind: "surface", ordinal: 1),
                uuid: UUID(),
                workspaceRef: "workspace:1",
                title: "t",
                cols: 80,
                rows: 24,
                altScreen: false,
                focused: true,
                semanticAvailable: false
            ),
        ])
        var table = RouteTable()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: stub)
        let server = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: "tok"),
            hostAllowlistFor: { HostAllowlist(port: Int($0)) }
        )
        let port = try server.startTCP(port: 0)
        defer { server.stop() }
        let resp = try LoopbackHTTPClient.send(
            port: port,
            raw: "GET /v1/surfaces HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        )
        #expect(resp.contains("200 OK"))
        #expect(resp.contains("surface:1"))
        #expect(resp.contains("\"semantic_available\":false"))
    }

    @Test func missingTokenReturns401() throws {
        var table = RouteTable()
        let stub = StubTerminalAccessService()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: stub)
        let server = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: "tok"),
            hostAllowlistFor: { HostAllowlist(port: Int($0)) }
        )
        let port = try server.startTCP(port: 0)
        defer { server.stop() }
        let resp = try LoopbackHTTPClient.send(
            port: port,
            raw: "GET /v1/surfaces HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
        )
        #expect(resp.contains("401"))
    }

    @Test func spoofedHostReturns403() throws {
        var table = RouteTable()
        let stub = StubTerminalAccessService()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: stub)
        let server = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: "tok"),
            hostAllowlistFor: { HostAllowlist(port: Int($0)) }
        )
        let port = try server.startTCP(port: 0)
        defer { server.stop() }
        let resp = try LoopbackHTTPClient.send(
            port: port,
            raw: "GET /v1/surfaces HTTP/1.1\r\nHost: evil.example:\(port)\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        )
        #expect(resp.contains("403"))
    }
}
