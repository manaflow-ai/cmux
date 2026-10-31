//! A host whose daemon never comes back ends once its agent is idle (`SpawnSpec::orphan_exit`),
//! never while a controller is connected and never mid-turn: hosts outlive their daemon on
//! purpose (an update, a crash, a restart, the app's Quit), but with nothing to adopt them they
//! ran forever (Leo, 2026-10-30: "JUST FUCKING REMOVE THE FUCKING OLD DAMEMONS").

use super::*;

/// The test's wait for a controller, far below the daemon's ([`agent_host::ORPHAN_IDLE`]).
const WAIT: Duration = Duration::from_millis(1000);

fn orphan_spec(dir: &Path, session: &str) -> SpawnSpec {
    let mut spec = spec(dir, session);
    spec.orphan_exit = Some(agent_host::OrphanExit {
        idle_ms: WAIT.as_millis() as u64,
        servers: Vec::new(),
        path: String::new(),
        cwd: std::path::PathBuf::new(),
    });
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

/// A daemon that died after it started a host but before it connected: the harness never wrote
/// a line, so no event ever came. The host's wait starts as it starts serving (review 1).
#[tokio::test]
async fn a_host_no_controller_ever_reached_ends_after_its_wait() {
    let dir = scratch("orph-never");
    let record = link::spawn(&launcher(), &orphan_spec(&dir, "s-orph-never")).await.unwrap();
    assert!(
        ends_within(&dir, &record, Duration::from_secs(15)).await,
        "a host no controller reached outlived its wait"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// A daemon that connects while the host ends its harness (between SIGTERM and SIGKILL) is
/// answered only once the harness's exit is in, so it never starts a turn on a dying harness and
/// is told it exited; it logs the exit and the host ends as every host does (review 4).
#[tokio::test]
async fn a_daemon_connecting_while_the_harness_ends_is_told_it_exited() {
    let dir = scratch("orph-late");
    let term = dir.join("term");
    let agent = dir.join("agent");
    // Notes its SIGTERM and runs on until the SIGKILL, with nothing running under it (the
    // census would keep a harness with a child up).
    write_executable(
        &agent,
        "#!/usr/bin/env python3\nimport os, signal, sys\n\
         signal.signal(signal.SIGTERM, lambda *_: open(os.environ['TERM_NOTE'], 'w').close())\n\
         while True: signal.pause()\n",
    );
    let mut launch = orphan_spec(&dir, "s-orph-late");
    launch.program = agent.to_string_lossy().into_owned();
    launch.args.clear();
    launch.env.push(("TERM_NOTE".into(), term.to_string_lossy().into_owned()));
    let record = link::spawn(&launcher(), &launch).await.unwrap();
    let lock = live_lock(&dir, &record);
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    while !term.exists() {
        assert!(std::time::Instant::now() < deadline, "the idle host never ended its harness");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    let (late, adopted) = connected(&record, 0).await;
    // The harness wrote nothing: its exit is the one entry, numbered before the answer. (A
    // killed harness's `exited` is `Some(None)`, which reads back as none on the wire.)
    assert_eq!(adopted.last_h, 1, "a hello during the end was answered before the exit");
    let mut logged = 0;
    read_until(&late, &mut logged, |e| matches!(e, Entry::Exit { .. })).await;
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// What the harness writes as it ends (on its SIGTERM) is kept for a daemon for one more wait:
/// one that connects then logs it with the exit (review 5).
#[tokio::test]
async fn what_the_harness_writes_as_it_ends_waits_for_a_daemon() {
    let dir = scratch("orph-last");
    let agent = dir.join("agent");
    write_executable(
        &agent,
        "#!/usr/bin/env python3\nimport signal, sys\n\
         def last(*_):\n    \
         print('{\"jsonrpc\":\"2.0\",\"method\":\"note\",\"params\":{\"text\":\"bye\"}}', flush=True)\n    \
         sys.exit(0)\n\
         signal.signal(signal.SIGTERM, last)\n\
         while True: signal.pause()\n",
    );
    let mut launch = orphan_spec(&dir, "s-orph-last");
    launch.program = agent.to_string_lossy().into_owned();
    launch.args.clear();
    let record = link::spawn(&launcher(), &launch).await.unwrap();
    let lock = live_lock(&dir, &record);
    let harness = record.harness_pid.unwrap() as i32;
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    // SAFETY: signal 0 only checks that the harness still exists.
    while unsafe { libc::kill(harness, 0) } == 0 {
        assert!(std::time::Instant::now() < deadline, "the idle host never ended its harness");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    tokio::time::sleep(WAIT / 2).await;
    assert!(live(&dir, &record), "the host let go of its harness's last line at once");
    let (late, _) = connected(&record, 0).await;
    let mut logged = 0;
    let read = read_until(&late, &mut logged, |e| matches!(e, Entry::Exit { .. })).await;
    assert!(read.iter().any(|(_, e)| format!("{e:?}").contains("bye")), "{read:?}");
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// What the harness writes as it ends can be more than the buffer cap holds with no daemon to
/// read it: the exit entry then never comes, and the host ends at the end's own deadline
/// instead of running on for good (review 6).
#[tokio::test]
async fn an_end_whose_output_the_buffer_cap_holds_back_still_ends() {
    let dir = scratch("orph-cap");
    let agent = dir.join("agent");
    write_executable(
        &agent,
        "#!/usr/bin/env python3\nimport signal, sys\n\
         def last(*_):\n    \
         for i in range(400):\n        \
         print('{\"jsonrpc\":\"2.0\",\"method\":\"note\",\"params\":{\"text\":\"%s\"}}' % ('x' * 64), flush=True)\n    \
         sys.exit(0)\n\
         signal.signal(signal.SIGTERM, last)\n\
         while True: signal.pause()\n",
    );
    let mut launch = orphan_spec(&dir, "s-orph-cap");
    launch.program = agent.to_string_lossy().into_owned();
    launch.args.clear();
    launch.buffer_cap = 4096;
    let record = link::spawn(&launcher(), &launch).await.unwrap();
    assert!(
        ends_within(&dir, &record, Duration::from_secs(20)).await,
        "a host whose last output the buffer cap held back outlived its end"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
