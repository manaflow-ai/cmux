use super::*;

struct Fixture {
    _dir: tempfile::TempDir,
    ctx: Context,
    project: PathBuf,
}

/// A home with `.claude` and `.codex`, a git project under it, and managed files that do not exist.
fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let project = home.join("code/app");
    fs::create_dir_all(project.join(".git")).unwrap();
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::create_dir_all(home.join(".codex")).unwrap();
    let ctx = Context {
        homes: Homes::under(&home),
        cwd: Some(project.join("src")),
        claude_managed: dir.path().join("managed/managed-settings.json"),
        codex_managed: dir.path().join("managed/managed_config.toml"),
        codex_system: dir.path().join("managed/config.toml"),
    };
    fs::create_dir_all(project.join("src")).unwrap();
    Fixture { _dir: dir, ctx, project }
}

fn entry<'a>(report: &'a Value, key: &str) -> &'a Value {
    report["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["key"] == key)
        .unwrap_or_else(|| panic!("no {key}"))
}

fn curated_row<'a>(report: &'a Value, key: &str) -> &'a Value {
    report["curated"].as_array().unwrap().iter().find(|e| e["key"] == key).unwrap()
}

const USER_SETTINGS: &str = r#"{
  // a comment Claude Code tolerates
  "theme": "dark",
  "model": "opus",
  "env": {"ANTHROPIC_API_KEY": "sk-secret-1", "DEBUG": "1"},
  "permissions": {"allow": ["Bash(ls)"], "defaultMode": "plan"},
  "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "x"}]}]},
  "zUnknown": {"nested": true}
}
"#;

#[test]
fn claude_report_shows_every_key_with_its_scope_and_masks_env() {
    let f = fixture();
    fs::write(f.ctx.homes.claude_settings(), USER_SETTINGS).unwrap();
    fs::create_dir_all(f.project.join(".claude")).unwrap();
    fs::write(
        f.project.join(".claude/settings.json"),
        r#"{"model": "sonnet", "permissions": {"allow": ["Read"]}}"#,
    )
    .unwrap();
    let report = report(&f.ctx, Agent::Claude);
    let model = entry(&report, "model");
    assert_eq!(model["display"], "sonnet");
    assert_eq!(model["scope"], "project");
    assert_eq!(model["overridden"], json!([{"scope": "user", "display": "opus"}]));
    assert_eq!(entry(&report, "theme")["scope"], "user");
    assert_eq!(entry(&report, "permissions.allow")["merged"], true);
    assert_eq!(entry(&report, "hooks.Stop")["display"], "1 item");
    assert_eq!(entry(&report, "zUnknown.nested")["display"], "true");
    let secret = entry(&report, "env.ANTHROPIC_API_KEY");
    assert_eq!(secret["display"], MASK);
    assert_eq!(secret["masked"], true);
    assert_eq!(entry(&report, "env.DEBUG")["display"], MASK);
    assert!(!report.to_string().contains("sk-secret-1"));
    // Every leaf on disk is shown: 8 user leaves and 2 project leaves.
    assert_eq!(report["keysOnDisk"], 10);
    assert_eq!(report["keysShown"], 10);
    let mode = curated_row(&report, "permissions.defaultMode");
    assert_eq!(mode["value"], "plan");
    assert_eq!(mode["scope"], "user");
    assert_eq!(mode["writableScopes"], json!(["user", "project", "local"]));
    assert_eq!(curated_row(&report, "effortLevel")["value"], Value::Null);
}

#[test]
fn claude_set_and_unset_round_trip_byte_for_byte_elsewhere() {
    let f = fixture();
    let path = f.ctx.homes.claude_settings();
    fs::write(&path, USER_SETTINGS).unwrap();
    let written = apply(&f.ctx, Agent::Claude, "model", Some("haiku"), None).unwrap();
    assert_eq!(written.path, path);
    assert_eq!(
        fs::read_to_string(write::backup_path(&fs::canonicalize(&path).unwrap())).unwrap(),
        USER_SETTINGS
    );
    let after = fs::read_to_string(&path).unwrap();
    assert_eq!(after, USER_SETTINGS.replace(r#""model": "opus""#, r#""model": "haiku""#));
    // A new nested key, then removing both: the file is what it was, comment and order included.
    apply(&f.ctx, Agent::Claude, "effortLevel", Some("high"), None).unwrap();
    apply(&f.ctx, Agent::Claude, "effortLevel", None, None).unwrap();
    apply(&f.ctx, Agent::Claude, "model", Some("opus"), None).unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), USER_SETTINGS);
    // The status line is an object; setting its command writes its type too, unset takes both.
    apply(&f.ctx, Agent::Claude, "statusLine.command", Some("~/bin/status.sh"), None).unwrap();
    let parsed = cmux_config::jsonc::parse(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(parsed["statusLine"], json!({"command": "~/bin/status.sh", "type": "command"}));
    apply(&f.ctx, Agent::Claude, "statusLine.command", None, None).unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), USER_SETTINGS);
}

#[test]
fn claude_project_and_local_scopes_write_the_project_root() {
    let f = fixture();
    apply(&f.ctx, Agent::Claude, "permissions.defaultMode", Some("acceptEdits"), Some("local"))
        .unwrap();
    let local = f.project.join(".claude/settings.local.json");
    let parsed = cmux_config::jsonc::parse(&fs::read_to_string(&local).unwrap()).unwrap();
    assert_eq!(parsed, json!({"permissions": {"defaultMode": "acceptEdits"}}));
    let report = report(&f.ctx, Agent::Claude);
    assert_eq!(curated_row(&report, "permissions.defaultMode")["scope"], "local");
    // A repo cannot grant auto; a value outside the choices is refused.
    assert_eq!(
        apply(&f.ctx, Agent::Claude, "permissions.defaultMode", Some("auto"), Some("project"))
            .unwrap_err()
            .code,
        "agent_config.invalid_value"
    );
    assert_eq!(
        apply(&f.ctx, Agent::Claude, "theme", Some("neon"), None).unwrap_err().code,
        "agent_config.invalid_value"
    );
    assert_eq!(
        apply(&f.ctx, Agent::Claude, "hooks", Some("x"), None).unwrap_err().code,
        "agent_config.unknown_key"
    );
    let no_cwd = Context { cwd: None, ..f.ctx.clone() };
    assert_eq!(
        apply(&no_cwd, Agent::Claude, "model", Some("opus"), Some("project")).unwrap_err().code,
        "agent_config.scope"
    );
}

#[test]
fn claude_refuses_to_write_over_a_broken_file() {
    let f = fixture();
    let path = f.ctx.homes.claude_settings();
    fs::write(&path, "{ not json").unwrap();
    assert_eq!(
        apply(&f.ctx, Agent::Claude, "model", Some("opus"), None).unwrap_err().code,
        "agent_config.parse"
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), "{ not json");
    let report = report(&f.ctx, Agent::Claude);
    let user = report["files"].as_array().unwrap().iter().find(|f| f["scope"] == "user").unwrap();
    assert!(user["error"].as_str().unwrap().contains("not valid JSON"));
}

const CODEX_CONFIG: &str = r#"# my codex config
model = "gpt-5.1" # the default
model_reasoning_effort = "low"

[features]
chronicle = true

[mcp_servers.linear]
command = "npx"
env = { LINEAR_TOKEN = "lin-secret-2" }

[projects."/somewhere/else"]
trust_level = "trusted"
"#;

#[test]
fn codex_report_lists_profiles_and_masks_server_env() {
    let f = fixture();
    fs::write(f.ctx.homes.codex_config(), CODEX_CONFIG).unwrap();
    fs::write(f.ctx.homes.codex.join("fast.config.toml"), "model = \"gpt-5.1-codex-mini\"\n")
        .unwrap();
    let report = report(&f.ctx, Agent::Codex);
    assert_eq!(entry(&report, "model")["display"], "gpt-5.1");
    assert_eq!(entry(&report, "features.chronicle")["display"], "true");
    assert_eq!(entry(&report, "mcp_servers.linear.env.LINEAR_TOKEN")["display"], MASK);
    assert_eq!(entry(&report, "projects.\"/somewhere/else\".trust_level")["display"], "trusted");
    assert!(!report.to_string().contains("lin-secret-2"));
    assert_eq!(
        report["profiles"],
        json!([{"name": "fast", "path": f.ctx.homes.codex.join("fast.config.toml").display().to_string(), "keys": 1}])
    );
    assert_eq!(report["activeProfile"], Value::Null);
    let profile_model = report["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["key"] == "model" && e["scope"] == "profile:fast")
        .unwrap();
    assert!(profile_model["inactive"].as_str().unwrap().contains("--profile fast"));
    // The untrusted project has no project scope to write.
    assert_eq!(curated_row(&report, "model")["writableScopes"], json!(["user", "profile:fast"]));
    assert_eq!(report["keysOnDisk"], report["keysShown"]);
    assert_eq!(report["keysOnDisk"], 7);
}

#[test]
fn codex_set_keeps_comments_and_unknown_tables() {
    let f = fixture();
    let path = f.ctx.homes.codex_config();
    fs::write(&path, CODEX_CONFIG).unwrap();
    apply(&f.ctx, Agent::Codex, "model", Some("gpt-5.2"), None).unwrap();
    assert_eq!(
        fs::read_to_string(&path).unwrap(),
        CODEX_CONFIG.replace("\"gpt-5.1\"", "\"gpt-5.2\"")
    );
    apply(&f.ctx, Agent::Codex, "sandbox_mode", Some("read-only"), None).unwrap();
    let text = fs::read_to_string(&path).unwrap();
    assert!(text.contains("sandbox_mode = \"read-only\"\n\n[features]"), "{text}");
    apply(&f.ctx, Agent::Codex, "sandbox_mode", None, None).unwrap();
    apply(&f.ctx, Agent::Codex, "model", Some("gpt-5.1"), None).unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), CODEX_CONFIG);
    assert_eq!(
        apply(&f.ctx, Agent::Codex, "approval_policy", Some("sometimes"), None).unwrap_err().code,
        "agent_config.invalid_value"
    );
    // A profile scope writes NAME.config.toml.
    apply(&f.ctx, Agent::Codex, "model", Some("o3"), Some("profile:work")).unwrap();
    assert_eq!(
        fs::read_to_string(f.ctx.homes.codex.join("work.config.toml")).unwrap(),
        "model = \"o3\"\n"
    );
    assert_eq!(
        apply(&f.ctx, Agent::Codex, "model", Some("o3"), Some("profile:../x")).unwrap_err().code,
        "agent_config.scope"
    );
}

#[test]
fn codex_project_scope_needs_trust_and_legacy_profiles_are_reported() {
    let f = fixture();
    fs::create_dir_all(f.project.join(".codex")).unwrap();
    fs::write(f.project.join(".codex/config.toml"), "model = \"project-model\"\n").unwrap();
    fs::write(f.ctx.homes.codex_config(), "model = \"gpt-5.1\"\n").unwrap();
    let untrusted = report(&f.ctx, Agent::Codex);
    assert_eq!(curated_row(&untrusted, "model")["value"], "gpt-5.1");
    assert_eq!(
        apply(&f.ctx, Agent::Codex, "model", Some("x"), Some("project")).unwrap_err().code,
        "agent_config.scope"
    );
    let trust = format!(
        "model = \"gpt-5.1\"\nprofile = \"old\"\n\n[projects.{:?}]\ntrust_level = \"trusted\"\n",
        f.project.display().to_string()
    );
    fs::write(f.ctx.homes.codex_config(), trust).unwrap();
    let trusted = report(&f.ctx, Agent::Codex);
    assert_eq!(curated_row(&trusted, "model")["value"], "project-model");
    assert_eq!(curated_row(&trusted, "model")["scope"], "project");
    assert!(
        trusted["notes"].as_array().unwrap().iter().any(|n| n.as_str().unwrap().contains("legacy"))
    );
    apply(&f.ctx, Agent::Codex, "model", Some("p2"), Some("project")).unwrap();
    assert_eq!(
        fs::read_to_string(f.project.join(".codex/config.toml")).unwrap(),
        "model = \"p2\"\n"
    );
}
