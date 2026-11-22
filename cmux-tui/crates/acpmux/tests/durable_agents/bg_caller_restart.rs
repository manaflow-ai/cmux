//! A chat's background tasks across an update restart (`hub/bg_tasks.rs`, `hub/person.rs` (a)).
//! The agent's `acpmux` MCP server connects anew for each tool call, so right after a restart it
//! reaches the new daemon with the previous run's caller token while that daemon is still
//! adopting the agent hosts it found. On 2026-11-01 two lanes on one VM lost their review and CI
//! tasks that way: every `bg_output` and `bg_list` in that window answered "a chat reaches only
//! its own background tasks", while the tasks ran on.

use super::*;

/// A connection that presents `token` as chat `session`'s caller token, as the agent's `acpmux`
/// MCP server does on each call, and its reply to background-task method `method`.
async fn bg_as(daemon: &Daemon, session: &str, token: &str, method: &str, params: Value) -> Value {
    let mut caller = daemon.rpc().await;
    caller
        .call(
            "initialize",
            json!({"protocolVersion": 1,
                   "_meta": {"acpmux": {"callerSession": {"sessionId": session, "token": token}}}}),
        )
        .await;
    let mut params = params;
    params["sessionId"] = json!(session);
    caller.reply(method, params).await
}

fn task_ids(listed: &Value) -> Vec<String> {
    let tasks = listed["result"]["tasks"].as_array().cloned().unwrap_or_default();
    tasks.iter().filter_map(|t| t["id"].as_str().map(str::to_owned)).collect()
}

#[tokio::test]
async fn a_chats_background_task_stays_its_own_while_a_restarted_daemon_adopts_its_agent() {
    let mut daemon = Daemon::new("bgadopt", "approve-all");
    let session = new_session(&daemon).await;
    let token = agent_env(&daemon, &session, "ACPMUX_SESSION_TOKEN").await;
    let started = bg_as(
        &daemon,
        &session,
        &token,
        "_acpmux/bg/start",
        json!({"command": "echo started; sleep 60"}),
    )
    .await;
    let task = started["result"]["id"].as_str().unwrap_or_else(|| panic!("{started}")).to_owned();
    let other = new_session(&daemon).await;
    let other_token = agent_env(&daemon, &other, "ACPMUX_SESSION_TOKEN").await;

    // An update restart whose adoption takes a while, as one of ~90 hosts did on a lane VM.
    daemon.sigterm();
    daemon.env = vec![("ACPMUX_TEST_ADOPT_HOLD_MS".into(), "3000".into())];
    daemon.start();
    let adopted = |s: &str| daemon.events(s).iter().any(|e| e["kind"] == "host_adopted");
    assert!(!adopted(&session), "the host was adopted before the agent's tool call");
    let listed = bg_as(&daemon, &session, &token, "_acpmux/bg/list", json!({})).await;
    assert!(
        listed.get("error").is_none(),
        "the chat's own agent lost its background tasks to the restart: {listed}"
    );
    assert_eq!(task_ids(&listed), vec![task.clone()], "{listed}");
    let read = bg_as(&daemon, &session, &token, "_acpmux/bg/output", json!({"id": task})).await;
    assert!(read["result"]["text"].as_str().is_some_and(|t| t.contains("started")), "{read}");

    // Never another chat's: neither its token for this chat nor this token for it.
    let borrowed = bg_as(&daemon, &session, &other_token, "_acpmux/bg/list", json!({})).await;
    assert!(borrowed.get("error").is_some(), "another chat read this chat's tasks: {borrowed}");
    let crossed = bg_as(&daemon, &other, &token, "_acpmux/bg/list", json!({})).await;
    assert!(crossed.get("error").is_some(), "this chat's token reached another chat: {crossed}");
    let stray = bg_as(&daemon, &session, &"0".repeat(64), "_acpmux/bg/list", json!({})).await;
    assert!(stray.get("error").is_some(), "a token that proves nothing was let in: {stray}");

    // A new agent process (respawn) has this run's token and still owns the task; it stops it.
    let out = daemon_env::acpmux(&daemon.home)
        .args(["session", "restart", &session])
        .env("ACPMUX_HOME", &daemon.home)
        .env("ACPMUX_SOCKET", &daemon.socket)
        .output()
        .expect("run acpmux session restart");
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let fresh = agent_env(&daemon, &session, "ACPMUX_SESSION_TOKEN").await;
    assert_ne!(fresh, token, "the restarted agent kept the earlier run's token");
    let listed = bg_as(&daemon, &session, &fresh, "_acpmux/bg/list", json!({})).await;
    assert_eq!(task_ids(&listed), vec![task.clone()], "{listed}");
    let stopped = bg_as(&daemon, &session, &fresh, "_acpmux/bg/stop", json!({"id": task})).await;
    assert_eq!(stopped["result"]["state"], "stopped", "{stopped}");
}
