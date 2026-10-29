//! A panic in an `__agent-host` process must never be
//! lost. The host runs detached with no stdio, so the controller names the
//! home's `agent-host-panics.jsonl` and the host appends each panic there;
//! the cmux-next app sends new lines to Sentry.
#![cfg(all(unix, debug_assertions))]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs a stand-in agent; every host it starts panics a worker thread once.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::stand_in().with_env(&[("ACPMUX_TEST_AGENT_HOST_PANIC", "thread")]);

use acpmux::agent_host::link::{self, Connect, HostLauncher};
use acpmux::agent_host::{self, Entry, Liveness, SpawnSpec};
use std::os::fd::AsRawFd;
use std::time::{Duration, Instant};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

#[tokio::test]
async fn agent_host_panic_log_gets_one_line_and_the_host_keeps_its_harness() {
    // Short: socket paths must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("amh-panic-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    // The host refuses a state directory others can write, whatever the umask.
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let log = agent_host::panic_log_path();
    std::fs::create_dir_all(log.parent().unwrap()).unwrap();
    let _ = std::fs::remove_file(&log);
    let hosts = dir.join("hosts");
    let session = "s-panic";
    let spec = SpawnSpec {
        session_id: session.into(),
        program: "python3".into(),
        args: vec![FAKE.into()],
        env: daemon_env::vars(&dir, daemon_env::Agents::StandIn, &[]),
        cwd: dir.clone(),
        cwd_pin: None,
        translator: None,
        codex_bridge: false,
        socket: agent_host::socket_path(&hosts, session),
        hosts_dir: hosts.clone(),
        buffer_cap: agent_host::DEFAULT_BUFFER_CAP,
        router_owner_fifo: None,
    };
    let launcher = HostLauncher { exe: daemon_env::bin().into(), prefix: Vec::new() };
    let record = link::spawn(&launcher, &spec).await.expect("spawn host");

    let deadline = Instant::now() + Duration::from_secs(20);
    let text = loop {
        let text = std::fs::read_to_string(&log).unwrap_or_default();
        if text.ends_with('\n') {
            break text;
        }
        assert!(Instant::now() < deadline, "no agent host panic line at {}", log.display());
        tokio::time::sleep(Duration::from_millis(20)).await;
    };
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 1, "{text}");
    let line: serde_json::Value = serde_json::from_str(lines[0]).unwrap();
    assert_eq!(line["process"], "acpmux-agent-host", "{line}");
    assert_eq!(line["message"], "acpmux agent host test panic", "{line}");
    assert_eq!(line["thread"], "agent-host-panic-test", "{line}");
    assert_eq!(line["test"], true, "{line}");
    assert_eq!(line["pid"].as_u64(), Some(u64::from(record.host_pid)), "{line}");
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&log).unwrap().permissions().mode() & 0o777, 0o600);
    }

    // The panic ended only its own thread: the host still keeps the harness.
    assert_eq!(agent_host::liveness(&hosts, session, &record.start_nonce), Liveness::Live);
    let live = hosts.join(format!("{session}.{}.live", record.start_nonce));
    let lock = std::fs::OpenOptions::new().read(true).write(true).open(live).unwrap();
    let Connect::Ready(owner, _) = link::connect(record, 0).await.expect("connect") else {
        panic!("host refused a same-build controller")
    };
    owner.terminate(Duration::from_millis(500)).await.unwrap();
    // The host ends once its harness's exit is acknowledged as logged.
    let mut entries = owner.entries.lock().await;
    loop {
        let (h, entry) = tokio::time::timeout(Duration::from_secs(20), entries.recv())
            .await
            .expect("entry in time")
            .expect("host connection open");
        owner.ack(h).await.unwrap();
        if matches!(entry, Entry::Exit { .. }) {
            break;
        }
    }
    drop(entries);
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
    let _ = std::fs::remove_dir_all(&dir);
}
