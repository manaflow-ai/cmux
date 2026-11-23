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
    assert_eq!(report["profiles"], json!([]));
    let mode = curated_row(&report, "permissions.defaultMode");
    assert_eq!(mode["value"], "plan");
    assert_eq!(mode["scope"], "user");
    assert_eq!(mode["writableScopes"], json!(["user", "project", "local"]));
    assert_eq!(curated_row(&report, "effortLevel")["value"], Value::Null);
}

#[test]
fn secret_names_are_masked_but_their_limits_and_stores_are_not() {
    let key = |path: &str| path.split('.').map(str::to_owned).collect::<Vec<_>>();
    for masked in [
        "env.DEBUG",
        "github_token",
        "api_key",
        "mcp_servers.x.bearer_token_env_var",
        "shell_environment_policy.set.DATABASE_URL",
        "profiles.work.shell_environment_policy.set.CMUXPROBE_CODEX_PLAIN_VAR",
    ] {
        assert!(secret(&key(masked)), "{masked} is masked");
    }
    for shown in [
        "model_auto_compact_token_limit",
        "cli_auth_credentials_store",
        "model",
        "shell_environment_policy.inherit",
    ] {
        assert!(!secret(&key(shown)), "{shown} is shown");
    }
}

#[test]
fn claude_set_and_unset_round_trip_byte_for_byte_elsewhere() {
    let f = fixture();
    let path = f.ctx.homes.claude_settings();
    fs::write(&path, USER_SETTINGS).unwrap();
    let written = apply(&f.ctx, Agent::Claude, "model", Some("haiku"), None).unwrap();
    assert_eq!(written.path, path);
    assert_eq!(
        fs::read_to_string(f.ctx.homes.edits.backup_path(&fs::canonicalize(&path).unwrap()))
            .unwrap(),
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
    let no_cwd = Context { cwd: None, ..f.ctx };
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
fn codex_shell_environment_policy_set_is_masked_like_env() {
    let f = fixture();
    fs::write(
        f.ctx.homes.codex_config(),
        "[shell_environment_policy]\ninherit = \"core\"\nset = { PLAIN = \"inline-secret-3\" }\n",
    )
    .unwrap();
    fs::write(
        f.ctx.homes.codex.join("work.config.toml"),
        "[shell_environment_policy.set]\nDATABASE_URL = \"postgres://u:pw-secret-4@h/db\"\n",
    )
    .unwrap();
    let report = report(&f.ctx, Agent::Codex);
    let text = report.to_string();
    assert!(!text.contains("inline-secret-3") && !text.contains("pw-secret-4"), "{text}");
    assert_eq!(entry(&report, "shell_environment_policy.inherit")["display"], "core");
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

#[test]
fn claude_flags_a_settings_file_with_comments_as_ignored() {
    // Claude Code 2.1.322 ignores a settings.json that is not strict JSON.
    let f = fixture();
    let path = f.ctx.homes.claude_settings();
    let text = "{\n  // mine\n  \"model\": \"opus\",\n}\n";
    fs::write(&path, text).unwrap();
    let report = report(&f.ctx, Agent::Claude);
    let model = entry(&report, "model");
    assert!(model["inactive"].as_str().unwrap().contains("ignores this file"));
    assert_eq!(curated_row(&report, "model")["value"], Value::Null);
    assert_eq!(
        apply(&f.ctx, Agent::Claude, "model", Some("haiku"), None).unwrap_err().code,
        "agent_config.parse"
    );
    assert_eq!(fs::read_to_string(&path).unwrap(), text);
}

/// Backups hold the file verbatim, credentials in `env` included, so a project's backups must
/// never land in the repo tree where `git add -A` stages them.
#[test]
fn project_backups_stay_out_of_the_repo_tree() {
    let f = fixture();
    let claude_dir = f.project.join(".claude");
    fs::create_dir_all(&claude_dir).unwrap();
    let local = claude_dir.join("settings.local.json");
    let original = "{\"env\": {\"ANTHROPIC_API_KEY\": \"sk-secret-7\"}}\n";
    fs::write(&local, original).unwrap();
    let written = apply(&f.ctx, Agent::Claude, "model", Some("opus"), Some("local")).unwrap();
    apply(&f.ctx, Agent::Claude, "model", Some("haiku"), Some("local")).unwrap();
    let backup = written.backup.expect("an existing file is backed up");
    let project = fs::canonicalize(&f.project).unwrap();
    assert!(
        !backup.starts_with(&f.project) && !backup.starts_with(&project),
        "backup {} is inside the project",
        backup.display()
    );
    assert_eq!(fs::read_to_string(&backup).unwrap(), original);
    // Nothing but the settings file itself is left in the project.
    let mut names: Vec<String> = fs::read_dir(&claude_dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    assert_eq!(names, vec!["settings.local.json".to_owned()]);
    let mut root: Vec<String> = fs::read_dir(&f.project)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    root.sort();
    assert_eq!(root, vec![".claude".to_owned(), ".git".to_owned(), "src".to_owned()]);
    // A trusted Codex project's config leaves nothing beside it either (backups, lock files).
    let trust =
        format!("[projects.{:?}]\ntrust_level = \"trusted\"\n", f.project.display().to_string());
    fs::write(f.ctx.homes.codex_config(), trust).unwrap();
    fs::create_dir_all(f.project.join(".codex")).unwrap();
    fs::write(f.project.join(".codex/config.toml"), "model = \"a\"\n").unwrap();
    apply(&f.ctx, Agent::Codex, "model", Some("b"), Some("project")).unwrap();
    let codex: Vec<String> = fs::read_dir(f.project.join(".codex"))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(codex, vec!["config.toml".to_owned()]);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mode = |p: &Path| fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&backup), 0o600);
        assert_eq!(mode(backup.parent().unwrap()), 0o700);
    }
}

/// A bearer token in an MCP server URL's query string, or a user:password in its authority, never
/// reaches the report; the scheme, host and path stay readable.
#[test]
fn codex_mcp_url_credentials_are_redacted() {
    let f = fixture();
    fs::write(
        f.ctx.homes.codex_config(),
        "[mcp_servers.remote]\nurl = \"https://me:pw-secret-5@mcp.example.com/sse?token=tok-secret-6&mode=fast#frag-secret-8\"\n\n[mcp_servers.plain]\nurl = \"https://mcp.example.com/plain\"\n",
    )
    .unwrap();
    let report = report(&f.ctx, Agent::Codex);
    let text = report.to_string();
    for secret in ["pw-secret-5", "tok-secret-6", "frag-secret-8", "me:"] {
        assert!(!text.contains(secret), "{secret} leaked: {text}");
    }
    let url = entry(&report, "mcp_servers.remote.url")["display"].as_str().unwrap().to_owned();
    assert!(url.starts_with("https://"), "{url}");
    assert!(url.contains("mcp.example.com/sse?token="), "{url}");
    assert!(url.contains("mode="), "{url}");
    assert_eq!(entry(&report, "mcp_servers.plain.url")["display"], "https://mcp.example.com/plain");
}

/// A Settings save and a CLI edit of different keys at the same time both survive.
#[test]
fn concurrent_claude_edits_of_different_keys_both_survive() {
    let f = fixture();
    let path = f.ctx.homes.claude_settings();
    fs::write(&path, "{}\n").unwrap();
    for round in 0..60 {
        let barrier = std::sync::Barrier::new(2);
        let (model, style) = (format!("model-{round}"), format!("style-{round}"));
        std::thread::scope(|s| {
            s.spawn(|| {
                barrier.wait();
                apply(&f.ctx, Agent::Claude, "model", Some(&model), None).unwrap();
            });
            s.spawn(|| {
                barrier.wait();
                apply(&f.ctx, Agent::Claude, "outputStyle", Some(&style), None).unwrap();
            });
        });
        let parsed = cmux_config::jsonc::parse(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(parsed["model"], json!(model), "round {round}: {parsed}");
        assert_eq!(parsed["outputStyle"], json!(style), "round {round}: {parsed}");
    }
}

/// Claude Code 2.1.322's statusLine schema needs `type: "command"` and `command`, and it skips a
/// settings file with a schema error entirely, so unsetting the command takes the object
/// (padding included): a `statusLine` left with only `padding` would switch off every setting in
/// the file. The file stays valid and every other key stays.
#[test]
fn unset_status_line_command_never_leaves_an_invalid_status_line() {
    let f = fixture();
    let path = f.ctx.homes.claude_settings();
    let text = "{\n  \"model\": \"opus\",\n  \"statusLine\": {\"type\": \"command\", \"command\": \"x.sh\", \"padding\": 2}\n}\n";
    fs::write(&path, text).unwrap();
    apply(&f.ctx, Agent::Claude, "statusLine.command", None, None).unwrap();
    let parsed: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(parsed, json!({"model": "opus"}));
}

#[test]
fn claude_env_set_and_unset_edit_only_that_variable_and_stay_masked() {
    let f = fixture();
    let path = f.ctx.homes.claude_settings();
    fs::write(&path, USER_SETTINGS).unwrap();
    let written = apply_env(&f.ctx, Agent::Claude, "MY_FLAG", Some("on air"), None).unwrap();
    assert_eq!(written.key, "env.MY_FLAG");
    assert_eq!(written.scope, "user");
    assert!(!written.json().to_string().contains("on air"));
    let text = fs::read_to_string(&path).unwrap();
    let value: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(value["env"]["MY_FLAG"], "on air");
    assert_eq!(value["env"]["ANTHROPIC_API_KEY"], "sk-secret-1");
    assert_eq!(value["hooks"]["Stop"][0]["hooks"][0]["command"], "x");
    let report = report(&f.ctx, Agent::Claude);
    assert_eq!(report["envTable"], "env");
    let names: Vec<&str> =
        report["env"].as_array().unwrap().iter().map(|e| e["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["ANTHROPIC_API_KEY", "DEBUG", "MY_FLAG"]);
    assert!(!report.to_string().contains("on air"));
    assert_eq!(entry(&report, "env.MY_FLAG")["display"], MASK);
    // Changing it rewrites only its value; unsetting puts the file back byte for byte.
    apply_env(&f.ctx, Agent::Claude, "MY_FLAG", Some("off"), None).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&fs::read_to_string(&path).unwrap()).unwrap()["env"]["MY_FLAG"],
        "off"
    );
    apply_env(&f.ctx, Agent::Claude, "MY_FLAG", None, None).unwrap();
    let parsed = |text: &str| serde_json::from_str::<Value>(text).unwrap();
    let after_unset = fs::read_to_string(&path).unwrap();
    assert_eq!(parsed(&after_unset), parsed(USER_SETTINGS));
    // Unsetting what is not there writes nothing.
    apply_env(&f.ctx, Agent::Claude, "NOPE", None, None).unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), after_unset);
}

#[test]
fn claude_env_last_variable_out_takes_the_empty_env_and_scopes_write_the_project() {
    let f = fixture();
    apply_env(&f.ctx, Agent::Claude, "ONLY", Some("1"), Some("local")).unwrap();
    let local = f.project.join(".claude/settings.local.json");
    let value: Value = serde_json::from_str(&fs::read_to_string(&local).unwrap()).unwrap();
    assert_eq!(value, json!({"env": {"ONLY": "1"}}));
    let report = report(&f.ctx, Agent::Claude);
    assert_eq!(report["env"][0]["scope"], "local");
    apply_env(&f.ctx, Agent::Claude, "ONLY", None, Some("local")).unwrap();
    let value: Value = serde_json::from_str(&fs::read_to_string(&local).unwrap()).unwrap();
    assert_eq!(value, json!({}));
}

#[test]
fn env_refuses_bad_names_and_multiline_values() {
    let f = fixture();
    for name in ["", "1ABC", "A-B", "A.B", "A B", "\u{e9}"] {
        let error = apply_env(&f.ctx, Agent::Claude, name, Some("1"), None).unwrap_err();
        assert_eq!(error.code, "agent_config.invalid_name", "{name:?}");
    }
    let error = apply_env(&f.ctx, Agent::Codex, "OK", Some("a\nb"), None).unwrap_err();
    assert_eq!(error.code, "agent_config.invalid_value");
    assert!(apply_env(&f.ctx, Agent::Claude, "_ok_1", Some(""), None).is_ok());
    assert!(!f.ctx.homes.codex_config().exists());
}

#[test]
fn codex_env_set_writes_shell_environment_policy_set_in_place() {
    let f = fixture();
    let path = f.ctx.homes.codex_config();
    let original = "# mine\nmodel = \"o3\"\n\n[shell_environment_policy]\ninherit = \"core\" # keep\n\n[mcp_servers.x]\ncommand = \"x\"\n";
    fs::write(&path, original).unwrap();
    let written = apply_env(&f.ctx, Agent::Codex, "RUST_LOG", Some("debug"), None).unwrap();
    assert_eq!(written.key, "shell_environment_policy.set.RUST_LOG");
    let text = fs::read_to_string(&path).unwrap();
    assert!(text.contains("inherit = \"core\" # keep"), "{text}");
    assert!(text.contains("[shell_environment_policy.set]\nRUST_LOG = \"debug\""), "{text}");
    let doc: toml_edit::DocumentMut = text.parse().unwrap();
    assert_eq!(doc["shell_environment_policy"]["set"]["RUST_LOG"].as_str(), Some("debug"));
    assert_eq!(doc["mcp_servers"]["x"]["command"].as_str(), Some("x"));
    let report = report(&f.ctx, Agent::Codex);
    assert_eq!(report["envTable"], "shell_environment_policy.set");
    assert_eq!(
        report["env"],
        json!([{"name": "RUST_LOG", "value": MASK, "scope": "user", "path": path.display().to_string()}])
    );
    assert!(!report.to_string().contains("debug"));
    apply_env(&f.ctx, Agent::Codex, "RUST_LOG", None, None).unwrap();
    let text = fs::read_to_string(&path).unwrap();
    assert!(!text.contains("RUST_LOG") && !text.contains(".set]"), "{text}");
    assert!(text.contains("inherit = \"core\" # keep"));
}

#[test]
fn codex_env_set_creates_the_table_and_edits_an_inline_one() {
    let f = fixture();
    let path = f.ctx.homes.codex_config();
    apply_env(&f.ctx, Agent::Codex, "A", Some("1"), None).unwrap();
    let text = fs::read_to_string(&path).unwrap();
    assert_eq!(text, "[shell_environment_policy.set]\nA = \"1\"\n");
    fs::write(&path, "shell_environment_policy = { set = { B = \"2\" } }\n").unwrap();
    apply_env(&f.ctx, Agent::Codex, "C", Some("3"), None).unwrap();
    let doc: toml_edit::DocumentMut = fs::read_to_string(&path).unwrap().parse().unwrap();
    assert_eq!(doc["shell_environment_policy"]["set"]["B"].as_str(), Some("2"));
    assert_eq!(doc["shell_environment_policy"]["set"]["C"].as_str(), Some("3"));
    fs::write(&path, "shell_environment_policy = \"x\"\n").unwrap();
    assert_eq!(
        apply_env(&f.ctx, Agent::Codex, "D", Some("4"), None).unwrap_err().code,
        "agent_config.parse"
    );
}
