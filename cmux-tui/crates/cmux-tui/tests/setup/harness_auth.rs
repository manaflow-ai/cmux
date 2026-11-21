//! Setup's recovery is scoped to the profile, and uncertainty is never a sign-out.
use super::*;

#[test]
fn cmux_setup_harness_auth_required_has_typed_profile_recovery() {
    let world = World::new("hauth");
    let id = "work's $(false) agent";
    let agent = world.bin.join("opencode");
    world.harness(&agent, "1.0.0");
    world.configure(json!({id: {"argv": [agent], "family": "opencode"}}));
    let before = world.acpmux_files();
    for report in [
        world.json(&["setup", "harness", id, "--dry-run"]),
        world.json(&["setup", "status"])["checks"][2].clone(),
    ] {
        let rows = report["harnesses"].as_array().unwrap();
        let row = rows.iter().find(|row| row["id"] == id).unwrap();
        assert_eq!(row["auth_status"], "signed_out", "{row}");
        assert_eq!(row["signed_in"], false);
        assert_eq!(row["state"], "needs_user");
        assert_eq!(row["recovery"], row["user_action"]);
        assert_eq!(report["user_action"], rows[0]["recovery"]);
        let command = row["recovery"]["command"].as_str().unwrap();
        // Execute only the argument parser with a fake cmux function: no login.
        let parsed = Command::new("/bin/sh")
            .args(["-c", &format!("cmux() {{ printf '%s\\n' \"$@\"; }}; {command}")])
            .output()
            .unwrap();
        assert!(parsed.status.success());
        assert_eq!(String::from_utf8(parsed.stdout).unwrap(), format!("harness\nlogin\n{id}\n"));
    }
    assert_eq!(world.acpmux_files(), before);
    assert!(!World::harness_log(&agent).contains("session/prompt"));
    World::sign_in(&agent);
    let ready = world.json(&["setup", "harness", id]);
    assert_eq!(ready["harnesses"][0]["auth_status"], "detected");
    assert_eq!(ready["harnesses"][0]["recovery"], Value::Null);
}

#[test]
fn cmux_setup_harness_auth_provider_missing_needs_diagnosis_not_oauth() {
    let world = World::new("hprovider");
    let agent = world.bin.join("router-codex-acp");
    world.harness(&agent, "1.0.0");
    let home = world.codex_home(
        "router",
        r#"model_provider = "router"
[model_providers.router]
env_key = "CMUX_SETUP_TEST_MISSING_KEY"
"#,
    );
    world.configure(json!({"work-codex": {"argv": [agent], "env": {"CODEX_HOME": home}}}));
    let report = world.json(&["setup", "harness", "work-codex"]);
    let row = &report["harnesses"][0];
    assert_eq!(row["auth_status"], "needs_action", "{row}");
    assert_eq!(row["signed_in"], Value::Null);
    assert_eq!(row["state"], "needs_user");
    assert_eq!(row["recovery"]["kind"], "check");
    assert_eq!(row["recovery"]["command"], "cmux harness doctor work-codex --no-prompt --json");
    assert!(row["auth_detail"].as_str().unwrap().contains("CMUX_SETUP_TEST_MISSING_KEY"));
    assert_eq!(World::harness_log(&agent), "");
}

#[test]
fn cmux_setup_harness_auth_protocol_failure_is_not_sign_out() {
    let world = World::new("hprotocol");
    let agent = world.bin.join("opencode");
    world.harness(&agent, "1.0.0");
    let body = std::fs::read_to_string(&agent)
        .unwrap()
        .replace("-32000", "-32601")
        .replace("Authentication required", "Method not found");
    World::executable(&agent, &body);
    world.configure(json!({"work-opencode": {"argv": [agent]}}));
    let report = world.json(&["setup", "harness", "work-opencode"]);
    let row = &report["harnesses"][0];
    assert_eq!(row["auth_status"], "needs_action", "{row}");
    assert_eq!(row["signed_in"], Value::Null);
    assert_eq!(row["recovery"]["kind"], "check");
    assert_eq!(row["recovery"]["command"], "cmux harness doctor work-opencode --no-prompt --json");
    assert!(row["auth_detail"].as_str().unwrap().contains("Method not found"));
}

#[test]
fn cmux_setup_harness_auth_claude_check_failure_retains_profile_login_and_respects_disabled_launches()
 {
    let world = World::new("hclaude");
    let agent = world.bin.join("claude");
    World::executable(&agent, "#!/bin/sh\necho 1.0.0\n");
    let profiles = world.home.join(".config/cmux/harnesses");
    std::fs::create_dir_all(&profiles).unwrap();
    std::fs::write(
        profiles.join("work-claude.toml"),
        format!(
            r#"schema = 1
id = "work-claude"
protocol = "claude-stdio"
command = {command:?}
[auth]
check = ["/usr/bin/false"]
login = "claude auth login"
"#,
            command = agent.to_string_lossy()
        ),
    )
    .unwrap();
    let report = world.json(&["setup", "harness", "work-claude"]);
    let row = &report["harnesses"][0];
    assert_eq!(row["auth_status"], "signed_out", "{row}");
    assert_eq!(row["recovery"]["command"], "cmux harness login work-claude");
    for (variable, value) in [("ACPMUX_AGENT_LAUNCH", "deny"), ("CMUX_AGENTS_DISABLED", "1")] {
        let output = world
            .command(&["setup", "harness", "work-claude"])
            .env(variable, value)
            .output()
            .unwrap();
        assert!(output.status.success());
        let report: Value = serde_json::from_slice(&output.stdout).unwrap();
        let row = &report["harnesses"][0];
        assert_eq!(row["auth_status"], "unknown", "{row}");
        assert_eq!(row["signed_in"], Value::Null);
        assert_eq!(row["state"], "ok");
        assert_eq!(row["recovery"], Value::Null);
        assert_eq!(row["auth_detail"], acpmux::launch_policy::DISABLED_MESSAGE);
    }
}

#[test]
fn cmux_setup_harness_auth_expired_credential_is_signed_out_with_login() {
    let world = World::new("hexpired");
    let agent = world.bin.join("claude");
    World::executable(&agent, "#!/bin/sh\necho 1.0.0\n");
    let check = world.bin.join("expired-check");
    World::executable(&check, "#!/bin/sh\necho 'OAuth token has expired'\nexit 1\n");
    let profiles = world.home.join(".config/cmux/harnesses");
    std::fs::create_dir_all(&profiles).unwrap();
    std::fs::write(
        profiles.join("work-claude.toml"),
        format!(
            r#"schema = 1
id = "work-claude"
protocol = "claude-stdio"
command = {command:?}
[auth]
check = [{check:?}]
login = "claude auth login"
"#,
            command = agent.to_string_lossy(),
            check = check.to_string_lossy()
        ),
    )
    .unwrap();
    let report = world.json(&["setup", "harness", "work-claude"]);
    let row = &report["harnesses"][0];
    assert_eq!(row["auth_status"], "signed_out", "{row}");
    assert_eq!(row["signed_in"], false);
    assert_eq!(row["state"], "needs_user");
    assert_eq!(row["recovery"]["kind"], "oauth");
    assert_eq!(row["recovery"]["command"], "cmux harness login work-claude");
}

#[test]
fn cmux_setup_harness_auth_timeout_is_not_sign_out() {
    let world = World::new("htimeout");
    let agent = world.bin.join("opencode");
    World::executable(
        &agent,
        "#!/bin/sh\n[ \"$1\" = --version ] && { echo 1.0.0; exit 0; }\nexec sleep 60\n",
    );
    world.configure(json!({"slow-opencode": {"argv": [agent]}}));
    let report = world.json(&["setup", "harness", "slow-opencode"]);
    let row = &report["harnesses"][0];
    assert_eq!(row["auth_status"], "needs_action", "{row}");
    assert_eq!(row["signed_in"], Value::Null);
    assert_eq!(row["recovery"]["kind"], "check");
    assert_eq!(row["recovery"]["command"], "cmux harness doctor slow-opencode --no-prompt --json");
    assert!(row["auth_detail"].as_str().unwrap().contains("initialize"));
}

#[test]
fn cmux_setup_harness_auth_codex_signed_out_keeps_custom_profile() {
    let world = World::new("hcodex");
    let agent = world.bin.join("codex");
    World::executable(
        &agent,
        "#!/bin/sh\n[ \"$1\" = --version ] && { echo 1.0.0; exit 0; }\necho 'Not logged in' >&2\nexit 1\n",
    );
    world.configure(json!({"work-codex": {"argv": [agent, "app-server"]}}));
    let report = world.json(&["setup", "harness", "work-codex"]);
    let row = &report["harnesses"][0];
    assert_eq!(row["auth_status"], "signed_out", "{row}");
    assert_eq!(row["signed_in"], false);
    assert_eq!(row["recovery"]["command"], "cmux harness login work-codex");
}

#[test]
fn cmux_setup_harness_auth_keychain_unknown_stays_non_actionable() {
    let world = World::new("hunknown");
    let agent = world.bin.join("claude-agent-acp");
    world.harness(&agent, "1.0.0");
    world.configure(json!({"work-claude": {"argv": [agent]}}));
    let report = world.json(&["setup", "harness", "work-claude"]);
    let row = &report["harnesses"][0];
    assert_eq!(row["auth_status"], "unknown", "{row}");
    assert_eq!(row["signed_in"], Value::Null);
    assert_eq!(row["state"], "ok");
    assert_eq!(row["recovery"], Value::Null);
    assert_eq!(World::harness_log(&agent), "");
}
