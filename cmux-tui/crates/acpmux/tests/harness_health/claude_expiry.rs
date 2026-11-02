use super::*;

/// File presence must not advertise an unusable OAuth login before the first send.
/// A Mac may still have a working keychain login; no keychain probe is allowed here.
#[tokio::test]
async fn claude_file_expiry_requires_unrefreshable_evidence_without_another_source() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("home");
    let user = root.path().join("profiles");
    let claude = home.join(".local/bin/claude");
    program(&home.join(".local/share/claude/versions/2.0.5"), &claude, "2.0.5 (Claude Code)");
    let expired = json!({"claudeAiOauth": {"accessToken": "synthetic-access", "expiresAt": 1}});
    let mut cases = vec![
        ("expired", expired.clone(), true),
        (
            "blank-refresh",
            json!({"claudeAiOauth": {"accessToken": "synthetic-access", "expiresAt": 1, "refreshToken": "  "}}),
            true,
        ),
        (
            "refreshable",
            json!({"claudeAiOauth": {"accessToken": "synthetic-access", "expiresAt": 1, "refreshToken": "synthetic-refresh"}}),
            false,
        ),
        (
            "future",
            json!({"claudeAiOauth": {"accessToken": "synthetic-access", "expiresAt": 9_000_000_000_000_u64}}),
            false,
        ),
        ("no-expiry", json!({"claudeAiOauth": {"accessToken": "synthetic-access"}}), false),
        ("no-access", json!({"claudeAiOauth": {"expiresAt": 1}}), false),
        ("unknown-format", json!({}), false),
        (
            "string-expiry",
            json!({"claudeAiOauth": {"accessToken": "synthetic-access", "expiresAt": "1"}}),
            false,
        ),
        (
            "malformed-refresh",
            json!({"claudeAiOauth": {"accessToken": "synthetic-access", "expiresAt": 1, "refreshToken": {}}}),
            false,
        ),
    ];
    for id in ["env", "settings", "helper", "api-key", "cloud"] {
        cases.push((id, expired.clone(), false));
    }
    for (id, credentials, _) in &cases {
        let dir = root.path().join(id);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(".credentials.json"), credentials.to_string()).unwrap();
        let settings = match *id {
            "settings" => json!({"env": {"ANTHROPIC_AUTH_TOKEN": "synthetic-settings"}}),
            "helper" => json!({"apiKeyHelper": "synthetic-helper"}),
            "cloud" => json!({"env": {"CLAUDE_CODE_USE_BEDROCK": true}}),
            _ => json!({}),
        };
        std::fs::write(dir.join("settings.json"), settings.to_string()).unwrap();
        if *id == "api-key" {
            std::fs::write(dir.join(".claude.json"), r#"{"primaryApiKey":"synthetic-key"}"#)
                .unwrap();
        }
        let extra = if *id == "env" { "ANTHROPIC_API_KEY = \"synthetic-env\"\n" } else { "" };
        profile(
            &user,
            &format!("claude-{id}"),
            &format!(
                "protocol = \"claude-stdio\"\ncommand = \"{}\"\n[env]\nCLAUDE_CONFIG_DIR = \"{}\"\n{extra}",
                claude.display(),
                dir.display()
            ),
        );
    }
    let hub = hub_for(root.path(), &user, &home);
    let mut app = Client::open(&hub, Origin::LocalApp);
    let reply = app.call(method::MUX_HARNESS_HEALTH, json!({})).await.unwrap();
    for (id, _, expired) in cases {
        let health = row(&reply, &format!("claude-{id}"));
        let expected = if expired && !cfg!(target_os = "macos") { "expired" } else { "signedIn" };
        assert_eq!(health["auth"], expected, "{id}: {health}");
        assert!(!health.to_string().contains("synthetic-"), "credential leaked: {id}");
    }
}
