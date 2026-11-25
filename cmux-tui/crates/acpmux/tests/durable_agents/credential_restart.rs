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
    let mut daemon = claude_family_daemon("cred", json!({}));
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

/// The Cloud journey's order (resume-matrix run 45177970049): the daemon restarts and adopts the
/// agent, the chat then sits idle past the idle period so the adopted agent hibernates, and the
/// next message (the first after the machine paused and resumed) wakes a new agent. That agent
/// must run on the launch credential too; Claude said "Not logged in" when it did not.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_adopted_agent_that_hibernates_wakes_on_its_launch_credential() {
    let mut daemon = claude_family_daemon("cred-idle", json!({}));
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
    let first = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();

    // A crash, and a daemon whose idle period is short: it adopts the agent, which then hibernates.
    daemon.sigkill();
    daemon.env.push(("ACPMUX_IDLE_CHILD_SECS".into(), "1".into()));
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    assert!(
        gone_within(first, Duration::from_secs(30)),
        "the adopted agent did not hibernate while the chat sat idle"
    );

    // The next message wakes a new agent, which runs on the credential again.
    assert_eq!(
        agent_token(&daemon, &session, 2).await,
        TOKEN,
        "the agent woken after the adopted one hibernated runs on the launch credential"
    );
    let woken = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    assert_ne!(woken, first, "the message was not answered by a new agent");
}

/// cmux#52399: the same order, with an agent whose own env no longer names its credential (it
/// started itself again through a wrapper that cleaned the env, so `/proc/PID/environ`, the env of
/// its last exec, lacks the marker). The new daemon took the credential only from that env, held
/// none, and the agent it woke after the adopted one hibernated ran with no login: "Not logged in".
/// The agent's host, which launched it and outlives the daemon, says the credential instead.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_adopted_agent_whose_env_lost_the_marker_still_wakes_on_its_launch_credential() {
    let mut daemon = claude_family_daemon(
        "cred-reexec",
        json!({"FAKE_REEXEC_WITHOUT": "ACPMUX_LAUNCH_CREDENTIAL"}),
    );
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
    let first = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    let environ = std::fs::read(format!("/proc/{first}/environ")).unwrap();
    assert!(
        !environ.split(|b| *b == 0).any(|v| v.starts_with(b"ACPMUX_LAUNCH_CREDENTIAL=")),
        "the stand-in agent's env still names its credential, so this test proves nothing"
    );

    daemon.sigkill();
    daemon.env.push(("ACPMUX_IDLE_CHILD_SECS".into(), "1".into()));
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    assert!(
        gone_within(first, Duration::from_secs(30)),
        "the adopted agent did not hibernate while the chat sat idle"
    );

    assert_eq!(
        agent_token(&daemon, &session, 2).await,
        TOKEN,
        "the agent woken after the adopted one hibernated runs on the launch credential"
    );
    let woken = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    assert_ne!(woken, first, "the message was not answered by a new agent");
}
