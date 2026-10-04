//! Agent hosts (plans/cmux-next/durable-sessions.md section 2): a harness
//! runs under its own `__agent-host` process, keeps running while no
//! controller is attached, and a new controller resumes after the last entry
//! it logged without losing or repeating one.
#![cfg(unix)]

use acpmux::agent_host::link::{self, Connect, HostLauncher, Link};
use acpmux::agent_host::{
    self, ControllerFrame, Entry, HostFrame, HostRecord, Liveness, SpawnSpec, TapDir,
};
use serde_json::{Value, json};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::Duration;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn scratch(tag: &str) -> PathBuf {
    // Short: socket paths must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amh-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn launcher() -> HostLauncher {
    HostLauncher { exe: env!("CARGO_BIN_EXE_acpmux").into(), prefix: Vec::new() }
}

fn spec(dir: &Path, session: &str) -> SpawnSpec {
    let hosts = dir.join("hosts");
    SpawnSpec {
        session_id: session.into(),
        program: "python3".into(),
        args: vec![FAKE.into()],
        env: std::env::vars().collect(),
        cwd: dir.to_path_buf(),
        translator: None,
        socket: agent_host::socket_path(&hosts, session),
        hosts_dir: hosts,
        buffer_cap: agent_host::DEFAULT_BUFFER_CAP,
    }
}

/// Opens the host's liveness lock so the test can wait for its death
/// without timers: a blocking lock returns when the host process exits.
fn live_lock(dir: &Path, record: &HostRecord) -> std::fs::File {
    let path = dir.join("hosts").join(format!("{}.{}.live", record.session_id, record.start_nonce));
    std::fs::OpenOptions::new().read(true).write(true).open(path).expect("live lock")
}

async fn wait_dead(lock: std::fs::File) {
    tokio::time::timeout(
        Duration::from_secs(20),
        tokio::task::spawn_blocking(move || {
            // SAFETY: flock on a descriptor this test owns.
            assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
        }),
    )
    .await
    .expect("host exited in time")
    .unwrap();
}

async fn connected(record: &HostRecord, after: u64) -> (Box<Link>, link::Adopted) {
    match link::connect(record.clone(), after).await.expect("connect") {
        Connect::Ready(link, adopted) => (link, adopted),
        Connect::Incompatible { .. } => panic!("host refused a same-build controller"),
    }
}

/// Reads entries, acknowledging each, until `until` matches one; returns
/// every entry read and checks that sequences are contiguous after `after`.
async fn read_until(
    link: &Link,
    after: &mut u64,
    until: impl Fn(&Entry) -> bool,
) -> Vec<(u64, Entry)> {
    let mut seen = Vec::new();
    let mut rx = link.entries.lock().await;
    loop {
        let (h, e) = tokio::time::timeout(Duration::from_secs(20), rx.recv())
            .await
            .expect("entry in time")
            .expect("host connection open");
        assert_eq!(h, *after + 1, "entries must be contiguous and never repeat: {e:?}");
        *after = h;
        link.ack(h).await.unwrap();
        let done = until(&e);
        seen.push((h, e));
        if done {
            return seen;
        }
    }
}

fn is_response(e: &Entry, id: i64) -> bool {
    matches!(e, Entry::In { msg } if msg.get("id") == Some(&json!(id)) && msg.get("method").is_none())
}

fn chunk_text(e: &Entry) -> Option<String> {
    let Entry::In { msg } = e else { return None };
    let update = msg.get("params")?.get("update")?;
    (update.get("sessionUpdate")? == "agent_message_chunk")
        .then(|| update["content"]["text"].as_str().unwrap_or_default().to_owned())
}

async fn request(link: &Link, id: i64, method: &str, params: Value) {
    link.line(json!({"jsonrpc":"2.0","id":id,"method":method,"params":params})).await.unwrap();
}

fn make_fifo(path: &Path) {
    let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
}

#[tokio::test]
async fn host_keeps_the_turn_running_without_a_controller_and_resumes_exactly() {
    let dir = scratch("resume");
    let record = link::spawn(&launcher(), &spec(&dir, "s-resume")).await.expect("spawn host");
    let lock = live_lock(&dir, &record);
    assert_eq!(
        agent_host::liveness(&dir.join("hosts"), &record.session_id, &record.start_nonce),
        Liveness::Live
    );

    let (first, adopted) = connected(&record, 0).await;
    assert_eq!(adopted.last_h, 0);
    let mut logged = 0;
    request(&first, 1, "initialize", json!({"protocolVersion": 1})).await;
    read_until(&first, &mut logged, |e| is_response(e, 1)).await;
    request(&first, 2, "session/new", json!({"cwd": dir, "mcpServers": []})).await;
    let new = read_until(&first, &mut logged, |e| is_response(e, 2)).await;
    let Entry::In { msg } = &new.last().unwrap().1 else { unreachable!() };
    let sid = msg["result"]["sessionId"].as_str().unwrap().to_owned();

    // The written request comes back as an `out` tap before the agent's reply.
    let gate = dir.join("gate");
    make_fifo(&gate);
    let prompt = json!({"sessionId": sid, "prompt": [{"type":"text","text": format!("gate: {}", gate.display())}]});
    request(&first, 3, "session/prompt", prompt).await;
    let before =
        read_until(&first, &mut logged, |e| chunk_text(e).as_deref() == Some("before-gate")).await;
    assert!(
        before
            .iter()
            .any(|(_, e)| matches!(e, Entry::Tap { dir: TapDir::Out, msg } if msg["id"] == 3))
    );

    // The controller dies mid-turn: no detach.
    drop(first);
    // The turn finishes while no controller is attached.
    std::fs::write(&gate, b"go").unwrap();

    let (second, adopted) = connected(&record, logged).await;
    assert_eq!(adopted.max_out_id, 3, "a new controller must continue ids above 3");
    assert!(adopted.exited.is_none());
    let rest = read_until(&second, &mut logged, |e| is_response(e, 3)).await;
    assert!(
        rest.iter().any(|(_, e)| chunk_text(e).as_deref() == Some("after-gate")),
        "output produced while no controller was attached was lost: {rest:?}"
    );

    second.terminate(Duration::from_millis(500)).await.unwrap();
    read_until(&second, &mut logged, |e| matches!(e, Entry::Exit { .. })).await;
    wait_dead(lock).await;
    assert!(!agent_host::record_path(&dir.join("hosts"), "s-resume").exists());
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn detach_hands_off_and_a_second_owner_supersedes_the_first() {
    let dir = scratch("detach");
    let record = link::spawn(&launcher(), &spec(&dir, "s-detach")).await.unwrap();
    let lock = live_lock(&dir, &record);
    let (first, _) = connected(&record, 0).await;
    let mut logged = 0;
    request(&first, 1, "initialize", json!({"protocolVersion": 1})).await;
    read_until(&first, &mut logged, |e| is_response(e, 1)).await;
    first.detach().await.expect("detach acknowledged");

    let (second, adopted) = connected(&record, logged).await;
    assert_eq!(adopted.acked_h, logged);
    let (third, _) = connected(&record, logged).await;
    // The superseded owner's connection closes; the new one works.
    let mut rx = second.entries.lock().await;
    assert!(tokio::time::timeout(Duration::from_secs(10), rx.recv()).await.unwrap().is_none());
    drop(rx);
    request(&third, 2, "initialize", json!({"protocolVersion": 1})).await;
    read_until(&third, &mut logged, |e| is_response(e, 2)).await;

    third.terminate(Duration::from_millis(500)).await.unwrap();
    read_until(&third, &mut logged, |e| matches!(e, Entry::Exit { .. })).await;
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn an_incompatible_controller_is_refused_and_the_agent_keeps_running() {
    let dir = scratch("incompat");
    let record = link::spawn(&launcher(), &spec(&dir, "s-incompat")).await.unwrap();
    let lock = live_lock(&dir, &record);

    let stream = tokio::net::UnixStream::connect(&record.socket).await.unwrap();
    let (mut rd, mut wr) = stream.into_split();
    agent_host::write_frame(
        &mut wr,
        &ControllerFrame::Hello {
            min: 9,
            max: 9,
            token: record.owner_token.clone(),
            controller_build: "future".into(),
        },
    )
    .await
    .unwrap();
    let reply: HostFrame = agent_host::read_frame(&mut rd).await.unwrap().unwrap();
    assert!(
        matches!(reply, HostFrame::Incompatible { min: 1, max: 1, .. }),
        "expected Incompatible, got {reply:?}"
    );
    assert_eq!(
        agent_host::liveness(&dir.join("hosts"), &record.session_id, &record.start_nonce),
        Liveness::Live,
        "refusing a controller must not end the agent"
    );

    // The version-independent end path: no protocol, proof by the live lock.
    // Without the nonce that names its lock there is no proof: no signal.
    assert!(
        !agent_host::terminate_unadoptable(
            &dir.join("hosts"),
            &record.session_id,
            None,
            Some(record.host_pid),
        )
        .unwrap()
    );
    let ended = agent_host::terminate_unadoptable(
        &dir.join("hosts"),
        &record.session_id,
        Some(&record.start_nonce),
        Some(record.host_pid),
    )
    .unwrap();
    assert!(ended);
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_wrong_token_gets_no_hello() {
    let dir = scratch("token");
    let record = link::spawn(&launcher(), &spec(&dir, "s-token")).await.unwrap();
    let lock = live_lock(&dir, &record);
    let mut forged = record.clone();
    forged.owner_token = "00".repeat(32);
    assert!(link::connect(forged, 0).await.is_err(), "a forged token must not adopt the host");
    let (owner, _) = connected(&record, 0).await;
    let mut logged = 0;
    owner.terminate(Duration::from_millis(500)).await.unwrap();
    read_until(&owner, &mut logged, |e| matches!(e, Entry::Exit { .. })).await;
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
}

/// A harness whose child calls setsid keeps the output pipe open after the
/// harness exits. The host still reports the exit after a bounded drain
/// instead of waiting for that pipe forever (and living forever).
#[tokio::test]
async fn an_escaped_grandchild_does_not_hold_back_the_exit() {
    let dir = scratch("escape");
    let pid_file = dir.join("grandchild.pid");
    let mut spec = spec(&dir, "s-escape");
    spec.program = "python3".into();
    spec.args = vec![
        "-c".into(),
        format!(
            "import os,time\nif os.fork()==0:\n    os.setsid()\n    open({:?},'w').write(str(os.getpid()))\n    time.sleep(60)\nelse:\n    time.sleep(0.2)\n    os._exit(0)\n",
            pid_file.display().to_string()
        ),
    ];
    let record = link::spawn(&launcher(), &spec).await.expect("spawn host");
    let (link, _) = connected(&record, 0).await;
    let lock = live_lock(&dir, &record);
    let mut after = 0;
    let exited = tokio::time::timeout(
        Duration::from_secs(15),
        read_until(&link, &mut after, |e| matches!(e, Entry::Exit { .. })),
    )
    .await;
    // End the escaped grandchild this test started.
    if let Ok(pid) =
        std::fs::read_to_string(&pid_file).map(|p| p.trim().parse::<i32>().unwrap_or(0))
        && pid > 0
    {
        // SAFETY: the pid this test's harness wrote for its own grandchild.
        unsafe { libc::kill(pid, libc::SIGKILL) };
    }
    assert!(exited.is_ok(), "the host never reported the harness exit");
    // The host itself ends once its Exit is acknowledged.
    wait_dead(lock).await;
    drop(link);
    let _ = std::fs::remove_dir_all(&dir);
}

/// Output that back-pressure keeps in the pipe is not a hung pipe: with no
/// controller to acknowledge entries, the host stops reading at its buffer
/// cap, and the harness exits meanwhile. Every line still arrives before
/// the Exit once a controller reads them, however late it connects.
#[tokio::test]
async fn paced_output_left_in_the_pipe_at_exit_is_kept() {
    let dir = scratch("paced");
    let mut spec = spec(&dir, "s-paced");
    // About 20 KB of lines: above the cap, below a pipe's buffer, so the
    // harness writes them all and exits while most are still unread.
    spec.buffer_cap = 4096;
    spec.program = "python3".into();
    spec.args = vec![
        "-c".into(),
        "import json,sys\nfor i in range(300):\n    print(json.dumps({'jsonrpc':'2.0','method':'x/line','params':{'i':i}}))\nsys.stdout.flush()\n".into(),
    ];
    let record = link::spawn(&launcher(), &spec).await.expect("spawn host");
    let lock = live_lock(&dir, &record);
    // Longer than the drain period: the harness has exited by now.
    tokio::time::sleep(Duration::from_secs(4)).await;
    let (link, _) = connected(&record, 0).await;
    let mut after = 0;
    let seen = read_until(&link, &mut after, |e| matches!(e, Entry::Exit { .. })).await;
    let lines = seen
        .iter()
        .filter(
            |(_, e)| matches!(e, Entry::In { msg } if msg.get("method") == Some(&json!("x/line"))),
        )
        .count();
    assert_eq!(lines, 300, "lines still in the pipe at the harness exit were dropped");
    wait_dead(lock).await;
    drop(link);
    let _ = std::fs::remove_dir_all(&dir);
}
