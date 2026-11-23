//! An agent that runs before a daemon restart or upgrade keeps a proven identity after it, with
//! no action from the person or the agent (`hub/caller_registry.rs`, `hub/person.rs` (a)).
//!
//! Its harness keeps the caller token the earlier daemon run gave it. Before the registry, the
//! next run knew that token only through the host record it adopted: while a host's hello was
//! late (a loaded Mac, cmuxterm-hq#5545) or its record unreadable, every `acpmux send` of that
//! agent went out as "no proven session" until `acpmux session restart`.

use super::*;

/// `acpmux send --no-wait TO TEXT` as the agent of `session` runs it: inside that session, with
/// the caller token its harness got and the socket the token is for. Answers its stderr.
fn send_as(daemon: &Daemon, session: &str, token: &str, to: &str, text: &str) -> String {
    send_as_with(daemon, session, token, to, text, &[])
}

/// [`send_as`] with `extra` in the command's environment (the harness's own variables).
fn send_as_with(
    daemon: &Daemon,
    session: &str,
    token: &str,
    to: &str,
    text: &str,
    extra: &[(&str, &str)],
) -> String {
    let out = daemon_env::acpmux(&daemon.home)
        .args(["send", "--no-wait", to, text])
        .env("ACPMUX_HOME", &daemon.home)
        .env("ACPMUX_SOCKET", &daemon.socket)
        .env("ACPMUX_SESSION_ID", session)
        .env("ACPMUX_SESSION_NAME", "lead")
        .env("ACPMUX_SESSION_TOKEN", token)
        .env("ACPMUX_SESSION_TOKEN_SOCKET", &daemon.socket)
        .envs(extra.iter().copied())
        .output()
        .expect("run acpmux send");
    let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
    format!("status {:?}\nstderr: {stderr}", out.status)
}

/// What a send's `sending as` line must say for a proven agent: its session, not the refusal.
fn proven(said: &str) -> bool {
    said.contains("sending as ") && !said.contains("no proven session")
}

#[tokio::test]
async fn caller_identity_an_agent_stays_proven_across_daemon_restarts() {
    let mut daemon = Daemon::new("callerid", "approve-all");
    let session = new_session(&daemon).await;
    let other = new_session(&daemon).await;
    let token = agent_env(&daemon, &session, "ACPMUX_SESSION_TOKEN").await;
    assert_eq!(token.len(), 64, "the agent has no caller token");
    let harness = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    let before = send_as(&daemon, &session, &token, &other, "before the restart");
    assert!(proven(&before), "the agent's send before any restart: {before}");

    // A plain restart (an update): the next run adopts the host, and the agent's send is proven.
    daemon.sigterm();
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    assert!(alive(harness), "the agent died with the restart");
    let after = send_as(&daemon, &session, &token, &other, "after the restart");
    assert!(proven(&after), "the agent's send after a restart: {after}");

    // A restart on a loaded Mac: the host does not answer its hello in time for the start's
    // adoption pass (debug builds' seam: every hello of that pass misses) nor yet for its retry
    // (the host is stopped), so this run has not adopted it when the agent sends. Before the
    // registry, that send went out as "no proven session".
    let host = daemon.host_record(&session)["host_pid"].as_i64().unwrap();
    daemon.sigterm();
    daemon.env.push(("ACPMUX_TEST_ADOPT_HELLO_BUDGET_MS".into(), "0".into()));
    // SAFETY: signals the agent host this test started; it is resumed below.
    assert_eq!(unsafe { libc::kill(host as i32, libc::SIGSTOP) }, 0);
    daemon.start();
    let late = send_as(&daemon, &session, &token, &other, "while adoption is late");
    let listed = list_as(&daemon, &session, &token).await;
    // SAFETY: as above; the retry's hello is answered now.
    assert_eq!(unsafe { libc::kill(host as i32, libc::SIGCONT) }, 0);
    assert!(proven(&late), "the agent's send before its late adoption: {late}");
    assert!(listed.get("error").is_none(), "the daemon did not prove the agent's token: {listed}");
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
    assert!(alive(harness), "the agent died with the second restart");

    // Still the session's alone, and a token that proves nothing proves nothing.
    let borrowed = list_as(&daemon, &other, &token).await;
    assert!(borrowed.get("error").is_some(), "one session's token proved another: {borrowed}");
    let stray = list_as(&daemon, &session, &"0".repeat(64)).await;
    assert!(stray.get("error").is_some(), "a token that proves nothing was let in: {stray}");
}

/// A Codex subagent runs in a thread of its own, so its commands carry another
/// `CODEX_THREAD_ID` than the session's own thread (`cli/sender.rs` `codex_thread_in`): its send
/// names it as the session's codex subagent, the lead's own send names the session.
#[tokio::test]
async fn caller_identity_a_codex_thread_other_than_the_sessions_own_sends_as_its_subagent() {
    let daemon = Daemon::new("calleridcx", "approve-all");
    let session = new_session(&daemon).await;
    let other = new_session(&daemon).await;
    let token = agent_env(&daemon, &session, "ACPMUX_SESSION_TOKEN").await;
    let mut rpc = daemon.rpc().await;
    let info = rpc.call("_acpmux/info", json!({"sessionId": session, "waitLogs": false})).await;
    let own = info["agentSessionId"].as_str().expect("the session's own id in its harness");
    let lead = send_as_with(
        &daemon,
        &session,
        &token,
        &other,
        "from the lead",
        &[("CODEX_THREAD_ID", own)],
    );
    assert!(proven(&lead) && !lead.contains("subagent"), "the lead's own thread: {lead}");
    let thread = "019a2b3c-sub-thread";
    let sub = send_as_with(
        &daemon,
        &session,
        &token,
        &other,
        "from a subagent",
        &[("CODEX_THREAD_ID", thread)],
    );
    assert!(sub.contains("'s codex subagent 019a2b3c"), "another thread of the session: {sub}");
}
