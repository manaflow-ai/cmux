//! Agent hosts (plans/cmux-next/durable-sessions.md section 2): a harness
//! runs under its own `__agent-host` process, keeps running while no
//! controller is attached, and a new controller resumes after the last entry
//! it logged without losing or repeating one.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process =
    daemon_env::Process::stand_in().with_env(&[("LC_API_TOKEN", "synthetic-locale-shaped-secret")]);

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
    HostLauncher { exe: daemon_env::bin().into(), prefix: Vec::new() }
}

fn spec(dir: &Path, session: &str) -> SpawnSpec {
    let hosts = dir.join("hosts");
    SpawnSpec {
        session_id: session.into(),
        program: "python3".into(),
        args: vec![FAKE.into()],
        // The stand-in's environment: never the host's (its PATH has real agents).
        env: daemon_env::vars(dir, daemon_env::Agents::StandIn, &[]),
        cwd: dir.to_path_buf(),
        translator: None,
        codex_bridge: false,
        socket: agent_host::socket_path(&hosts, session),
        hosts_dir: hosts,
        buffer_cap: agent_host::DEFAULT_BUFFER_CAP,
        router_owner_fifo: None,
        cwd_pin: None,
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

fn write_executable(path: &Path, text: &str) {
    use std::io::Write as _;
    use std::process::{Command, Stdio};
    let mut child = Command::new("/bin/sh")
        .args(["-c", "cat >\"$1\" && chmod 755 \"$1\"", "sh"])
        .arg(path)
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(text.as_bytes()).unwrap();
    assert!(child.wait().unwrap().success());
}

#[tokio::test]
async fn agent_host_parent_does_not_retain_the_controller_environment() {
    let dir = scratch("parent-env");
    let parent = dir.join("parent.txt");
    let wrapper = dir.join("agent");
    write_executable(
        &wrapper,
        &format!(
            "#!/bin/sh\nps eww -p \"$PPID\" > \"$PARENT_ENV_PROBE\" || exit 97\nexec python3 {}\n",
            daemon_env::sh_quote(FAKE)
        ),
    );
    let mut launch = spec(&dir, "s-parent-env");
    launch.program = wrapper.to_string_lossy().into_owned();
    launch.args.clear();
    launch.env.push(("PARENT_ENV_PROBE".into(), parent.to_string_lossy().into_owned()));
    let record = link::spawn(&launcher(), &launch).await.expect("spawn host");
    let lock = live_lock(&dir, &record);
    let (owner, _) = connected(&record, 0).await;
    let mut logged = 0;
    request(&owner, 1, "initialize", json!({"protocolVersion": 1})).await;
    read_until(&owner, &mut logged, |e| is_response(e, 1)).await;
    let observed = std::fs::read_to_string(&parent).unwrap();
    assert!(observed.contains("HOME="), "the parent-environment control was empty");
    for name in ["ACPMUX_TEST_HERMETIC=", "CARGO_MANIFEST_DIR=", "LC_API_TOKEN="] {
        assert!(!observed.contains(name), "agent host parent retained {name}");
    }
    owner.terminate(Duration::from_millis(500)).await.unwrap();
    read_until(&owner, &mut logged, |e| matches!(e, Entry::Exit { .. })).await;
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
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

/// A host whose start fails (here the harness cannot be spawned) leaves no
/// liveness lock file behind: a stale `.live` file would outlive the session.
#[tokio::test]
async fn a_failed_start_leaves_no_live_file() {
    let dir = scratch("nolive");
    let mut spec = spec(&dir, "s-nolive");
    spec.program = "/nonexistent/harness".into();
    const SENTINEL: &str = "argv-secret-must-not-leave-the-daemon";
    spec.args = vec!["--token".into(), SENTINEL.into()];
    let error = link::spawn(&launcher(), &spec).await.expect_err("a missing harness started");
    assert!(!error.to_string().contains(SENTINEL), "spawn failure exposed harness argv: {error:#}");
    let left: Vec<_> = std::fs::read_dir(dir.join("hosts"))
        .expect("the host created its hosts dir")
        .filter_map(|e| e.ok().map(|e| e.file_name()))
        .collect();
    assert!(
        !left
            .iter()
            .any(|n| n.to_string_lossy().ends_with(".live")
                || n.to_string_lossy().ends_with(".sock")),
        "a failed start left {left:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_start_waits_for_a_harness_binary_an_update_is_replacing() {
    // `npm install --global` removes the package and its bin link and writes
    // them again; a chat started in between failed with "spawn harness
    // process: No such file or directory (os error 2)".
    let dir = scratch("replaced");
    let bin = dir.join("lib").join("bin");
    let program = bin.join("agent");
    let mut launch = spec(&dir, "s-replaced");
    launch.program = program.to_string_lossy().into_owned();
    launch.args.clear();
    let host = launcher();
    let mut start = std::pin::pin!(agent_host::program_wait::spawn_within(
        &host,
        &launch,
        Duration::from_secs(20)
    ));
    // The start waits while the program is missing.
    assert!(
        tokio::time::timeout(Duration::from_millis(300), &mut start).await.is_err(),
        "the start did not wait for the missing program"
    );
    // The update writes the package, then links the program into place.
    std::fs::create_dir_all(&bin).unwrap();
    let staged = dir.join("agent.staged");
    write_executable(&staged, &format!("#!/bin/sh\nexec python3 {}\n", daemon_env::sh_quote(FAKE)));
    std::fs::rename(&staged, &program).unwrap();
    let record = start.await.expect("the start waited for the program");
    let lock = live_lock(&dir, &record);
    let (owner, _) = connected(&record, 0).await;
    let mut logged = 0;
    request(&owner, 1, "initialize", json!({"protocolVersion": 1})).await;
    read_until(&owner, &mut logged, |e| is_response(e, 1)).await;
    owner.terminate(Duration::from_millis(500)).await.unwrap();
    read_until(&owner, &mut logged, |e| matches!(e, Entry::Exit { .. })).await;
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_harness_binary_that_never_comes_back_names_its_path() {
    let dir = scratch("gone");
    let mut launch = spec(&dir, "s-gone");
    launch.program = dir.join("missing").join("agent").to_string_lossy().into_owned();
    let error =
        agent_host::program_wait::spawn_within(&launcher(), &launch, Duration::from_millis(200))
            .await
            .expect_err("a missing harness started");
    assert!(error.to_string().contains(&launch.program), "{error:#}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn discovery_rejects_linked_records_and_socket_paths_outside_the_host_namespace() {
    use std::os::unix::fs::PermissionsExt;

    let dir = scratch("record-paths");
    let hosts = dir.join("hosts");
    std::fs::create_dir_all(&hosts).unwrap();
    std::fs::set_permissions(&hosts, std::fs::Permissions::from_mode(0o755)).unwrap();
    let outside_socket = dir.join("must-not-be-removed");
    std::fs::write(&outside_socket, "sentinel").unwrap();
    let record = |session_id: &str, socket: PathBuf| HostRecord {
        record_version: acpmux::agent_host::RECORD_VERSION,
        session_id: session_id.into(),
        incarnation: "11".repeat(16),
        host_pid: std::process::id(),
        start_nonce: "22".repeat(16),
        harness_pid: None,
        owner_token: "33".repeat(32),
        caller_token: None,
        protocol_min: acpmux::agent_host::PROTOCOL_MIN,
        protocol_max: acpmux::agent_host::PROTOCOL_MAX,
        host_build: "test".into(),
        socket,
    };
    let wrong = record("wrong-socket", outside_socket.clone());
    let wrong_path = hosts.join("wrong-socket.json");
    std::fs::write(&wrong_path, serde_json::to_vec(&wrong).unwrap()).unwrap();
    std::fs::set_permissions(&wrong_path, std::fs::Permissions::from_mode(0o600)).unwrap();

    let linked = record("linked", acpmux::agent_host::socket_path(&hosts, "linked"));
    let linked_target = dir.join("linked-record.json");
    std::fs::write(&linked_target, serde_json::to_vec(&linked).unwrap()).unwrap();
    std::os::unix::fs::symlink(&linked_target, hosts.join("linked.json")).unwrap();

    let promoted = record(
        "promoted",
        acpmux::agent_host::socket_path(&acpmux::agent_host::pool_dir(&hosts), "promoted"),
    );
    acpmux::agent_host::write_record_atomic(&hosts.join("promoted.json"), &promoted).unwrap();

    let (good, bad) = acpmux::agent_host::load_records(&hosts).unwrap();
    assert_eq!(
        good.iter().map(|(_, record)| record.session_id.as_str()).collect::<Vec<_>>(),
        ["promoted"],
        "a promoted pool socket is valid, but no other path is: {good:#?}"
    );
    assert_eq!(bad.len(), 2, "each refused record is reported: {bad:#?}");
    assert!(outside_socket.exists(), "discovery removed a path outside the hosts directory");
    assert_eq!(std::fs::symlink_metadata(&hosts).unwrap().permissions().mode() & 0o777, 0o700);
    let _ = std::fs::remove_dir_all(&dir);
}

/// A harness that reads nothing for 3 s, then everything (`a_fenced_line_*`).
fn slow_reader(dir: &Path, session: &str) -> SpawnSpec {
    let slow = dir.join("agent");
    write_executable(&slow, "#!/bin/sh\nsleep 3\nexec cat >/dev/null\n");
    let mut launch = spec(dir, session);
    launch.program = slow.to_string_lossy().into_owned();
    launch.args.clear();
    launch
}

/// A harness that never reads its stdin.
fn never_reader(dir: &Path, session: &str) -> SpawnSpec {
    let idle = dir.join("agent");
    write_executable(&idle, "#!/bin/sh\nexec sleep 60\n");
    let mut launch = spec(dir, session);
    launch.program = idle.to_string_lossy().into_owned();
    launch.args.clear();
    launch
}

/// An agent on `record`'s host, whose log takes every entry (`logs`) or none.
async fn hosted_agent(
    record: &HostRecord,
    logs: bool,
) -> std::sync::Arc<acpmux::agent::ChildAgent> {
    let (inbound, _) = tokio::sync::mpsc::channel(64);
    let tap: acpmux::agent::Tap = std::sync::Arc::new(move |_, _, _| logs);
    let attached = acpmux::agent::ChildAgent::attach_hosted(
        "fake",
        record.clone(),
        0,
        Vec::new(),
        inbound,
        tap,
    )
    .await
    .unwrap();
    let acpmux::agent::Attached::Ready(agent, ..) = attached else {
        panic!("the host refused its controller")
    };
    agent
}

/// Review 87 of #23322: a fenced request whose connection another controller took is answered
/// here with this side's own "agent process closed", which proves nothing about its line: it
/// stays unsettled, also past any fixed wait, until its host's death is proven.
#[tokio::test]
async fn a_fenced_request_cut_off_by_a_new_controller_settles_only_with_its_host() {
    let dir = scratch("fenced-taken");
    let record = link::spawn(&launcher(), &never_reader(&dir, "s-fenced-taken")).await.unwrap();
    let lock = live_lock(&dir, &record);
    let agent = hosted_agent(&record, true).await;
    let fence = acpmux::agent::Fence::default();
    let request = {
        let (agent, fence) = (agent.clone(), fence.clone());
        tokio::spawn(async move {
            let params = json!({"text": "x".repeat(1 << 20)});
            agent.request_with_hook("note", params, Some(&fence), || {}).await
        })
    };
    tokio::time::sleep(Duration::from_millis(300)).await;
    let (_second, _) = connected(&record, 0).await;
    let answered = tokio::time::timeout(Duration::from_secs(10), request).await;
    assert!(answered.expect("the request ends").unwrap().is_err());
    assert!(!fence.is_settled(), "a line its host still has counted written");
    tokio::time::sleep(Duration::from_secs(7)).await;
    assert!(!fence.is_settled(), "a line its living host still has settled");
    // SAFETY: the host this test spawned; its live lock is held, so the pid is its own.
    unsafe { libc::kill(record.host_pid as i32, libc::SIGKILL) };
    wait_dead(lock).await;
    tokio::time::timeout(Duration::from_secs(10), fence.settled())
        .await
        .expect("the line settles once its host is gone");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review 85 of #23322: a host killed while it still writes a fenced answer (no `Exit`, no
/// receipt) settles that answer once its death is proven, so nothing waits on it forever; also
/// when its controller stopped reading because an entry could not be logged (review 87).
#[tokio::test]
async fn a_fenced_answer_settles_once_its_host_is_killed() {
    let dir = scratch("fenced-killed");
    let record = link::spawn(&launcher(), &never_reader(&dir, "s-fenced-killed")).await.unwrap();
    let lock = live_lock(&dir, &record);
    let agent = hosted_agent(&record, false).await;
    let fence = acpmux::agent::Fence::default();
    let answer = Ok(json!({"text": "x".repeat(1 << 20)}));
    agent.respond_fenced(json!(1), answer, Some(&fence)).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    // SAFETY: the host this test spawned; its live lock is held, so the pid is its own.
    unsafe { libc::kill(record.host_pid as i32, libc::SIGKILL) };
    wait_dead(lock).await;
    tokio::time::timeout(Duration::from_secs(15), fence.settled())
        .await
        .expect("a fenced answer its killed host never wrote settles");
    let _ = std::fs::remove_dir_all(&dir);
}

/// Review 87 of #23322, rounds 4 and 5: no answer to a fenced request on a host that gives no
/// receipt proves its line was written: an error a translator makes up once its harness's
/// output ended (the Codex bridge), nor a result it makes up for a prompt it gave up on
/// (Claude's `cancelled`). The line stays unsettled while its host lives.
#[tokio::test]
async fn an_answer_does_not_settle_a_request_its_host_still_writes() {
    let dir = scratch("fenced-answered");
    let error = json!({"jsonrpc": "2.0", "id": 1,
        "error": {"code": -32603, "message": "codex app-server stopped: it exited"}});
    let result = json!({"jsonrpc": "2.0", "id": 2, "result": {"stopReason": "cancelled"}});
    let harness = dir.join("agent");
    let script = format!("#!/bin/sh\nsleep 1\necho '{error}'\necho '{result}'\nexec sleep 60\n");
    write_executable(&harness, &script);
    let mut launch = spec(&dir, "s-fenced-answered");
    launch.program = harness.to_string_lossy().into_owned();
    launch.args.clear();
    let record = link::spawn(&launcher(), &launch).await.unwrap();
    let lock = live_lock(&dir, &record);
    // Before host protocol 2 every host gives no receipt.
    let agent = hosted_agent(&record, true).await;
    let (first, second) = (acpmux::agent::Fence::default(), acpmux::agent::Fence::default());
    // The first, 1 MiB, fills the harness's stdin, which it never reads; the second waits behind.
    let big = json!({"text": "x".repeat(1 << 20)});
    let one = agent.request_with_hook("note", big, Some(&first), || {});
    let two = async {
        tokio::time::sleep(Duration::from_millis(200)).await;
        agent.request_with_hook("note", json!({}), Some(&second), || {}).await
    };
    let answered =
        tokio::time::timeout(Duration::from_secs(10), async { tokio::join!(one, two) }).await;
    let settled = (first.is_settled(), second.is_settled());
    // SAFETY: the host this test spawned; its live lock is held, so the pid is its own.
    unsafe { libc::kill(record.host_pid as i32, libc::SIGKILL) };
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
    let (one, two) = answered.expect("both made-up answers come");
    assert!(one.is_err() && two.is_ok(), "{one:?} {two:?}");
    assert_eq!(
        settled,
        (false, false),
        "an answer counted a line its host still writes as written"
    );
}

/// Review 87 of #23322, round 3: a harness that exits while a descendant keeps its stdin leaves
/// its host still writing a fenced line. The harness's `Exit` proves nothing of that line, which
/// stays unsettled while its host lives, also when that `Exit` is never acknowledged.
#[tokio::test]
async fn a_harness_exit_does_not_settle_a_line_its_host_still_writes() {
    let dir = scratch("fenced-kept");
    let pid_file = dir.join("kept.pid");
    let hold = format!(
        "import os, time; os.setsid(); open('{}', 'w').write(str(os.getpid())); time.sleep(30)",
        pid_file.display()
    );
    let kept = dir.join("agent");
    // The harness exits only once its descendant left its group, so the host's end of the
    // harness's group does not take it.
    let script = format!(
        "#!/bin/sh\nexec 3<&0\npython3 -c \"{hold}\" <&3 3<&- >/dev/null 2>&1 &\nuntil [ -s '{}' ]; do sleep 0.05; done\nexit 0\n",
        pid_file.display()
    );
    write_executable(&kept, &script);
    let mut launch = spec(&dir, "s-fenced-kept");
    launch.program = kept.to_string_lossy().into_owned();
    launch.args.clear();
    let record = link::spawn(&launcher(), &launch).await.unwrap();
    let lock = live_lock(&dir, &record);
    let agent = hosted_agent(&record, false).await;
    let fence = acpmux::agent::Fence::default();
    let answer = Ok(json!({"text": "x".repeat(1 << 20)}));
    agent.respond_fenced(json!(1), answer, Some(&fence)).await.unwrap();
    // Its harness exited and its host said so; its host still writes the line.
    tokio::time::sleep(Duration::from_secs(2)).await;
    let settled = fence.is_settled();
    // SAFETY: the host this test spawned; its live lock is held, so the pid is its own.
    unsafe { libc::kill(record.host_pid as i32, libc::SIGKILL) };
    if let Some(pid) = std::fs::read_to_string(&pid_file).ok().and_then(|p| p.parse().ok()) {
        // SAFETY: the descendant this test started, which sleeps holding its pid.
        unsafe { libc::kill(pid, libc::SIGKILL) };
    }
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
    assert!(!settled, "a harness's exit settled a line its host was still writing");
}

/// Review 85 of #23322: a fenced line to a protocol-1 host (an answer, which gets no answer of
/// its own) has no receipt. A cut that finds it unproven fails closed: it ends that host by its
/// start nonce, and the line can not reach the harness after it.
#[tokio::test]
async fn a_cut_of_an_unproven_line_to_a_protocol_1_host_ends_that_host() {
    let dir = scratch("cut-v1");
    let record = link::spawn(&launcher(), &slow_reader(&dir, "s-cut-v1")).await.unwrap();
    let lock = live_lock(&dir, &record);
    let (owner, _) = connected(&record, 0).await;
    let fence = acpmux::agent::Fence::default();
    let answer = json!({"jsonrpc": "2.0", "id": 1, "result": {"text": "x".repeat(1 << 20)}});
    owner.line_fenced(answer, Some(fence.clone())).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!fence.is_settled(), "a protocol-1 host's line counted written with no receipt");
    let hosts = dir.join("hosts");
    // The writer `cut_or_end` names for a hosted line: its host, ended by its start nonce.
    let ended = agent_host::terminate_unadoptable(
        &hosts,
        &record.session_id,
        Some(&record.start_nonce),
        Some(record.host_pid),
    )
    .unwrap();
    assert!(ended, "the host was not ended");
    link::settle_receipts_of(&record.incarnation);
    assert!(fence.is_settled(), "the line still waits after its host ended");
    wait_dead(lock).await;
    let _ = std::fs::remove_dir_all(&dir);
}
