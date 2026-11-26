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
        #expect(!overrides.contains(where: { $0.contains("http_headers") }))
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
        // With a temporary CODEX_HOME, the provider definition is already
        // available in its mode-restricted config.toml. Do not duplicate it
        // on argv, where nested provider values could expose credentials.
        #expect(!overrides.contains("model_providers.subrouter.base_url=\"http://127.0.0.1:31415/v1\""))
        #expect(!overrides.contains(where: {
            $0.contains("secret") || $0.contains("experimental_bearer_token") || $0.contains("api-secret")
        }))
        #expect(!args.joined(separator: " ").contains("secret"))
        #expect(!args.joined(separator: " ").contains("api-secret"))
        #expect(!args.contains("--ignore-user-config"))
    }

    @Test func nonTemporaryConfigDropsInlineHeaderMaps() {
        let args = CodexAutoNamingArguments.build(configToml: """
        model = "gpt-5-codex"
        model_provider = "subrouter"
        [model_providers.subrouter]
        base_url = "http://127.0.0.1:31415/v1"
        http_headers = { Authorization = "Bearer secret", X-API-Key = "api-secret" }
        http_headers.X-Org-ID = "sensitive-value"
        http_headers . X-Org-ID = "sensitive-value"
        [model_providers.subrouter.http_headers]
        X-Subrouter-Agent = "sr"
        [model_providers.subrouter."http_headers"]
        X-Org-ID = "sensitive-value" # trailing comment
        [model_providers.subrouter-extra]
        base_url = "http://127.0.0.1:9999/v1"
        """)
        let overrides = configOverrides(args)
        #expect(overrides.contains("model_provider=\"subrouter\""))
        #expect(overrides.contains("model=\"gpt-5-codex\""))
        #expect(!overrides.contains(where: { $0.contains("http_headers") }))
        #expect(!overrides.contains(where: { $0.contains("subrouter-extra") }))
        #expect(!overrides.contains(where: { $0.contains("sensitive-value") }))
        #expect(!args.joined(separator: " ").contains("secret"))
        #expect(!args.joined(separator: " ").contains("api-secret"))
    }

    @Test func nonTemporaryConfigDropsHeaderSectionsWithTrailingComments() {
        let args = CodexAutoNamingArguments.build(configToml: """
        model = "gpt-5-codex"
        model_provider = "subrouter"
        [model_providers.subrouter.http_headers] # trailing comment
        Authorization = "Bearer sensitive-value"
        """)
        let overrides = configOverrides(args)
        #expect(!overrides.contains(where: { $0.contains("sensitive-value") }))
        #expect(!args.joined(separator: " ").contains("sensitive-value"))
    }

    @Test func nonTemporaryConfigIgnoresSectionsInsideMultilineStrings() {
        let args = CodexAutoNamingArguments.build(configToml: """
        model = "gpt-5-codex"
        model_provider = "subrouter"
        [model_providers.subrouter]
        description = \"\"\"
        [model_providers.subrouter.http_headers]
        Authorization = "Bearer sensitive-value"
        \"\"\"
        base_url = "http://127.0.0.1:31415/v1"
        """)
        let overrides = configOverrides(args)
        #expect(!overrides.contains(where: { $0.contains("sensitive-value") }))
        #expect(!args.joined(separator: " ").contains("sensitive-value"))
    }

    @Test func nonTemporaryConfigDropsUnicodeEscapedHeaderSections() {
        let args = CodexAutoNamingArguments.build(configToml: #"""
        model = "gpt-5-codex"
        model_provider = "subrouter"
        [model_providers.subrouter."\u0068ttp_headers"]
        Authorization = "Bearer sensitive-value"
        """#)
        let overrides = configOverrides(args)
        #expect(!overrides.contains(where: { $0.contains("sensitive-value") }))
        #expect(!args.joined(separator: " ").contains("sensitive-value"))
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
