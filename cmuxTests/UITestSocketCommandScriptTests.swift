import Foundation
import Testing
@testable import cmux_DEV

/// The in-app UI-test setup script runs socket commands in order and threads
/// the id a `new_*` command returns into later commands through `{last}`.
@Suite
struct UITestSocketCommandScriptTests {
    @Test
    func parsesNonEmptyLinesAndIgnoresMissingOrBlankInput() {
        #expect(UITestSocketCommandScript(environment: [:]) == nil)
        #expect(UITestSocketCommandScript(environment: [UITestSocketCommandScript.commandsKey: " \n "]) == nil)
        let script = UITestSocketCommandScript(environment: [
            UITestSocketCommandScript.commandsKey: "ping\n\n  new_workspace a  \n",
        ])
        #expect(script?.commands == ["ping", "new_workspace a"])
    }

    @Test
    func lastIsTheIdTheMostRecentNewCommandReturned() throws {
        let first = UUID().uuidString
        let second = UUID().uuidString
        let unrelated = UUID().uuidString
        let script = try #require(UITestSocketCommandScript(environment: [
            UITestSocketCommandScript.commandsKey: """
            new_workspace one
            set_status k v --tab={last}
            report_pr 1 https://x/1 --tab={last}
            new_workspace two
            set_status k v --tab={last}
            """,
        ]))
        var seen: [String] = []
        let replies = script.run { line in
            seen.append(line)
            switch seen.count {
            case 1: return "OK \(first)"
            case 3: return "OK \(unrelated)"  // not a new_* command: must not move {last}
            case 4: return "OK \(second)"
            default: return "OK"
            }
        }

        #expect(replies.count == 5)
        #expect(seen[1] == "set_status k v --tab=\(first)")
        #expect(seen[2] == "report_pr 1 https://x/1 --tab=\(first)")
        #expect(seen[4] == "set_status k v --tab=\(second)")
    }

    @Test
    func uuidExtractionTakesTheLastIdInAReply() {
        let id = UUID().uuidString
        #expect(UITestSocketCommandScript.lastUUID(in: "OK workspace:1 \(id)") == id)
        #expect(UITestSocketCommandScript.lastUUID(in: "OK") == nil)
    }
}
