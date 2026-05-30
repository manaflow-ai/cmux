import CmuxTerminalAccess
import Foundation
import Testing
@testable import cmux

@Suite struct HTTPControlScreenRouteTests {
    private func makeServer(
        _ stub: StubTerminalAccessService
    ) throws -> (HTTPControlServer, UInt16) {
        var table = RouteTable()
        HTTPControlRoutes.registerSurfaceList(into: &table, service: stub)
        HTTPControlRoutes.registerScreenRead(into: &table, service: stub)
        let server = HTTPControlServer(
            routeTable: table,
            auth: HTTPAuth(expectedToken: "tok"),
            hostAllowlistFor: { HostAllowlist(port: Int($0)) }
        )
        let port = try server.startTCP(port: 0)
        return (server, port)
    }

    @Test func textHappyPath() async throws {
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
            ),
        ])
        await stub.setScreen(.text(
            TextScreenPayload(
                cols: 80,
                rows: 24,
                altScreen: false,
                title: "t",
                text: "hello"
            )
        ))
        let (server, port) = try makeServer(stub)
        defer { server.stop() }
        let req = "GET /v1/surfaces/surface:1/screen?format=text&region=viewport HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("200 OK"))
        #expect(resp.contains("\"text\":\"hello\""))
    }

    @Test func cellsHappyPath_format_cells_works_in_v1() async throws {
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
                semanticAvailable: true
            ),
        ])
        let grid = CellGrid(
            cols: 2,
            rows: 1,
            altScreen: false,
            title: "t",
            cursor: CursorState(row: 0, col: 0, visible: true, style: .block),
            semanticAvailable: true,
            rowsData: [
                CellRow(
                    wrap: false,
                    wrapContinuation: false,
                    cells: [
                        Cell(
                            t: "a",
                            wide: .narrow,
                            fg: .default,
                            bg: .default,
                            attrs: [],
                            underlineKind: nil,
                            underlineColor: nil,
                            hyperlink: nil,
                            semantic: nil
                        ),
                        Cell(
                            t: "b",
                            wide: .narrow,
                            fg: .default,
                            bg: .default,
                            attrs: [],
                            underlineKind: nil,
                            underlineColor: nil,
                            hyperlink: nil,
                            semantic: nil
                        ),
                    ]
                ),
            ]
        )
        await stub.setScreen(.cells(grid))
        let (server, port) = try makeServer(stub)
        defer { server.stop() }
        let req = "GET /v1/surfaces/surface:1/screen?format=cells&region=viewport HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("200 OK"))
        #expect(resp.contains("\"format\":\"cells\""))
        #expect(resp.contains("\"semantic_available\":true"))
    }

    @Test func formatRawReturns400WithStreamingMessage() async throws {
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
            ),
        ])
        let (server, port) = try makeServer(stub)
        defer { server.stop() }
        let req = "GET /v1/surfaces/surface:1/screen?format=raw HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("400"))
        #expect(resp.contains("format=raw is streaming-only"))
    }

    @Test func wrapJoinAcceptedInV1() async throws {
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
            ),
        ])
        await stub.setScreen(.text(
            TextScreenPayload(
                cols: 80,
                rows: 24,
                altScreen: false,
                title: nil,
                text: "joined"
            )
        ))
        let (server, port) = try makeServer(stub)
        defer { server.stop() }
        let req = "GET /v1/surfaces/surface:1/screen?format=text&wrap=join HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("200 OK"))
    }

    @Test func methodMismatchReturns405WithAllow() async throws {
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
            ),
        ])
        let (server, port) = try makeServer(stub)
        defer { server.stop() }
        let req = "POST /v1/surfaces/surface:1/screen HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("405"))
        #expect(resp.contains("Allow: GET"))
    }

    @Test func unknownPathReturns404() async throws {
        let stub = StubTerminalAccessService()
        let (server, port) = try makeServer(stub)
        defer { server.stop() }
        let req = "GET /v1/nope HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nAuthorization: Bearer tok\r\nConnection: close\r\n\r\n"
        let resp = try LoopbackHTTPClient.send(port: port, raw: req)
        #expect(resp.contains("404"))
    }
}
