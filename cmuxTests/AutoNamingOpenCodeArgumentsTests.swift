import Foundation
import Testing

@Suite struct AutoNamingOpenCodeArgumentsTests {
    private let policy = AutoNamingEnvironmentPolicy()

    private func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    @Test func argumentsKeepTheSummarizerInItsTemporaryDirectory() throws {
        let arguments = AutoNamingEnvironmentPolicy.openCodeSummarizerArguments(
            directory: "/tmp/cmux-autoname",
            promptPath: "/tmp/cmux-autoname/prompt.txt"
        )

        #expect(arguments.prefix(4) == ["run", "--pure", "--format", "default"])
        #expect(value(of: "--dir", in: arguments) == "/tmp/cmux-autoname")
        #expect(value(of: "--file", in: arguments) == "/tmp/cmux-autoname/prompt.txt")
        #expect(arguments.contains("Generate a 2-5 word title from the attached conversation excerpt. Output only the title."))
    }

    @Test func environmentDisablesOpenCodeToolsAndProjectConfig() throws {
        let environment = policy.openCodeSummarizerEnvironment(from: [
            "CMUX_WORKSPACE_ID": "workspace",
            "OPENCODE_PERMISSION": "{\"*\":\"allow\"}",
            "OPENCODE_PROJECT_CONFIG": "/tmp/project/opencode.json",
            "OPENCODE_CONFIG": "/tmp/user/opencode.json",
            "OPENAI_API_KEY": "provider-secret",
            "PATH": "/usr/bin"
        ])

        #expect(environment["CMUX_WORKSPACE_ID"] == nil)
        #expect(environment["OPENCODE_PERMISSION"] == #"{"*":"deny"}"#)
        #expect(environment["OPENCODE_DISABLE_PROJECT_CONFIG"] == "1")
        #expect(environment["OPENCODE_PURE"] == "1")
        #expect(environment["OPENAI_API_KEY"] == "provider-secret")
        #expect(environment["OPENCODE_PROJECT_CONFIG"] == nil)
        #expect(environment["OPENCODE_CONFIG"] == nil)

        let permissionData = try #require(environment["OPENCODE_PERMISSION"]?.data(using: .utf8))
        let permission = try JSONSerialization.jsonObject(with: permissionData) as? [String: String]
        #expect(permission?["*"] == "deny")
    }
}
