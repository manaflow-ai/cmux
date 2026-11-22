use super::*;

fn found(sources: &[&str], env_keys: &[&str], endpoint: Option<&str>) -> Found {
    Found {
        sources: sources.iter().map(|s| (*s).to_owned()).collect(),
        env_keys: env_keys.iter().map(|s| (*s).to_owned()).collect(),
        endpoint: endpoint.map(str::to_owned),
        ..Found::default()
    }
}

fn origin(_: &str) -> String {
    "from its profile".into()
}

#[test]
fn the_sign_in_claude_code_uses_wins_and_names_its_kind_and_origin() {
    // The auth token outranks the subscription login and an API key, as in Claude Code.
    let f = found(
        &[
            "an API key (ANTHROPIC_API_KEY)",
            "a token (ANTHROPIC_AUTH_TOKEN)",
            "the sign-in saved in ~/.claude/.credentials.json",
        ],
        &["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"],
        None,
    );
    assert_eq!(auth_label(&f, origin), "Auth token (ANTHROPIC_AUTH_TOKEN, from its profile)");
    let sub = found(&["the sign-in saved in ~/.claude/.credentials.json"], &[], None);
    assert_eq!(auth_label(&sub, origin), "Claude subscription (~/.claude/.credentials.json)");
    let file = found(&["ANTHROPIC_API_KEY in ~/.claude/settings.json"], &[], None);
    assert_eq!(auth_label(&file, origin), "API key (ANTHROPIC_API_KEY in ~/.claude/settings.json)");
    let helper = found(
        &[
            "the sign-in saved in ~/.claude/.credentials.json",
            "apiKeyHelper in ~/.claude/settings.json",
        ],
        &[],
        None,
    );
    assert_eq!(
        auth_label(&helper, origin),
        "API key helper (apiKeyHelper in ~/.claude/settings.json)"
    );
    let saved = found(&["the API key saved in ~/.claude.json"], &[], None);
    assert_eq!(auth_label(&saved, origin), "API key saved by /login (~/.claude.json)");
    let bedrock = found(
        &["Amazon Bedrock (CLAUDE_CODE_USE_BEDROCK)", "an API key (ANTHROPIC_API_KEY)"],
        &["CLAUDE_CODE_USE_BEDROCK", "ANTHROPIC_API_KEY"],
        None,
    );
    assert_eq!(
        auth_label(&bedrock, origin),
        "Amazon Bedrock (CLAUDE_CODE_USE_BEDROCK, from its profile)"
    );
}

#[test]
fn no_sign_in_is_said_plainly() {
    let want = if cfg!(target_os = "macos") {
        "Claude subscription (keychain)"
    } else {
        "No sign-in found"
    };
    assert_eq!(auth_label(&Found::default(), origin), want);
}

#[test]
fn the_route_is_its_name_its_gateway_or_direct() {
    let none = Found::default();
    assert_eq!(route_label(&none, None, None), "Direct (Anthropic)");
    let named = found(&[], &[], Some("router.example:443"));
    assert_eq!(route_label(&named, Some("Team router"), None), "Team router (router.example:443)");
    let sr2 = found(&[], &[], Some("sr2-gateway.tail:4016"));
    assert_eq!(
        route_label(&sr2, None, Some("http://sr2-gateway.tail:4016")),
        "SR2 gateway (sr2-gateway.tail:4016)"
    );
    let sub = found(&[], &[], Some("subrouter.example"));
    assert_eq!(
        route_label(&sub, None, Some("https://subrouter.example")),
        "Subrouter (subrouter.example)"
    );
    let api = found(&[], &[], Some("api.anthropic.com"));
    assert_eq!(
        route_label(&api, None, Some("https://api.anthropic.com")),
        "Direct (api.anthropic.com)"
    );
    let custom = found(&[], &[], Some("llm.example:8080"));
    assert_eq!(
        route_label(&custom, None, Some("http://llm.example:8080/v1")),
        "Custom endpoint (llm.example:8080)"
    );
    let vertex = found(&[], &["CLAUDE_CODE_USE_VERTEX"], None);
    assert_eq!(route_label(&vertex, None, None), "Google Vertex AI");
}

#[test]
fn a_launcher_brings_its_own_sign_in_and_route() {
    let argv = |words: &[&str]| words.iter().map(|w| (*w).to_owned()).collect::<Vec<_>>();
    assert_eq!(
        launcher(&argv(&["/usr/local/bin/sr2", "claude"])),
        Some(("SR2 token (sr2 claude)", "SR2 (sr2 claude)"))
    );
    assert_eq!(
        launcher(&argv(&["sr", "claude", "proxy"])),
        Some(("Subrouter account pool (sr claude proxy)", "Subrouter (sr claude proxy)"))
    );
    assert_eq!(launcher(&argv(&["claude"])), None);
}

#[test]
fn settings_are_the_files_that_exist_and_the_autocompact_window() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home/.claude");
    let cwd = dir.path().join("project");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(cwd.join(".claude")).unwrap();
    std::fs::write(home.join("settings.json"), "{}").unwrap();
    std::fs::write(cwd.join(".claude/settings.json"), "{}").unwrap();
    let got = settings_in_force(&home, &cwd, Some("400000"));
    assert!(got.iter().any(|s| s.ends_with("home/.claude/settings.json")), "{got:?}");
    assert!(got.iter().any(|s| s.ends_with("project/.claude/settings.json")), "{got:?}");
    assert!(!got.iter().any(|s| s.ends_with("settings.local.json")), "{got:?}");
    assert_eq!(got.last().map(String::as_str), Some("autocompact at 400K"));
    assert!(!settings_in_force(&home, &cwd, None).iter().any(|s| s.starts_with("autocompact")));
}

#[test]
fn plan_limits_apply_to_a_subscription_or_a_router_only() {
    assert!(has_plan_limits(
        "Claude subscription (~/.claude/.credentials.json)",
        "Direct (Anthropic)"
    ));
    assert!(has_plan_limits(
        "Claude OAuth token (CLAUDE_CODE_OAUTH_TOKEN, from its profile)",
        "Direct (Anthropic)"
    ));
    assert!(has_plan_limits(
        "Auth token (ANTHROPIC_AUTH_TOKEN, from its profile)",
        "SR2 gateway (sr2-gateway:4016)"
    ));
    assert!(!has_plan_limits(
        "API key (ANTHROPIC_API_KEY, from the environment)",
        "Direct (Anthropic)"
    ));
    assert!(!has_plan_limits(
        "Amazon Bedrock (CLAUDE_CODE_USE_BEDROCK, from its profile)",
        "Amazon Bedrock"
    ));
}

#[test]
fn a_path_inside_a_source_never_ranks_it() {
    // "aws" in a home path is not an AWS credential helper: the OAuth token still wins.
    let f = found(
        &[
            "the sign-in saved in ~/laws/.claude/.credentials.json",
            "a sign-in token (CLAUDE_CODE_OAUTH_TOKEN)",
        ],
        &["CLAUDE_CODE_OAUTH_TOKEN"],
        None,
    );
    assert_eq!(
        auth_label(&f, origin),
        "Claude OAuth token (CLAUDE_CODE_OAUTH_TOKEN, from its profile)"
    );
}
