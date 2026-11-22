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
        // Host inventory has no project directory, so a known expired file cannot exclude
        // a working project credential. Only the session-scoped check can be conclusive.
        let expected = if expired && !cfg!(target_os = "macos") { "unknown" } else { "signedIn" };
        assert_eq!(health["auth"], expected, "{id}: {health}");
        assert!(!health.to_string().contains("synthetic-"), "credential leaked: {id}");
    }
}

#[test]
fn claude_file_expiry_checks_project_sources_before_a_conclusive_verdict() {
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("claude-home");
    let project = root.path().join("project");
    let nested = project.join("nested");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(project.join(".claude")).unwrap();
    std::fs::create_dir_all(&nested).unwrap();
    let alias = root.path().join("linked-project");
    std::os::unix::fs::symlink(&nested, &alias).unwrap();
    std::fs::write(
        home.join(".credentials.json"),
        r#"{"claudeAiOauth":{"accessToken":"synthetic-access","expiresAt":1}}"#,
    )
    .unwrap();
    let env = std::collections::BTreeMap::from([
        ("CLAUDE_CONFIG_DIR".to_owned(), home.display().to_string()),
        ("HOME".to_owned(), root.path().display().to_string()),
    ]);
    let scoped = || acpmux::claude_auth::find_in(&env, &nested);
    let found = scoped();
    assert!(found.credential_sources_complete);
    assert_eq!(found.expired_file_login, !cfg!(target_os = "macos"));
    assert!(!acpmux::claude_auth::find(&env).credential_sources_complete);
    for file in ["settings.json", "settings.local.json"] {
        let path = project.join(".claude").join(file);
        for contents in [
            r#"{"env":{"ANTHROPIC_API_KEY":"synthetic-project"}}"#,
            r#"{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"synthetic-project"}}"#,
            r#"{"apiKeyHelper":"never-execute-this-helper"}"#,
            r#"{"env":{"CLAUDE_CODE_USE_VERTEX":true}}"#,
        ] {
            std::fs::write(&path, contents).unwrap();
            let found = scoped();
            assert!(found.credential_sources_complete);
            assert!(!found.expired_file_login, "{file}: {contents}");
            assert!(!acpmux::claude_auth::find_in(&env, &alias).expired_file_login);
            assert!(!format!("{found:?}").contains("synthetic-"));
        }
        std::fs::write(&path, "invalid JSON").unwrap();
        assert!(!scoped().credential_sources_complete);
        std::fs::remove_file(&path).unwrap();
        // A path that cannot be read as a file must not be assumed absent.
        std::fs::create_dir(&path).unwrap();
        assert!(!scoped().credential_sources_complete);
        std::fs::remove_dir(&path).unwrap();
    }
    std::fs::write(home.join(".claude.json"), "invalid JSON").unwrap();
    assert!(!scoped().credential_sources_complete);
    assert!(!acpmux::claude_auth::find_in(&env, Path::new("relative")).credential_sources_complete);
}
