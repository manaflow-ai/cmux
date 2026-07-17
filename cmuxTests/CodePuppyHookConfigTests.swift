import Foundation
import Testing

/// Regression coverage for Code Puppy hook-config generation.
///
/// Code Puppy's hook-config validator (hook_engine/validator.py) requires a
/// `matcher` field on every hook group and rejects the whole config if any is
/// missing. cmux's shared `.nested` writer omitted `matcher`, so
/// `cmux hooks code-puppy install` produced a config Code Puppy refused to load
/// ("SessionStart[0] missing required field matcher", ...). The fix sets
/// `nestedGroupMatcher: "*"` on the code-puppy AgentHookDef.
@Suite(.serialized)
struct CodePuppyHookConfigTests {
    /// Events cmux writes for code-puppy: five lifecycle events plus the two
    /// Feed bridge events. Every one must carry a `matcher`.
    private static let expectedEvents: Set<String> = [
        "SessionStart", "UserPromptSubmit", "Stop", "Notification", "SessionEnd",
        "PreToolUse", "PostToolUse",
    ]

    @Test func codePuppyInstallWritesMatcherOnEveryHookGroup() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundledCLILinkageTests.self)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-code-puppy-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let install = runCodexHookProcess(
            executablePath: cliPath,
            arguments: ["hooks", "code-puppy", "install", "--yes"],
            environment: [
                "HOME": root.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CMUX_CLI_SENTRY_DISABLED": "1",
            ],
            timeout: 10
        )
        #expect(install.status == 0, Comment(rawValue: install.stderr))

        let hookURL = root.appendingPathComponent(".code_puppy/hooks.json", isDirectory: false)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: hookURL)) as? [String: Any]
        )
        // Code Puppy accepts both bare {Event:[...]} and wrapped {"hooks":{...}};
        // cmux writes the wrapped form.
        let hooks = try #require((json["hooks"] as? [String: Any]) ?? json as [String: Any])

        for event in Self.expectedEvents {
            let groups = try #require(
                hooks[event] as? [[String: Any]],
                Comment(rawValue: "missing event \(event)")
            )
            #expect(!groups.isEmpty, Comment(rawValue: "\(event) has no hook groups"))
            for (index, group) in groups.enumerated() {
                let matcher = group["matcher"] as? String
                #expect(
                    matcher == "*",
                    Comment(rawValue: "\(event)[\(index)] must carry matcher \"*\", got \(String(describing: group["matcher"]))")
                )
                let inner = group["hooks"] as? [[String: Any]]
                #expect(inner?.isEmpty == false, Comment(rawValue: "\(event)[\(index)] has no hooks"))
            }
        }
    }
}
