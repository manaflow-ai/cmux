import Foundation
import Testing

/// Kiro inbox output and fail-open behavior, using the shared CLI command harness.
extension CLIAgentMessageCommandTests {
    @Test func kiroPromptSubmitDrainPrintsPendingMessagesAsPlainContext() throws {
        let run = try runCLI(
            arguments: ["hooks", "kiro", "inbox-drain"],
            kiroProcess: true,
            standardInput: #"{"session_id":"k-1","hook_event_name":"UserPromptSubmit","prompt":"hi"}"#,
            responses: ["agent.message.claim": ["messages": [], "text": "[cmux agent message] from a\n---\nhello\n---"]]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        let params = try #require(run.request("agent.message.claim")?["params"] as? [String: Any])
        #expect(params["via"] as? String == "kiro.prompt-submit")
        #expect(params["mark_delivered_read"] as? Bool == false)
        // Kiro adds prompt-submit stdout to the model context as is.
        #expect(run.result.stdout.hasPrefix("[cmux agent message] from a"), Comment(rawValue: run.result.stdout))
    }

    @Test func kiroStopContinuesTheTurnWithPendingMessages() throws {
        let run = try runCLI(
            arguments: ["hooks", "kiro", "inbox-stop"],
            kiroProcess: true,
            standardInput: #"{"session_id":"k-1","hook_event_name":"Stop"}"#,
            responses: ["agent.message.claim": ["messages": [], "text": "[cmux agent message] from a\n---\nnext\n---"]]
        )

        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
        let params = try #require(run.request("agent.message.claim")?["params"] as? [String: Any])
        #expect(params["via"] as? String == "kiro.stop")
        #expect(params["mark_delivered_read"] as? Bool == true)
        let output = try #require(codexHookJSONObject(run.result.stdout))
        #expect(output["decision"] as? String == "block")
        #expect((output["reason"] as? String)?.contains("next") == true)
    }

    @Test func kiroInboxHooksPrintNothingWithoutMessages() throws {
        for subcommand in ["inbox-drain", "inbox-stop"] {
            let run = try runCLI(
                arguments: ["hooks", "kiro", subcommand],
                kiroProcess: true,
                standardInput: #"{"session_id":"k-1"}"#,
                responses: ["agent.message.claim": ["messages": [], "text": ""]]
            )
            #expect(run.result.status == 0)
            #expect(run.result.stdout.isEmpty, Comment(rawValue: run.result.stdout))

            let outside = try runCLI(
                arguments: ["hooks", "kiro", subcommand],
                kiroProcess: true,
                standardInput: #"{"session_id":"k-1"}"#,
                surfaceID: nil
            )
            #expect(outside.result.status == 0)
            #expect(outside.result.stdout.isEmpty, Comment(rawValue: outside.result.stdout))
            #expect(outside.request("agent.message.claim") == nil)
        }
    }

    @Test func kiroGlobalInboxHookWithoutLiveKiroPIDDoesNotClaim() throws {
        let run = try runCLI(
            arguments: ["hooks", "kiro", "inbox-drain"],
            standardInput: #"{"session_id":"k-global","hook_event_name":"UserPromptSubmit"}"#,
            extraEnvironment: ["CMUX_KIRO_GLOBAL_HOOK": "1"],
            responses: [
                "agent.message.claim": ["messages": [], "text": "must not be claimed"],
            ]
        )

        #expect(run.result.status == 0)
        #expect(run.result.stdout.isEmpty)
        #expect(run.request("agent.message.claim") == nil)
    }

    @Test func kiroInheritedPIDWithoutAncestorDoesNotClaim() throws {
        let run = try runCLI(
            arguments: ["hooks", "kiro", "inbox-drain"],
            extraEnvironment: ["CMUX_KIRO_PID": String(ProcessInfo.processInfo.processIdentifier)],
            responses: ["agent.message.claim": ["messages": [], "text": "wrong session"]]
        )
        #expect(run.result.status == 0)
        #expect(run.result.stdout.isEmpty)
        #expect(run.request("agent.message.claim") == nil)
    }

    @Test func kiroSurfaceComparisonUsesUUIDIdentity() throws {
        let run = try runCLI(
            arguments: ["hooks", "kiro", "inbox-drain"],
            kiroProcess: true,
            surfaceID: "abcdefab-abcd-abcd-abcd-abcdefabcdef",
            responses: ["agent.message.claim": ["messages": [], "text": "same surface"]]
        )
        #expect(run.result.stdout == "same surface\n")
    }

    @Test func globalKiroLifecycleWithoutAncestorDoesNotQueue() throws {
        let run = try runCLI(
            arguments: ["hooks", "enqueue", "kiro", "session-start"],
            extraEnvironment: ["CMUX_KIRO_GLOBAL_HOOK": "1"]
        )
        #expect(run.result.status == 0)
        #expect(run.requests.isEmpty)
    }

    func makeKiroProcess(at root: URL) throws -> String {
        let source = root.appendingPathComponent("kiro.c")
        let binary = root.appendingPathComponent("kiro-cli")
        try """
        #include <unistd.h>
        #include <sys/wait.h>
        int main(int argc, char **argv) {
            if (argc < 2) return 2;
            pid_t child = fork();
            if (child < 0) return 3;
            if (child == 0) { execv(argv[1], argv + 1); _exit(127); }
            int status;
            if (waitpid(child, &status, 0) < 0) return 4;
            return WIFEXITED(status) ? WEXITSTATUS(status) : 5;
        }
        """.write(to: source, atomically: true, encoding: .utf8)
        let build = CLIHookProcessRunner.run(
            executablePath: "/usr/bin/cc", arguments: [source.path, "-o", binary.path],
            environment: ["PATH": "/usr/bin:/bin"], standardInput: "", timeout: 60
        )
        try #require(build.status == 0, Comment(rawValue: build.stderr))
        return binary.path
    }
}
