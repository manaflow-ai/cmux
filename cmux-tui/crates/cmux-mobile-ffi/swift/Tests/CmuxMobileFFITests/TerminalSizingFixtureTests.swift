import CmuxMobileFFI
import Foundation
import Testing

/// Replays schemas/terminal-sizing/fixtures.json through the generated Swift
/// bindings and the Rust library in the xcframework. Records are built in
/// Swift, so every step crosses the FFI boundary in both directions.
struct TerminalSizingFixtureTests {
    typealias JSON = [String: Any]

    struct Case: CustomTestStringConvertible, @unchecked Sendable {
        var name: String
        var initial: JSON
        var steps: [JSON]
        var testDescription: String { name }
    }

    static let corpus: [Case] = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let relative = "schemas/terminal-sizing/fixtures.json"
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path) {
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return [] }
            directory = parent
        }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(relative)),
              let root = try? JSONSerialization.jsonObject(with: data) as? JSON,
              let cases = root["cases"] as? [JSON]
        else { return [] }
        return cases.map { item in
            Case(
                name: item["name"] as? String ?? "",
                initial: item["initial"] as? JSON ?? [:],
                steps: item["steps"] as? [JSON] ?? []
            )
        }
    }()

    static func size(_ value: JSON) throws -> TerminalGridSize {
        TerminalGridSize(
            cols: UInt16(try #require(value["cols"] as? Int)),
            rows: UInt16(try #require(value["rows"] as? Int))
        )
    }

    static func participant(_ value: JSON) throws -> TerminalSizingParticipant {
        TerminalSizingParticipant(
            id: try #require(value["id"] as? String),
            userId: value["user_id"] as? String,
            displayName: value["display_name"] as? String,
            deviceKind: terminalDeviceKindFromWire(raw: value["device_kind"] as? String ?? "unknown"),
            deviceName: value["device_name"] as? String,
            deviceId: value["device_id"] as? String,
            via: value["via"] as? String,
            viewport: try (value["viewport"] as? JSON).map(size),
            countsOverride: value["counts_override"] as? Bool
        )
    }

    @Test func corpusIsPresent() {
        #expect(!Self.corpus.isEmpty)
    }

    @Test(arguments: corpus)
    func replay(_ fixture: Case) throws {
        let engine = TerminalSizingEngine(
            initial: try Self.size(fixture.initial),
            policy: terminalSizingPolicy(mode: .smallest, priority: [], fixed: nil)
        )
        for (index, step) in fixture.steps.enumerated() {
            let at = "\(fixture.name) step \(index)"
            let id = step["id"] as? String ?? ""
            switch step["op"] as? String {
            case "attach": _ = engine.attach(participant: try Self.participant(try #require(step["participant"] as? JSON)))
            case "detach": _ = engine.detach(id: id)
            case "report": _ = engine.report(id: id, viewport: try Self.size(step))
            case "activity": _ = engine.noteActivity(id: id)
            case "clear_viewport": _ = engine.clearViewport(id: id)
            case "set_counts": _ = engine.setCountsOverride(id: id, value: step["counts_override"] as? Bool)
            case "set_policy":
                let data = try JSONSerialization.data(withJSONObject: try #require(step["policy"] as? JSON))
                _ = engine.setPolicy(policy: try terminalSizingPolicyFromJson(json: String(decoding: data, as: UTF8.self)))
            case "expect":
                let state = engine.state()
                if let cols = step["cols"] as? Int { #expect(Int(state.cols) == cols, "\(at) cols") }
                if let rows = step["rows"] as? Int { #expect(Int(state.rows) == rows, "\(at) rows") }
                if let owners = step["owners"] as? [String] { #expect(state.owners == owners, "\(at) owners") }
                if let reason = step["reason"] as? String {
                    #expect(terminalSizingReasonWire(reason: state.reason) == reason, "\(at) reason")
                }
                if let generation = step["generation"] as? Int {
                    #expect(state.generation == UInt64(generation), "\(at) generation")
                }
                for (participant, expected) in step["priority_keys"] as? [String: String] ?? [:] {
                    let row = state.participants.first { $0.participant.id == participant }
                    #expect(row?.priorityKey == expected, "\(at) priority_key \(participant)")
                }
                for (participant, expected) in step["counts"] as? [String: Bool] ?? [:] {
                    #expect(engine.counts(id: participant) == expected, "\(at) counts \(participant)")
                    let row = state.participants.first { $0.participant.id == participant }
                    #expect(row?.counts == expected, "\(at) published counts \(participant)")
                }
            default: Issue.record("\(at): unknown op \(String(describing: step["op"]))")
            }
        }
    }

    final class Recorder: TerminalSizingListener, @unchecked Sendable {
        private let lock = NSLock()
        private var received: [TerminalSizingState] = []
        var states: [TerminalSizingState] { lock.withLock { received } }
        func onState(state: TerminalSizingState) { lock.withLock { received.append(state) } }
    }

    @Test func swiftListenerReceivesEveryChangedState() {
        let engine = TerminalSizingEngine(
            initial: TerminalGridSize(cols: 80, rows: 24),
            policy: terminalSizingPolicy(mode: .latest, priority: [], fixed: nil)
        )
        let recorder = Recorder()
        engine.setListener(listener: recorder)
        let mac = TerminalSizingParticipant(
            id: "mac", userId: "u1", displayName: nil, deviceKind: .mac, deviceName: nil,
            deviceId: nil, via: nil, viewport: TerminalGridSize(cols: 150, rows: 42), countsOverride: nil
        )
        #expect(engine.attach(participant: mac))
        #expect(!engine.detach(id: "missing"))
        #expect(engine.report(id: "mac", viewport: TerminalGridSize(cols: 120, rows: 40)))
        #expect(recorder.states.map(\.generation) == [1, 2])
        #expect(recorder.states.last == engine.state())
        engine.setListener(listener: nil)
        #expect(engine.detach(id: "mac"))
        #expect(recorder.states.count == 2)
    }

    @Test func stateRoundTripsThroughTheWireAndBadJSONThrows() throws {
        let engine = TerminalSizingEngine(
            initial: TerminalGridSize(cols: 80, rows: 24),
            policy: terminalSizingPolicy(mode: .fixed, priority: [], fixed: TerminalGridSize(cols: 0, rows: 0))
        )
        #expect(engine.state().policy.fixed == TerminalGridSize(cols: 2, rows: 1))
        let json = try terminalSizingStateToJson(state: engine.state())
        #expect(try terminalSizingStateFromJson(json: json) == engine.state())
        #expect(throws: TerminalSizingWireError.self) { try terminalSizingStateFromJson(json: "{") }
        #expect(terminalDeviceKindFromWire(raw: "quantum") == .unknown)
    }
}
