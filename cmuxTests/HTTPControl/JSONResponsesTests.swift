import CmuxTerminalAccess
import Foundation
import Testing
@testable import cmux

@Suite struct JSONResponsesTests {
    @Test func mapsErrorsToStatusCodes() {
        #expect(JSONResponses.status(for: .unknownSurface) == 404)
        #expect(JSONResponses.status(for: .unauthorized) == 401)
        #expect(JSONResponses.status(for: .forbidden(reason: "x")) == 403)
        #expect(JSONResponses.status(for: .badRequest(reason: "x")) == 400)
        #expect(JSONResponses.status(for: .payloadTooLarge) == 413)
        #expect(JSONResponses.status(for: .rateLimited) == 429)
        // D11: featureDisabled looks like 404, not 503.
        #expect(JSONResponses.status(for: .featureDisabled) == 404)
        // D18: unsupported is 415 everywhere (E18).
        #expect(JSONResponses.status(for: .unsupported(reason: "x")) == 415)
        #expect(JSONResponses.status(for: .ghosttyError("boom")) == 500)
    }

    @Test func renderBadRequestErrorJSON() throws {
        let resp = JSONResponses.error(.badRequest(reason: "bad format"))
        #expect(resp.status == 400)
        let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        let err = obj?["error"] as? [String: Any]
        #expect(err?["code"] as? String == "bad_request")
        #expect((err?["message"] as? String)?.contains("bad format") == true)
    }

    @Test func renderFeatureDisabledAsNotFoundWireCode() throws {
        let resp = JSONResponses.error(.featureDisabled)
        #expect(resp.status == 404)
        let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        let err = obj?["error"] as? [String: Any]
        // D11: even the wire code is "not_found" so callers can't
        // distinguish "endpoint off" from "endpoint missing".
        #expect(err?["code"] as? String == "not_found")
    }

    @Test func renderUnsupportedAs415() throws {
        let resp = JSONResponses.error(.unsupported(reason: "binary disabled"))
        #expect(resp.status == 415)
        let obj = try JSONSerialization.jsonObject(with: resp.body) as? [String: Any]
        let err = obj?["error"] as? [String: Any]
        #expect(err?["code"] as? String == "unsupported_media_type")
        #expect(err?["message"] as? String == "binary disabled")
    }

    @Test func methodNotAllowedRenders405WithAllowHeader() throws {
        let resp = JSONResponses.methodNotAllowed(allow: ["GET", "POST"])
        #expect(resp.status == 405)
        let allow = resp.headers.first { $0.0 == "Allow" }?.1
        #expect(allow == "GET, POST")
        let contentType = resp.headers.first { $0.0 == "Content-Type" }?.1
        #expect(contentType == "application/json")
    }

    @Test func jsonHelperPopulatesContentHeaders() {
        let resp = JSONResponses.json(200, ["ok": true])
        #expect(resp.status == 200)
        #expect(resp.headers.contains { $0.0 == "Content-Type" && $0.1 == "application/json" })
        let length = resp.headers.first { $0.0 == "Content-Length" }?.1
        #expect(length == "\(resp.body.count)")
    }

    @Test func jsonBodyEmitsSortedKeysForDeterminism() throws {
        let resp = JSONResponses.json(200, ["b": 2, "a": 1])
        // Sorted keys → the literal string starts with "a" before "b".
        let text = String(data: resp.body, encoding: .utf8) ?? ""
        let aIdx = text.firstIndex(of: "a")
        let bIdx = text.firstIndex(of: "b")
        try #require(aIdx != nil && bIdx != nil)
        #expect(aIdx! < bIdx!)
    }
}
