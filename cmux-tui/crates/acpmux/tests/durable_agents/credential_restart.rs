//! cmux#45776: a Cloud chat's launch credential (`agent_credentials.rs`, cmux#40159) lives in the
//! daemon's memory only. A daemon that died (the Cloud journey's "daemon restart keeps the
//! session": SIGKILL, then systemd's restart) came back with none, while the agent it adopted still
//! ran on it; the agent's next start (its wake after the machine paused) then ran on the machine's
//! route, and Claude said "not signed in". The new daemon now reads the credential back from the
//! adopted agent's own env, so the next start runs on it again. Linux only (`/proc/PID/environ`).

use super::*;

const TOKEN: &str = "sk-ant-oat01-journey-45776-token";
const NAME: &str = "CLAUDE_CODE_OAUTH_TOKEN";

/// The daemon whose default harness is a Claude-family stand-in agent, with `env` as its profile env.
fn claude_family_daemon(tag: &str, env: Value) -> Daemon {
    let mut daemon = Daemon::new(tag, "approve-all");
    daemon.sigterm();
    std::fs::write(
        daemon.home.join("config.json"),
        json!({"harnesses": {"claude-fake": {"argv": ["python3", FAKE], "family": "claude", "env": env}},
               "defaultHarness": "claude-fake", "permissionPolicy": "approve-all"})
        .to_string(),
    )
    .unwrap();
    daemon.start();
    daemon
}

/// What the agent of `session` has for [`NAME`] now (`env:` in `tests/fake_agent.py`).
async fn agent_token(daemon: &Daemon, session: &str, turn: usize) -> String {
    agent_env(daemon, session, NAME, turn).await
}

/// What the agent of `session` has for `name` now; empty when it has none.
async fn agent_env(daemon: &Daemon, session: &str, name: &str, turn: usize) -> String {
    let mut rpc = daemon.rpc().await;
    let marker = format!("{name}=");
    let before = daemon.events(session).iter().filter(|e| chunk_starts(e, &marker)).count();
    rpc.call(
        "session/prompt",
        json!({"sessionId": session, "prompt": [{"type": "text", "text": format!("env: {name}")}]}),
    )
    .await;
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let seen: Vec<String> = daemon
            .events(session)
            .iter()
            .filter(|e| chunk_starts(e, &marker))
            .filter_map(|e| e["msg"]["params"]["update"]["content"]["text"].as_str())
            .map(str::to_owned)
            .collect();
        if seen.len() > before {
            return seen[before].trim_start_matches(&marker).to_owned();
        }
        assert!(Instant::now() < deadline, "turn {turn}: the agent did not say its {name}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn chunk_starts(e: &Value, prefix: &str) -> bool {
    e["msg"]["params"]["update"]["sessionUpdate"] == "agent_message_chunk"
        && e["msg"]["params"]["update"]["content"]["text"]
            .as_str()
            .is_some_and(|t| t.starts_with(prefix))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_daemon_killed_and_restarted_starts_the_agent_again_on_its_launch_credential() {
    launch_credential_survives_adoption("cred", json!({})).await;
}

#[cfg(debug_assertions)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn adoption_recovers_a_launch_credential_from_a_base_version_host_hello() {
    launch_credential_survives_adoption("cred-old", json!({"ACPMUX_TEST_LEGACY_HOST_HELLO": "1"}))
        .await;
}

async fn launch_credential_survives_adoption(tag: &str, env: Value) {
    let mut daemon = claude_family_daemon(tag, env);
    let mut rpc = daemon.rpc().await;
    let created = rpc
        .call(
            "session/new",
            json!({"cwd": daemon.home, "mcpServers": [],
                   "_meta": {"acpmux": {"credentials": {"env": {NAME: TOKEN}}}}}),
        )
        .await;
    let session = created["sessionId"].as_str().unwrap().to_owned();
    drop(rpc);
    assert_eq!(agent_token(&daemon, &session, 1).await, TOKEN, "the first start has it");

    // A crash: no clean shutdown, the agent's host outlives it, and the new daemon adopts it.
    daemon.sigkill();
    daemon.start();

    // The adopted agent restarts (as on a wake after a pause, a route switch or an update), once
    // the new daemon holds it; before the fix it came back on the machine's route, with no token.
    let mut rpc = daemon.rpc().await;
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        let done =
            rpc.call("_acpmux/sessions/restart_harness", json!({"sessions": [session]})).await;
        if done["restarted"].as_u64() == Some(1) {
            break;
        }
        assert!(Instant::now() < deadline, "the new daemon never restarted the agent: {done}");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    drop(rpc);
    assert_eq!(
        agent_token(&daemon, &session, 2).await,
        TOKEN,
        "the agent the restarted daemon started runs on the launch credential again"
    );
    // Still never written down by the daemon. The stand-in agent itself said the value in the chat
    // (`env:`), so the chat's own text (its preview, title, last prompt) is left out.
    let path = daemon.home.join("sessions").join(&session).join("session.json");
    let mut meta: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    for chat_text in ["preview", "title", "lastPrompt"] {
        meta.as_object_mut().unwrap().remove(chat_text);
    }
    assert!(!meta.to_string().contains(TOKEN), "the session meta holds the credential: {meta}");
}

/// Only acpmux marks an agent as launched on a credential: a profile (or preset, or request) env
/// that sets the marker beside a login of its own would otherwise have that login read back after
/// a restart as an owner's credential, and applied to an agent that was never given one.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_profile_cannot_mark_its_own_login_as_a_launch_credential() {
    let daemon = claude_family_daemon(
        "cred-mark",
        json!({"ACPMUX_LAUNCH_CREDENTIAL": NAME, NAME: "sk-ant-oat01-profile-login"}),
    );
    let mut rpc = daemon.rpc().await;
    let created = rpc.call("session/new", json!({"cwd": daemon.home, "mcpServers": []})).await;
    let session = created["sessionId"].as_str().unwrap().to_owned();
    drop(rpc);
    assert_eq!(agent_env(&daemon, &session, "ACPMUX_LAUNCH_CREDENTIAL", 1).await, "");
    assert_eq!(
        agent_token(&daemon, &session, 2).await,
        "sk-ant-oat01-profile-login",
        "its own login stays"
    );
}

/// A fake Claude CLI for account status and manual approval, with a separate ACP test harness.
fn claude_recovery_daemon(tag: &str) -> Daemon {
    use std::os::unix::fs::PermissionsExt as _;

    let mut daemon = Daemon::new(tag, "approve-all");
    daemon.sigterm();
    let config_dir = daemon.home.join("claude-config");
    std::fs::create_dir(&config_dir).unwrap();
    let cli = daemon.home.join("claude");
    std::fs::write(
        &cli,
        format!(
            r#"#!/bin/sh
case "$1 $2" in
    "auth status") echo '{{"loggedIn":true,"authMethod":"claude.ai"}}' ;;
    "auth login")
        echo 'visit: https://claude.com/cai/oauth/authorize?code=true&state=s1 '
        read -r code
        [ "$code" = fixture-code ] || exit 1
        echo '{{"claudeAiOauth":{{}}}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
        ;;
    *) exec python3 "{FAKE}" "$@" ;;
esac
"#
        ),
    )
    .unwrap();
    std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o700)).unwrap();
    let env = json!({"CLAUDE_CONFIG_DIR": config_dir, "CMUX_CLAUDE_AUTH": "team"});
    std::fs::write(
        daemon.home.join("config.json"),
        json!({
            "harnesses": {
                "claude-fake": {"argv": [cli], "family": "claude", "env": env},
                "claude": {"argv": [cli], "kind": "claude-stdio", "env": env}
            },
            "defaultHarness": "claude-fake", "permissionPolicy": "approve-all"
        })
        .to_string(),
    )
    .unwrap();
    daemon.start();
    daemon
}

async fn saved_claude_chat(daemon: &Daemon, rpc: &mut Rpc, connection: &str) -> String {
    let created = rpc.call("session/new", json!({
        "cwd": daemon.home, "mcpServers": [],
        "_meta": {"acpmux": {"credentials": {"env": {NAME: TOKEN}, "connection": connection}}}
    })).await;
    created["sessionId"].as_str().unwrap().to_owned()
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn claude_finish_uses_the_recovery_chat_bound_at_start() {
    let daemon = claude_recovery_daemon("recovery-bind");
    let mut rpc = daemon.rpc().await;
    let a = saved_claude_chat(&daemon, &mut rpc, "claude-token").await;
    let b = saved_claude_chat(&daemon, &mut rpc, "claude-token-2").await;
    let start = "_acpmux/agent_login/start";
    let finish = "_acpmux/agent_login/finish";
    let recover_start = "_acpmux/agent_login/recover_start";
    let recover_finish = "_acpmux/agent_login/recover_finish";

    let ordinary = rpc.call(start, json!({"agent": "claude"})).await;
    let wrong = rpc
        .reply(
            recover_finish,
            json!({
                "loginId": ordinary["loginId"], "code": "fixture-code", "recoverySession": b
            }),
        )
        .await;
    assert_eq!(wrong["error"]["code"], -32602);
    assert_eq!(
        rpc.call(finish, json!({"loginId": ordinary["loginId"], "code": "fixture-code"})).await["signedIn"],
        true
    );
    assert_eq!(agent_token(&daemon, &a, 1).await, TOKEN);
    assert_eq!(agent_token(&daemon, &b, 1).await, TOKEN);

    let scoped = rpc.call(recover_start, json!({"agent": "claude", "recoverySession": a})).await;
    let wrong = rpc
        .reply(
            recover_finish,
            json!({
                "loginId": scoped["loginId"], "code": "fixture-code", "recoverySession": b
            }),
        )
        .await;
    assert_eq!(wrong["error"]["code"], -32602);
    assert_eq!(
        rpc.call(finish, json!({"loginId": scoped["loginId"], "code": "fixture-code"})).await["signedIn"],
        true
    );
    assert_eq!(agent_token(&daemon, &a, 2).await, "");
    assert_eq!(agent_token(&daemon, &b, 2).await, TOKEN);

    let matched = rpc.call(recover_start, json!({"agent": "claude", "recoverySession": b})).await;
    assert_eq!(
        rpc.call(
            recover_finish,
            json!({"loginId": matched["loginId"], "code": "fixture-code", "recoverySession": b})
        )
        .await["signedIn"],
        true
    );
    assert_eq!(agent_token(&daemon, &b, 3).await, "");
}

#[cfg(debug_assertions)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn recovery_reusing_a_login_before_adoption_restarts_the_old_host_before_the_next_turn() {
    let mut daemon = claude_recovery_daemon("recovery-adopt");
    let mut rpc = daemon.rpc().await;
    let chat = saved_claude_chat(&daemon, &mut rpc, "claude-token").await;
    let original_host = daemon.host_record(&chat)["host_pid"].clone();
    assert!(original_host.is_number());
    daemon.sigkill();
    daemon.env.push(("ACPMUX_TEST_ADOPT_HOLD_MS".into(), "4000".into()));
    daemon.start();
    let mut rpc = daemon.rpc().await;
    let before = rpc.call("agent/credentials.update", json!({"sessionId": chat})).await;
    assert_eq!(before["connection"], "claude-token");
    assert_eq!(before["held"], false, "the old host has yet to be adopted");
    let status = rpc
        .call(
            "_acpmux/agent_login/start",
            json!({
                "agent": "claude", "reuseExisting": true, "recoverySession": chat
            }),
        )
        .await;
    assert_eq!(status["signedIn"], true);
    assert!(status["loginId"].is_null());
    assert_eq!(agent_token(&daemon, &chat, 1).await, "");
    assert_eq!(agent_env(&daemon, &chat, "CMUX_CLAUDE_AUTH", 2).await, "own");
    assert_ne!(daemon.host_record(&chat)["host_pid"], original_host);
    let meta: Value = serde_json::from_slice(
        &std::fs::read(daemon.home.join("sessions").join(&chat).join("session.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(meta["claudeLoginRestartPending"], false);
}
