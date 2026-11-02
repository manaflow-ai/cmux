//! An approve-all an older daemon saved with no source, on a chat whose agent host outlived it
//! (`hub/policy_source.rs`): the next daemon clears the grant before it reaches the host, and
//! ends that host rather than adopt it, so nothing the agent asks under the old grant is
//! approved by it.

use super::*;

/// Lets a `gate-ask:` agent that still waits on `gate` go on to ask; none waits once it ended.
fn release(gate: &Path) {
    let open = std::fs::OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open(gate);
    if let Ok(mut gate) = open {
        let _ = std::io::Write::write_all(&mut gate, b"go");
    }
}

/// Rewrites `session`'s saved meta (its daemon stopped) to what an older daemon saved for a
/// handoff target (local, tagged) it gave approve-all: no `policySource`. Returns its path.
fn saved_as_legacy_grant(daemon: &Daemon, session: &str) -> PathBuf {
    let path = daemon.home.join("sessions").join(session).join("session.json");
    let mut meta: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    meta["permissionPolicy"] = json!("approve-all");
    meta["tags"] = json!({"handoffKey": {"value": "k1"}});
    meta.as_object_mut().unwrap().remove("policySource");
    std::fs::write(&path, meta.to_string()).unwrap();
    path
}

/// A handoff target (local, tagged) that an older daemon gave approve-all, whose agent is about
/// to ask for a permission across the restart.
#[tokio::test]
async fn a_cleared_grants_live_agent_is_ended_not_adopted_and_its_chat_asks() {
    let mut daemon = Daemon::new("grant", "ask");
    let session = new_session(&daemon).await;
    let gate = daemon.home.join("gate");
    make_fifo(&gate);
    let mut client = daemon.rpc().await;
    let ask =
        |text: &str| json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
    client.send("session/prompt", ask(&format!("gate-ask: {}", gate.display()))).await;
    daemon.wait_event(&session, "before-gate chunk", |e| chunk(e, "before-gate"));
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    drop(client);
    assert!(alive(harness_pid), "SIGTERM ended the agent");

    let path = saved_as_legacy_grant(&daemon, &session);

    daemon.start();
    let first = daemon.wait_event(&session, "grant_cleared or host_adopted", |e| {
        e["kind"] == "grant_cleared" || e["kind"] == "host_adopted"
    });
    if first["kind"] == "host_adopted" {
        release(&gate);
        let answer = daemon.wait_event(&session, "the agent's ask", |e| {
            e["kind"] == "permission_request" || e["kind"] == "permission_auto"
        });
        panic!("the cleared chat's host was adopted, and its ask got {answer}");
    }
    assert_eq!(first["msg"]["hostEnded"], true, "{first}");
    assert!(gone_within(harness_pid, Duration::from_secs(10)), "the agent still runs");
    // Saved right after its record (test polling).
    let deadline = Instant::now() + Duration::from_secs(10);
    let saved = loop {
        let saved: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        if saved["policySource"] == "cleared" || Instant::now() >= deadline {
            break saved;
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(
        (&saved["permissionPolicy"], &saved["policySource"]),
        (&json!("ask"), &json!("cleared"))
    );

    // Its next start asks.
    let mut rpc = daemon.rpc().await;
    rpc.send("session/prompt", ask("ask: again")).await;
    daemon.wait_event(&session, "a permission_request", |e| e["kind"] == "permission_request");
    let events = daemon.events(&session);
    for kind in ["host_adopted", "permission_auto"] {
        assert!(!events.iter().any(|e| e["kind"] == kind), "{kind}: {events:#?}");
    }
    // The host that start runs is the chat's own: the next restart adopts it.
    daemon.sigterm();
    drop(rpc);
    daemon.start();
    daemon.wait_event(&session, "host_adopted", |e| e["kind"] == "host_adopted");
}

/// The same chat, its agent idle (no cut turn queues ahead), when the host records cannot be
/// read at the restart (the debug seam `ACPMUX_TEST_HOST_RECORDS_FAIL_FILE`): nothing proves its
/// old host ended, so a prompt is refused rather than start an agent beside it. Once the records
/// read again, the old host is ended and the next start asks.
#[tokio::test]
async fn a_cleared_chat_is_refused_while_its_old_host_is_not_proven_ended() {
    let flag = std::env::temp_dir().join(format!("amd-grantrec-flag-{}", std::process::id()));
    let flag_env = flag.to_string_lossy().into_owned();
    let env = [("ACPMUX_TEST_HOST_RECORDS_FAIL_FILE", flag_env.as_str())];
    let mut daemon = Daemon::with_env("grantrec", "ask", &env);
    let session = new_session(&daemon).await;
    let ask =
        |text: &str| json!({"sessionId": session, "prompt": [{"type": "text", "text": text}]});
    daemon.rpc().await.call("session/prompt", ask("hello")).await;
    let harness_pid = daemon.host_record(&session)["harness_pid"].as_i64().unwrap();
    daemon.sigterm();
    saved_as_legacy_grant(&daemon, &session);
    std::fs::write(&flag, "").unwrap();

    daemon.start();
    let mut rpc = daemon.rpc().await;
    let reply = rpc.reply("session/prompt", ask("hi")).await;
    let started =
        |d: &Daemon| d.events(&session).iter().filter(|e| e["kind"] == "host_started").count();
    assert_eq!(started(&daemon), 1, "an agent started beside the old host: {reply}");
    assert!(reply.get("error").is_some(), "{reply}");
    assert!(alive(harness_pid), "the seam did not keep the records unread");

    std::fs::remove_file(&flag).unwrap();
    rpc.send("session/prompt", ask("ask: again")).await;
    daemon.wait_event(&session, "a permission_request", |e| e["kind"] == "permission_request");
    assert!(gone_within(harness_pid, Duration::from_secs(10)), "the old agent still runs");
    let events = daemon.events(&session);
    assert!(!events.iter().any(|e| e["kind"] == "permission_auto"), "{events:#?}");
}
