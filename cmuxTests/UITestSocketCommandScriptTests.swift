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
    func waitPausesWithoutSendingAnything() throws {
        let script = try #require(UITestSocketCommandScript(environment: [
            UITestSocketCommandScript.commandsKey: "wait 250\nping\nwait nope",
        ]))
        var sent: [String] = []
        var slept: [Int] = []
        let replies = script.run({ sent.append($0); return "PONG" }, sleep: { slept.append($0) })

        #expect(slept == [250])
        #expect(sent == ["ping", "wait nope"])
        #expect(replies == ["OK", "PONG", "PONG"])
    }

    @Test
    func letSavesAWorkspaceAndListSurfacesFillsSurface() throws {
        let saved = UUID().uuidString
        let later = UUID().uuidString
        let surface = UUID().uuidString
        let script = try #require(UITestSocketCommandScript(environment: [
            UITestSocketCommandScript.commandsKey: """
            new_workspace unseen
            let unseen
            new_workspace other
            list_surfaces {unseen}
            notify_target {unseen} {surface} Done|Agent|Finished
            """,
        ]))
        var sent: [String] = []
        let replies = script.run { line in
            sent.append(line)
            switch sent.count {
            case 1: return "OK \(saved)"
            case 2: return "OK \(later)"
            case 3: return "* 0: \(surface)"
            default: return "OK"
            }
        }

        #expect(replies[1] == "OK")
        #expect(sent[2] == "list_surfaces \(saved)")
        #expect(sent[3] == "notify_target \(saved) \(surface) Done|Agent|Finished")
    }

    @Test
    func letWithoutAnEarlierIdFails() throws {
        let script = try #require(UITestSocketCommandScript(environment: [
            UITestSocketCommandScript.commandsKey: "let early",
        ]))
        #expect(script.run { _ in "OK" }.first?.hasPrefix("ERROR") == true)
    }

    @Test
    func uuidExtractionTakesTheLastIdInAReply() {
        let id = UUID().uuidString
        #expect(UITestSocketCommandScript.lastUUID(in: "OK workspace:1 \(id)") == id)
        #expect(UITestSocketCommandScript.lastUUID(in: "OK") == nil)
    }

    @Test
    func groupCreateRepliesFillTheGroupPlaceholder() throws {
        let group = UUID().uuidString
        let script = try #require(UITestSocketCommandScript(environment: [
            UITestSocketCommandScript.commandsKey: """
            {"id":"g","method":"workspace.group.create","params":{}}
            {"id":"c","method":"workspace.group.collapse","params":{"group_id":"{group}"}}
            """,
        ]))
        var sent: [String] = []
        _ = script.run { line in
            sent.append(line)
            return sent.count == 1
                ? #"{"id":"g","ok":true,"result":{"created":true,"group":{"id":"\#(group)"}}}"#
                : #"{"id":"c","ok":true,"result":{}}"#
        }

        #expect(sent[1].contains(#""group_id":"\#(group)""#))
    }

    @Test
    func pidIsTheAppsOwnProcessId() throws {
        let script = try #require(UITestSocketCommandScript(environment: [
            UITestSocketCommandScript.commandsKey: "set_agent_pid claude_code {pid} --tab=x",
        ]))
        var sent: [String] = []
        _ = script.run(processIdentifier: 4242) { sent.append($0); return "OK" }
        #expect(sent == ["set_agent_pid claude_code 4242 --tab=x"])
    }

    @Test
    func v2ErrorRepliesCountAsFailures() {
        #expect(UITestSocketCommandScript.isFailure(#"{"id":"c","ok":false,"error":{"code":"not_found"}}"#))
        #expect(!UITestSocketCommandScript.isFailure(#"{"id":"c","ok":true,"result":{}}"#))
        #expect(UITestSocketCommandScript.isFailure("ERROR: nope"))
        #expect(!UITestSocketCommandScript.isFailure("OK"))
    }
}
