use super::*;

fn home(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("acpmux-agent-files-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn env(home: &Path, extra: &[(&str, &str)]) -> BTreeMap<String, String> {
    let mut env = BTreeMap::from([("HOME".to_owned(), home.display().to_string())]);
    env.extend(extra.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())));
    env
}

fn write(path: &Path, body: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, body).unwrap();
}

fn auth(family: &str, program: &str, env: &BTreeMap<String, String>) -> Option<Auth> {
    file_auth(family, program, env).map(|(auth, _)| auth)
}

#[test]
fn nothing_found_is_unknown_not_signed_out() {
    let dir = home("none");
    let env = env(&dir, &[]);
    for (family, program) in [
        ("gemini", "gemini"),
        ("opencode", "opencode"),
        ("pi", "pi-acp"),
        ("cursor", "cursor-agent"),
        ("copilot", "copilot"),
        ("grok", "grok"),
        ("muse", "muse-acp"),
        ("antigravity", "agy_acp_server.par"),
        ("antigravity", "agy"),
        ("deepseek", "dsh"),
        ("prime", "prime-agent"),
        ("hermes", "hermes"),
    ] {
        assert_eq!(auth(family, program, &env), None, "{family}");
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_key_in_the_environment_is_a_sign_in_and_its_value_is_never_answered() {
    let dir = home("env");
    for (family, program, key) in [
        ("gemini", "gemini", "GEMINI_API_KEY"),
        ("cursor", "cursor-agent", "CURSOR_API_KEY"),
        ("copilot", "copilot", "COPILOT_GITHUB_TOKEN"),
        ("grok", "grok", "GROK_API_KEY"),
        ("grok", "grok", "XAI_API_KEY"),
        ("muse", "muse-acp", "META_API_KEY"),
        ("antigravity", "agy_acp_server.par", "GEMINI_API_KEY"),
        ("opencode", "opencode", "OPENCODE_AUTH_CONTENT"),
        ("deepseek", "dsh", "DEEPSEEK_API_KEY"),
        ("prime", "prime-agent", "PRIME_API_KEY"),
        ("hermes", "hermes", "OPENROUTER_API_KEY"),
        ("hermes", "hermes", "ANTHROPIC_TOKEN"),
    ] {
        let found = file_auth(family, program, &env(&dir, &[(key, "sk-secret-value")]));
        let (auth, detail) = found.unwrap_or_else(|| panic!("{family}"));
        assert_eq!(auth, Auth::SignedIn, "{family}");
        assert!(!detail.unwrap_or_default().contains("sk-secret"), "{family}");
    }
    assert_eq!(auth("muse", "muse-acp", &env(&dir, &[("META_API_KEY", "  ")])), None);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn login_files_prove_a_sign_in() {
    let dir = home("files");
    let env = env(&dir, &[]);
    write(&dir.join(".gemini/oauth_creds.json"), r#"{"refresh_token":"x"}"#);
    assert_eq!(auth("gemini", "gemini", &env), Some(Auth::SignedIn));
    write(&dir.join(".local/share/opencode/auth.json"), r#"{"anthropic":{"type":"oauth"}}"#);
    assert_eq!(auth("opencode", "opencode", &env), Some(Auth::SignedIn));
    write(&dir.join(".pi/agent/auth.json"), "{}");
    assert_eq!(auth("pi", "pi-acp", &env), None, "no provider is no sign-in proven");
    write(
        &dir.join(".pi/agent/auth.json"),
        r#"{"anthropic":{"type":"api_key"},"openai":{"type":"oauth"}}"#,
    );
    let (_, detail) = file_auth("pi", "pi-acp", &env).unwrap();
    assert!(detail.unwrap().ends_with("signs in 2 providers"));
    write(&dir.join(".config/cursor/auth.json"), r#"{"accessToken":"x"}"#);
    assert_eq!(auth("cursor", "cursor-agent", &env), Some(Auth::SignedIn));
    write(&dir.join(".copilot/config.json"), "// comment\n{\"loggedInUsers\": []}");
    assert_eq!(auth("copilot", "copilot", &env), None);
    write(
        &dir.join(".copilot/config.json"),
        "// comment\n{\"lastLoggedInUser\": {\"host\": \"https://github.com\", \"login\": \"a\"}}",
    );
    assert_eq!(auth("copilot", "copilot", &env), Some(Auth::SignedIn));
    write(&dir.join(".grok/user-settings.json"), r#"{"apiKey":""}"#);
    assert_eq!(auth("grok", "grok", &env), None);
    write(&dir.join(".grok/user-settings.json"), r#"{"apiKey":"xai-1"}"#);
    assert_eq!(auth("grok", "grok", &env), Some(Auth::SignedIn));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_grok_login_session_is_a_sign_in() {
    let dir = home("grok-login");
    let env = env(&dir, &[]);
    write(&dir.join(".grok/auth.json"), "{}");
    assert_eq!(auth("grok", "grok", &env), None, "an empty file proves nothing");
    write(&dir.join(".grok/auth.json"), r#"{"access_token":"x","refresh_token":"y"}"#);
    let (auth, detail) = file_auth("grok", "grok", &env).unwrap();
    assert_eq!(auth, Auth::SignedIn);
    assert!(detail.unwrap().ends_with(".grok/auth.json holds a sign-in"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn antigravity_token_files_prove_a_sign_in() {
    let dir = home("antigravity");
    let acp = env(&dir, &[]);
    write(&dir.join(".gemini/antigravity-acp/acp_token.json"), r#"{"refresh_token":"x"}"#);
    assert_eq!(auth("antigravity", "agy_acp_server.par", &acp), Some(Auth::SignedIn));
    let _ = std::fs::remove_dir_all(&dir);
    let dir = home("agy-cli");
    let cli = env(&dir, &[]);
    write(&dir.join(".gemini/antigravity-cli/antigravity-oauth-token"), "ya29.token");
    assert_eq!(auth("antigravity", "agy", &cli), Some(Auth::SignedIn));
    assert_eq!(auth("antigravity", "agy-wrapper", &cli), None);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn folder_variables_move_the_login_files() {
    let dir = home("vars");
    let elsewhere = dir.join("elsewhere");
    write(&elsewhere.join(".gemini/oauth_creds.json"), r#"{"refresh_token":"x"}"#);
    write(&elsewhere.join("auth.json"), r#"{"anthropic":{"type":"oauth"}}"#);
    write(&elsewhere.join("antigravity-acp/acp_token.json"), r#"{"refresh_token":"x"}"#);
    write(&elsewhere.join(".env"), "DEEPSEEK_API_KEY=k\nANTHROPIC_API_KEY=k\n");
    let moved = elsewhere.display().to_string();
    assert_eq!(auth("deepseek", "dsh", &env(&dir, &[])), None);
    assert_eq!(auth("deepseek", "dsh", &env(&dir, &[("DSH_HOME", &moved)])), Some(Auth::SignedIn));
    assert_eq!(
        auth("prime", "prime-agent", &env(&dir, &[("PRIME_AGENT_CODING_AGENT_DIR", &moved)])),
        Some(Auth::SignedIn)
    );
    assert_eq!(auth("hermes", "hermes", &env(&dir, &[])), None);
    assert_eq!(
        auth("hermes", "hermes", &env(&dir, &[("HERMES_HOME", &moved)])),
        Some(Auth::SignedIn)
    );
    assert_eq!(
        auth("hermes", "hermes", &env(&dir, &[("HERMES_HOME", "relative/home")])),
        None,
        "a relative home resolves from Hermes's own folder"
    );
    assert_eq!(auth("gemini", "gemini", &env(&dir, &[])), None);
    assert_eq!(
        auth("gemini", "gemini", &env(&dir, &[("GEMINI_CLI_HOME", &moved)])),
        Some(Auth::SignedIn)
    );
    assert_eq!(
        auth("pi", "pi-acp", &env(&dir, &[("PI_CODING_AGENT_DIR", &moved)])),
        Some(Auth::SignedIn)
    );
    assert_eq!(auth("grok", "grok", &env(&dir, &[("GROK_HOME", &moved)])), Some(Auth::SignedIn));
    assert_eq!(
        auth("antigravity", "agy_acp_server.par", &env(&dir, &[("GEMINI_HOME", &moved)])),
        Some(Auth::SignedIn)
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_home_env_file_key_is_a_sign_in() {
    let dir = home("dotenv");
    let env = env(&dir, &[]);
    write(&dir.join(".dsh/.env"), "# DEEPSEEK_API_KEY=sk-commented\nDEEPSEEK_API_KEY=\"\"\n");
    assert_eq!(auth("deepseek", "dsh", &env), None, "a comment or an empty value is no key");
    write(&dir.join(".dsh/.env"), "OTHER=1\nexport DEEPSEEK_API_KEY='sk-secret-value'\n");
    let (auth_found, detail) = file_auth("deepseek", "dsh", &env).unwrap();
    assert_eq!(auth_found, Auth::SignedIn);
    let detail = detail.unwrap();
    assert!(detail.ends_with(".dsh/.env sets DEEPSEEK_API_KEY"), "{detail}");
    assert!(!detail.contains("sk-secret"));
    write(&dir.join(".hermes/.env"), "OPENAI_BASE_URL=http://localhost:8000/v1\n");
    assert_eq!(auth("hermes", "hermes", &env), Some(Auth::SignedIn));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn prime_counts_only_model_providers() {
    let dir = home("prime");
    let env = env(&dir, &[]);
    let file = dir.join(".prime/agent/auth.json");
    write(&file, r#"{"serper":{"type":"api_key"},"mcp:linear":{"type":"oauth"}}"#);
    assert_eq!(auth("prime", "prime-agent", &env), None, "web search and MCP are no sign-in");
    write(&file, r#"{"serper":{"type":"api_key"},"prime-inference":{"type":"api_key"}}"#);
    let (_, detail) = file_auth("prime", "prime-agent", &env).unwrap();
    assert!(detail.unwrap().ends_with("signs in 1 provider"));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn hermes_signs_in_by_its_active_provider() {
    let dir = home("hermes");
    let env = env(&dir, &[]);
    let file = dir.join(".hermes/auth.json");
    write(&file, r#"{"version":1,"providers":{},"active_provider":"nous"}"#);
    assert_eq!(auth("hermes", "hermes", &env), None, "an active provider with no entry");
    write(
        &file,
        r#"{"version":1,"providers":{"nous":{"access_token":"x"}},"active_provider":null}"#,
    );
    assert_eq!(auth("hermes", "hermes", &env), None, "an entry nothing selects");
    write(
        &file,
        r#"{"version":1,"providers":{"nous":{"access_token":"x"}},"active_provider":"nous"}"#,
    );
    assert_eq!(auth("hermes", "hermes", &env), Some(Auth::SignedIn));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_wrapper_or_another_family_gets_no_answer() {
    let dir = home("wrapper");
    let gemini = env(&dir, &[("GEMINI_API_KEY", "k")]);
    assert_eq!(auth("gemini", "ssh", &gemini), None);
    assert_eq!(auth("gemini", "my-gemini-wrapper", &gemini), None);
    let cursor = env(&dir, &[("CURSOR_API_KEY", "k")]);
    assert_eq!(auth("cursor", "agent-wrapper", &cursor), None);
    assert_eq!(auth("cursor", "agent", &cursor), Some(Auth::SignedIn));
    assert_eq!(auth("cursor", "cursor-agent.exe", &cursor), Some(Auth::SignedIn));
    assert_eq!(auth("gemini", "gemini.cmd", &gemini), Some(Auth::SignedIn));
    assert_eq!(auth("gemini", "gemini-wrapper.exe", &gemini), None);
    assert_eq!(auth("aider", "aider", &gemini), None);
    let _ = std::fs::remove_dir_all(&dir);
}
