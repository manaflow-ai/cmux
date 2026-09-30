import Testing

struct CodexAutoNamingArgumentsTests {
    @Test func disablesFeaturesAndForwardsSelectedProviderAndModel() {
        let args = CodexAutoNamingArguments.build(configToml: """
        model = "gpt-5-codex"
        model_provider = "subrouter"
        [model_providers.subrouter]
        name = "Subrouter"
        base_url = "http://127.0.0.1:31415/v1"
        experimental_bearer_token = "secret"
        [model_providers.subrouter.http_headers]
        X-Subrouter-Agent = "sr"
        [profiles.default]
        model = "ignored"
        """)
        let overrides = configOverrides(args)
        #expect(overrides.contains("web_search=\"disabled\""))
        #expect(!overrides.contains("web_search=false"))
        #expect(overrides.contains("model_provider=\"subrouter\""))
        #expect(overrides.contains("model=\"gpt-5-codex\""))
        #expect(overrides.contains("model_providers.subrouter.base_url=\"http://127.0.0.1:31415/v1\""))
        #expect(!overrides.contains(where: { $0.contains("experimental_bearer_token") }))
        #expect(overrides.contains("model_providers.subrouter.http_headers.X-Subrouter-Agent=\"sr\""))
        #expect(!overrides.contains(where: { $0.contains("profiles") }))
        #expect(args.contains("--ignore-user-config"))
        #expect(args.contains("--ignore-rules"))
    }

    @Test func temporaryConfigKeepsProviderCredentialsOutOfArguments() {
        let args = CodexAutoNamingArguments.build(configToml: """
        model = "gpt-5-codex"
        model_provider = "subrouter"
        [model_providers.subrouter]
        base_url = "http://127.0.0.1:31415/v1"
        experimental_bearer_token = "secret"
        [model_providers.subrouter.http_headers]
        Authorization = "Bearer secret"
        X-API-Key = "api-secret"
        """, usesTemporaryConfig: true)
        let overrides = configOverrides(args)
        #expect(overrides.contains("model_provider=\"subrouter\""))
        #expect(overrides.contains("model=\"gpt-5-codex\""))
        #expect(overrides.contains("model_providers.subrouter.base_url=\"http://127.0.0.1:31415/v1\""))
        #expect(!overrides.contains(where: {
            $0.contains("secret") || $0.contains("experimental_bearer_token") || $0.contains("api-secret")
        }))
        #expect(!args.joined(separator: " ").contains("secret"))
        #expect(!args.joined(separator: " ").contains("api-secret"))
        #expect(!args.contains("--ignore-user-config"))
    }

    @Test func keepsIsolationWhenUserConfigIsMissing() {
        let args = CodexAutoNamingArguments.build(configToml: nil)
        let overrides = configOverrides(args)
        #expect(overrides.contains("default_tools_enabled=false"))
        #expect(overrides.contains("tools={}"))
        #expect(overrides.contains("mcp_servers={}"))
        #expect(overrides.contains("web_search=\"disabled\""))
        #expect(!overrides.contains(where: { $0.hasPrefix("model_provider=") }))
    }

    private func configOverrides(_ args: [String]) -> [String] {
        zip(args, args.dropFirst()).compactMap { pair in
            pair.0 == "-c" ? pair.1 : nil
        }
    }
}
