//! An OpenCode chat is forked by the fork's own agent as it starts (`hub/fork_own_process.rs`).
//! The fake agent's `FAKE_FORK_BUSY=1` answers `session/fork` as OpenCode 1.19 does: only once no
//! prompt of its process runs, and of any session in the store its processes share. Measured
//! 2026-11-22 on a Mac: forking a working OpenCode chat took 24-58 s (its agent answered once the
//! running step or tool call ended), a stopped one 44.5 s (its agent started again to be asked).

use super::*;

/// Each `session/new`, `session/load` and `session/fork` the fake agents got: (pid, method, id).
fn calls(log: &std::path::Path) -> Vec<(u64, String, String)> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .map(|v| {
            (
                v["pid"].as_u64().unwrap_or_default(),
                v["method"].as_str().unwrap_or_default().to_owned(),
                v["sessionId"].as_str().unwrap_or_default().to_owned(),
            )
        })
        .collect()
}

async fn opencode_chat() -> (Arc<Hub>, TestClient, String, std::path::PathBuf) {
    let log = std::env::temp_dir().join(format!("acpmux-own-fork-{}", uuid::Uuid::now_v7()));
    let env = BTreeMap::from([
        ("FAKE_FORK_BUSY".to_owned(), "1".to_owned()),
        ("FAKE_FORK_LOG".to_owned(), log.to_string_lossy().into_owned()),
    ]);
    let (hub, mut c) = setup_opencode(env).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "oc"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "first ZEBRA-7"}]}),
    )
    .await
    .unwrap();
    (hub, c, id, log)
}

/// The fork's agent session, once its own agent started.
async fn forks_agent_session(hub: &Hub, fid: &str) -> String {
    for _ in 0..500 {
        if let Some(sid) = hub.resolve(fid).unwrap().meta().agent_session_id {
            return sid;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("the fork's agent never got its session");
}

/// Forked by its own agent: one `session/fork` of the chat's agent session, from a process that
/// is not the chat's, and the fork's agent session is the one it answered.
fn forked_by_its_own_agent(log: &std::path::Path, parent_sid: &str, fork_sid: &str) {
    let calls = calls(log);
    let parent_pid = calls.iter().find(|(_, m, _)| m == "session/new").map(|(p, ..)| *p).unwrap();
    let forks: Vec<_> = calls.iter().filter(|(_, m, _)| m == "session/fork").collect();
    assert_eq!(forks.len(), 1, "{calls:?}");
    assert_eq!(forks[0].2, parent_sid, "{calls:?}");
    assert_ne!(forks[0].0, parent_pid, "the chat's own process was asked for the fork: {calls:?}");
    assert!(fork_sid.starts_with(&format!("{parent_sid}-fork-{}-", forks[0].0)), "{fork_sid}");
    let loads: Vec<_> = calls.iter().filter(|(_, m, _)| m == "session/load").collect();
    assert!(loads.is_empty(), "nothing is loaded: {calls:?}");
}

/// A working chat forks at once: its agent is never asked (it would answer once its turn
/// ended), the fork's own agent forks the chat's session, and the chat's turn goes on.
#[tokio::test]
async fn a_working_opencode_chat_forks_at_once_by_the_forks_own_agent() {
    let (hub, mut c, id, log) = opencode_chat().await;
    let parent_sid = hub.resolve(&id).unwrap().meta().agent_session_id.unwrap();
    c.send(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "until-cancel"}]}),
    )
    .await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    let f = tokio::time::timeout(
        Duration::from_secs(8),
        c.request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()})),
    )
    .await
    .expect("the fork of a working chat waited for the chat's turn")
    .unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    let fork_sid = forks_agent_session(&hub, &fid).await;
    forked_by_its_own_agent(&log, &parent_sid, &fork_sid);
    assert_eq!(
        hub.resolve(&id).unwrap().meta().status,
        acpmux::store::SessionStatus::Running,
        "the chat's turn goes on"
    );
    let events = hub.events(&fid, 0, 1000).unwrap();
    let results: Vec<&Value> =
        events.iter().filter(|e| e.kind == "turn_result").map(|e| &e.msg).collect();
    assert_eq!(results.last().map(|r| r["status"].clone()), Some(json!("cancelled")));
    assert!(events.iter().any(|e| e.msg.to_string().contains("first ZEBRA-7")));
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": fid, "prompt": [{"type": "text", "text": "second"}]}),
        )
        .await
        .unwrap();
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    c.send(method::SESSION_CANCEL, json!({"sessionId": id})).await;
    hub.shutdown_all().await;
    let _ = std::fs::remove_file(&log);
}

/// A stopped chat forks without its agent starting again (initialize and a load of its whole
/// history, only to be asked for the fork).
#[tokio::test]
async fn a_stopped_opencode_chat_forks_without_starting_its_agent() {
    let (hub, mut c, id, log) = opencode_chat().await;
    let parent_sid = hub.resolve(&id).unwrap().meta().agent_session_id.unwrap();
    hub.kill(&hub.resolve(&id).unwrap(), false).await.unwrap();
    let f = c.request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()})).await.unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    let fork_sid = forks_agent_session(&hub, &fid).await;
    forked_by_its_own_agent(&log, &parent_sid, &fork_sid);
    let r = c
        .request(
            method::SESSION_PROMPT,
            json!({"sessionId": fid, "prompt": [{"type": "text", "text": "second"}]}),
        )
        .await
        .unwrap();
    assert_eq!(r["stopReason"], "end_turn", "{r}");
    hub.shutdown_all().await;
    let _ = std::fs::remove_file(&log);
}
