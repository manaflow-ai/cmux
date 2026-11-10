internal import Foundation

@main
struct SurfaceIconTTLRegression {
    static func main() throws {
        let parser = ControlSurfaceIconParser()
        let base: [String: JSONValue] = [
            "workspace_id": .string("AABBCCDD-1111-2222-3333-444455556666"),
            "surface_id": .string("AABBCCDD-1111-2222-3333-444455557777"),
            "owner_id": .string("test-producer"),
            "expected_agent_pid": .int(12345),
            "expected_process_start": .string("test-generation"),
            "asset": .object(["frames": .array([
                .object(["svg": .string("<svg/>"), "duration_ms": .int(100)])
            ]), "loop": .bool(true)])
        ]
        var failed = 0
        var executed = 0
        func check(_ name: String, _ action: () throws -> Bool) {
            executed += 1
            do {
                if try action() { print("PASS \(name)") }
                else { failed += 1; print("FAIL \(name)") }
            } catch { failed += 1; print("FAIL \(name): \(error)") }
        }
        check("omitted TTL remains nil") { try parser.parse(base, clear: false).ttlSeconds as Int? == nil }
        for ttl in [1, 4, 5, 120, 121, 600, Int.max] {
            check("integer TTL \(ttl)") {
                var params = base
                params["ttl_seconds"] = .int(Int64(ttl))
                return try parser.parse(params, clear: false).ttlSeconds == ttl
            }
            check("decimal TTL \(ttl)") {
                var params = base
                params["ttl_seconds"] = .decimal(String(ttl))
                return try parser.parse(params, clear: false).ttlSeconds == ttl
            }
        }
        for raw in ["600.0", "6e2"] {
            check("JSON TTL \(raw)") {
                let object = try JSONSerialization.jsonObject(with: Data("{\"ttl\":\(raw)}".utf8)) as! [String: Any]
                var params = base
                params["ttl_seconds"] = JSONValue(foundationObject: object["ttl"]!)!
                return try parser.parse(params, clear: false).ttlSeconds == 600
            }
        }
        let invalid: [JSONValue] = [.null, .bool(true), .string("600"), .int(0), .int(-1),
                                    .double(1.5), .double(.infinity), .double(Double(Int.max)),
                                    .decimal("9223372036854775808"), .decimal("9007199254740992.5")]
        for (index, value) in invalid.enumerated() {
            check("reject malformed TTL \(index)") {
                var params = base
                params["ttl_seconds"] = value
                do { _ = try parser.parse(params, clear: false); return false }
                catch is ControlSurfaceIconParser.Invalid { return true }
            }
        }
        print("Executed \(executed) parser behavior checks; failures: \(failed)")
        if failed > 0 { exit(1) }
    }
}
