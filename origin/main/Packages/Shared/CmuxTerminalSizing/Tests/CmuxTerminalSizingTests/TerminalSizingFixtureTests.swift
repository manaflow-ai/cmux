import CmuxTerminalSizing
import Foundation
import Testing

/// Replays the shared conformance corpus that the cmux-tui Rust engine also runs.
struct TerminalSizingFixtureTests {
    struct Corpus: Decodable { var cases: [Case] }
    struct Case: Decodable, CustomTestStringConvertible {
        var name: String
        var initial: TerminalGridSize
        var steps: [Step]
        var testDescription: String { name }
    }
    struct Step: Decodable {
        var op: String
        var participant: TerminalSizingParticipant?
        var id: String?
        var cols: Int?
        var rows: Int?
        var owners: [String]?
        var reason: TerminalSizingReason?
        var generation: UInt64?
        var counts: [String: Bool]?
        var priorityKeys: [String: String]?
        var policy: TerminalSizingPolicy?
        var countsOverride: Bool??

        enum CodingKeys: String, CodingKey {
            case op, participant, id, cols, rows, owners, reason, generation, counts, policy
            case countsOverride = "counts_override"
            case priorityKeys = "priority_keys"
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            op = try c.decode(String.self, forKey: .op)
            participant = try c.decodeIfPresent(TerminalSizingParticipant.self, forKey: .participant)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            cols = try c.decodeIfPresent(Int.self, forKey: .cols)
            rows = try c.decodeIfPresent(Int.self, forKey: .rows)
            owners = try c.decodeIfPresent([String].self, forKey: .owners)
            reason = try c.decodeIfPresent(TerminalSizingReason.self, forKey: .reason)
            generation = try c.decodeIfPresent(UInt64.self, forKey: .generation)
            counts = try c.decodeIfPresent([String: Bool].self, forKey: .counts)
            priorityKeys = try c.decodeIfPresent([String: String].self, forKey: .priorityKeys)
            policy = try c.decodeIfPresent(TerminalSizingPolicy.self, forKey: .policy)
            countsOverride = c.contains(.countsOverride) ? .some(try c.decodeIfPresent(Bool.self, forKey: .countsOverride)) : nil
        }
    }

    static let corpus: [Case] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("schemas/terminal-sizing/fixtures.json")
        let data = try! Data(contentsOf: url)
        return try! JSONDecoder().decode(Corpus.self, from: data).cases
    }()

    @Test(arguments: corpus)
    func replay(_ fixture: Case) throws {
        var engine = TerminalSizingEngine(initialSize: fixture.initial)
        for (index, step) in fixture.steps.enumerated() {
            switch step.op {
            case "attach": engine.attach(try #require(step.participant))
            case "detach": engine.detach(try #require(step.id))
            case "report":
                engine.report(try #require(step.id), viewport: TerminalGridSize(cols: try #require(step.cols), rows: try #require(step.rows)))
            case "activity": engine.noteActivity(try #require(step.id))
            case "set_counts": engine.setCountsOverride(try #require(step.id), try #require(step.countsOverride))
            case "set_policy": engine.setPolicy(try #require(step.policy))
            case "expect":
                let s = engine.state
                let where_ = "step \(index)"
                if let cols = step.cols { #expect(s.cols == cols, "\(where_)") }
                if let rows = step.rows { #expect(s.rows == rows, "\(where_)") }
                if let owners = step.owners { #expect(s.owners == owners, "\(where_)") }
                if let reason = step.reason { #expect(s.reason == reason, "\(where_)") }
                if let generation = step.generation { #expect(s.generation == generation, "\(where_)") }
                for (id, value) in step.counts ?? [:] { #expect(s.participant(id)?.counts == value, "\(where_) counts \(id)") }
                for (id, key) in step.priorityKeys ?? [:] {
                    #expect(s.participant(id)?.priorityKey == key, "\(where_) priority_key \(id)")
                }
            default: Issue.record("unknown op \(step.op)")
            }
        }
    }

    @Test func stateRoundTripsThroughWireJSON() throws {
        var engine = TerminalSizingEngine(initialSize: TerminalGridSize(cols: 80, rows: 24))
        engine.attach(TerminalSizingParticipant(id: "c3", userID: "u_maya", displayName: "Maya", deviceKind: .mac,
                                                deviceName: "Mac Studio", viewport: TerminalGridSize(cols: 118, rows: 38)))
        let data = try JSONEncoder().encode(engine.state)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let row = try #require((object["participants"] as? [[String: Any]])?.first)
        #expect(row["priority_key"] as? String == "u_maya/mac")
        #expect(row["device_kind"] as? String == "mac")
        #expect(try JSONDecoder().decode(TerminalSizingState.self, from: data) == engine.state)
    }

    @Test func onlyNetworkDetachReconnects() {
        #expect(TerminalDetachReason(wireValue: "network", by: nil).reconnectsAutomatically)
        #expect(TerminalDetachReason(wireValue: nil, by: nil).reconnectsAutomatically)
        #expect(!TerminalDetachReason(wireValue: "disconnected-by", by: nil).reconnectsAutomatically)
        #expect(!TerminalDetachReason(wireValue: "host-shutdown", by: nil).reconnectsAutomatically)
    }
}
