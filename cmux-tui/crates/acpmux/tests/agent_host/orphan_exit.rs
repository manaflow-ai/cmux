//! A host whose daemon never comes back ends once its agent is idle (`SpawnSpec::orphan_exit`),
//! never while a controller is connected and never mid-turn: hosts outlive their daemon on
//! purpose (an update, a crash, a restart, the app's Quit), but with nothing to adopt them they
//! ran forever (Leo, 2026-10-30: "JUST FUCKING REMOVE THE FUCKING OLD DAMEMONS").

use super::*;

/// The test's wait for a controller, far below the daemon's ([`agent_host::ORPHAN_IDLE`]).
const WAIT: Duration = Duration::from_millis(1000);

fn orphan_spec(dir: &Path, session: &str) -> SpawnSpec {
    let mut spec = spec(dir, session);
    spec.orphan_exit =
        Some(agent_host::OrphanExit { idle_ms: WAIT.as_millis() as u64, family: String::new() });
    spec
}

fn live(dir: &Path, record: &HostRecord) -> bool {
    agent_host::liveness(&dir.join("hosts"), &record.session_id, &record.start_nonce)
        == Liveness::Live
}

/// Whether the host ended within `within` (test polling): one that never ends fails the test
/// instead of holding it.
async fn ends_within(dir: &Path, record: &HostRecord, within: Duration) -> bool {
    let deadline = std::time::Instant::now() + within;
    while live(dir, record) {
        if std::time::Instant::now() >= deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    true
}

/// `initialize` and `session/new`, every entry logged: the session's id.
async fn started(owner: &Link, dir: &Path, logged: &mut u64) -> String {
    request(owner, 1, "initialize", json!({"protocolVersion": 1})).await;
    read_until(owner, logged, |e| is_response(e, 1)).await;
    request(owner, 2, "session/new", json!({"cwd": dir, "mcpServers": []})).await;
    let new = read_until(owner, logged, |e| is_response(e, 2)).await;
    let Entry::In { msg } = &new.last().unwrap().1 else { unreachable!() };
    msg["result"]["sessionId"].as_str().unwrap().to_owned()
}

#[tokio::test]
async fn an_idle_host_whose_controller_is_gone_ends_after_its_wait() {
    let dir = scratch("orph-idle");
    let record = link::spawn(&launcher(), &orphan_spec(&dir, "s-orph-idle")).await.unwrap();
    let (owner, _) = connected(&record, 0).await;
    let mut logged = 0;
    started(&owner, &dir, &mut logged).await;
    // Every entry's ack is on the host's socket, as a daemon's long since are.
    owner.ack_written(logged, Duration::from_secs(10)).await.unwrap();
    // The daemon dies: no detach, and no daemon comes back.
    drop(owner);
    tokio::time::sleep(WAIT / 4).await;
    assert!(live(&dir, &record), "the host ended before its wait");
    assert!(
        ends_within(&dir, &record, Duration::from_secs(15)).await,
        "the idle host outlived its wait"
    );
    assert!(
        !agent_host::record_path(&dir.join("hosts"), "s-orph-idle").exists(),
        "the host left its record behind"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_host_with_its_controller_connected_never_ends_for_idleness() {
    let dir = scratch("orph-kept");
    let record = link::spawn(&launcher(), &orphan_spec(&dir, "s-orph-kept")).await.unwrap();
    let lock = live_lock(&dir, &record);
    let (owner, _) = connected(&record, 0).await;
    let mut logged = 0;
    started(&owner, &dir, &mut logged).await;
    tokio::time::sleep(WAIT * 3).await;
    assert!(live(&dir, &record), "an idle host ended while its controller was connected");
    // A restarted daemon reconnects within its wait: the wait starts again from there.
    owner.detach().await.expect("detach acknowledged");
    tokio::time::sleep(WAIT / 2).await;
    let (next, _) = connected(&record, logged).await;
    tokio::time::sleep(WAIT * 2).await;
    assert!(live(&dir, &record), "a host ended though a daemon came back within its wait");
    next.terminate(Duration::from_millis(500)).await.unwrap();
    read_until(&next, &mut logged, |e| matches!(e, Entry::Exit { .. })).await;
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_host_keeps_a_running_turn_and_its_unlogged_end_for_the_next_daemon() {
    let dir = scratch("orph-turn");
    let record = link::spawn(&launcher(), &orphan_spec(&dir, "s-orph-turn")).await.unwrap();
    let (first, _) = connected(&record, 0).await;
    let mut logged = 0;
    let sid = started(&first, &dir, &mut logged).await;
    let gate = dir.join("gate");
    make_fifo(&gate);
    let prompt = json!({"sessionId": sid, "prompt": [{"type":"text","text": format!("gate: {}", gate.display())}]});
    request(&first, 3, "session/prompt", prompt).await;
    read_until(&first, &mut logged, |e| chunk_text(e).as_deref() == Some("before-gate")).await;
    // The daemon dies mid-turn.
    drop(first);
    tokio::time::sleep(WAIT * 3).await;
    assert!(live(&dir, &record), "the host ended mid-turn");
    // The turn ends with no daemon: its end is in no log yet.
    std::fs::write(&gate, b"go").unwrap();
    tokio::time::sleep(WAIT * 3).await;
    assert!(live(&dir, &record), "the host ended with output no daemon logged");
    // A daemon comes back, logs the turn's end and hands the host off (the app's Quit); none
    // comes back again, and now the agent is idle.
    let (second, _) = connected(&record, logged).await;
    let rest = read_until(&second, &mut logged, |e| is_response(e, 3)).await;
    assert!(rest.iter().any(|(_, e)| chunk_text(e).as_deref() == Some("after-gate")), "{rest:?}");
    second.detach().await.expect("detach acknowledged");
    drop(second);
    assert!(
        ends_within(&dir, &record, Duration::from_secs(15)).await,
        "the idle host outlived its wait"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
