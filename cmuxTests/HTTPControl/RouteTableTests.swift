import Foundation
import Testing
@testable import cmux

@Suite struct RouteTableTests {
    private func req(_ method: String, _ path: String) -> HTTPRequest {
        HTTPRequest(method: method, path: path, query: [:], headers: [], body: Data())
    }

    @Test func dispatchesMatchingRoute() async throws {
        var table = RouteTable()
        table.register(method: "GET", pattern: "/v1/surfaces") { _ in
            JSONResponses.json(200, ["ok": true])
        }
        let resp = await table.dispatch(req("GET", "/v1/surfaces"))
        #expect(resp.status == 200)
    }

    @Test func methodMismatchReturns405WithAllow() async throws {
        var table = RouteTable()
        table.register(method: "GET", pattern: "/v1/surfaces") { _ in
            JSONResponses.json(200, ["ok": true])
        }
        table.register(method: "POST", pattern: "/v1/surfaces") { _ in
            JSONResponses.json(201, ["ok": true])
        }
        let resp = await table.dispatch(req("DELETE", "/v1/surfaces"))
        #expect(resp.status == 405)
        let allow = resp.headers.first { $0.0 == "Allow" }?.1 ?? ""
        #expect(allow.contains("GET"))
        #expect(allow.contains("POST"))
    }

    @Test func unknownPathReturns404() async throws {
        var table = RouteTable()
        table.register(method: "GET", pattern: "/v1/surfaces") { _ in
            JSONResponses.json(200, ["ok": true])
        }
        let resp = await table.dispatch(req("GET", "/nope"))
        #expect(resp.status == 404)
    }

    @Test func parameterizedPatternsMatchPrefix() async throws {
        var table = RouteTable()
        table.register(method: "GET", pattern: "/v1/surfaces/*/screen") { req in
            JSONResponses.json(200, ["path": req.path])
        }
        let resp = await table.dispatch(req("GET", "/v1/surfaces/surface:1/screen"))
        #expect(resp.status == 200)
    }
}
