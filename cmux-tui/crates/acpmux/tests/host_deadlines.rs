//! Every wait the daemon makes on an agent host has a deadline and a typed
//! error (`HostTimeout`), and a host's death is watched by at most one
//! thread however often the daemon waits on it. The deadlines are injected
//! (`spawn_within`, `query_within`); production passes `BOOTSTRAP_BUDGET`
//! and `QUERY_BUDGET`.
#![cfg(unix)]

use acpmux::agent_host::link::{self, Connect, HostLauncher};
use acpmux::agent_host::{
    self, ControllerFrame, HostFrame, HostRecord, HostTimeout, SpawnSpec, death_watches,
    wait_dead_within,
};
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::Duration;

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("amd-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn spec(dir: &Path) -> SpawnSpec {
    SpawnSpec {
        session_id: "s".into(),
        program: "true".into(),
        args: Vec::new(),
        env: Vec::new(),
        cwd: dir.to_path_buf(),
        translator: None,
        socket: dir.join("s.sock"),
        hosts_dir: dir.to_path_buf(),
        buffer_cap: agent_host::DEFAULT_BUFFER_CAP,
    }
}

/// A host binary that starts and never reports ready (a wedged start) must
/// not hold the daemon's spawn (and the session's spawn lock) forever.
#[tokio::test]
async fn spawn_gives_up_on_a_host_that_never_reports_ready() {
    let dir = scratch("boot");
    let launcher = HostLauncher {
        exe: "/bin/sh".into(),
        prefix: vec!["-c".into(), "exec sleep 20".into(), "silent-host".into()],
    };
    let budget = Duration::from_millis(300);
    let out = tokio::time::timeout(
        Duration::from_secs(20),
        link::spawn_within(&launcher, &spec(&dir), budget),
    )
    .await
    .expect("spawn never gave up on a host that did not report ready");
    let err = out.expect_err("a silent host is not ready");
    assert!(err.downcast_ref::<HostTimeout>().is_some(), "not a typed timeout: {err:#}");
}

/// A host that never answers a translator query must not hold the caller.
#[tokio::test]
async fn a_query_the_host_never_answers_times_out() {
    let dir = scratch("query");
    let socket = dir.join("h.sock");
    let listener = tokio::net::UnixListener::bind(&socket).unwrap();
    let record = HostRecord {
        record_version: agent_host::RECORD_VERSION,
        session_id: "s".into(),
        incarnation: "inc".into(),
        host_pid: std::process::id(),
        start_nonce: "n".into(),
        harness_pid: None,
        owner_token: "00".into(),
        protocol_min: agent_host::PROTOCOL_MIN,
        protocol_max: agent_host::PROTOCOL_MAX,
        host_build: "fake".into(),
        socket: socket.clone(),
    };
    // A fake host: answers hello, then reads every frame and answers none.
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (mut rd, mut wr) = stream.into_split();
        let _: Option<ControllerFrame> = agent_host::read_frame(&mut rd).await.unwrap();
        let hello = HostFrame::HostHello {
            version: agent_host::PROTOCOL_MAX,
            host_build: "fake".into(),
            incarnation: "inc".into(),
            harness_pid: None,
            last_h: 0,
            acked_h: 0,
            max_out_id: 0,
            exited: None,
        };
        agent_host::write_frame(&mut wr, &hello).await.unwrap();
        while let Ok(Some(_)) = agent_host::read_frame::<_, ControllerFrame>(&mut rd).await {}
    });
    let Connect::Ready(link, _) = link::connect(record, 0).await.expect("connect") else {
        panic!("the fake host is compatible");
    };
    let out = tokio::time::timeout(
        Duration::from_secs(20),
        link.query_within(Duration::from_millis(300)),
    )
    .await
    .expect("query never gave up on a host that does not answer");
    let err = out.expect_err("no answer is no reply");
    assert!(err.downcast_ref::<HostTimeout>().is_some(), "not a typed timeout: {err:#}");
}

/// Bounded waits on a host that does not die share one watch; the watch ends
/// with the host.
#[test]
fn bounded_death_waits_share_one_watch_per_host() {
    let dir = scratch("death");
    let live = dir.join("s.n.live");
    let held = std::fs::File::create(&live).unwrap();
    // SAFETY: flock on a descriptor this test owns: it plays the live host.
    assert_eq!(unsafe { libc::flock(held.as_raw_fd(), libc::LOCK_EX) }, 0);
    assert!(!wait_dead_within(&dir, "s", "n", Duration::from_millis(100)));
    assert!(!wait_dead_within(&dir, "s", "n", Duration::from_millis(100)));
    assert!(!wait_dead_within(&dir, "s", "n", Duration::from_millis(100)));
    assert_eq!(death_watches(), 1, "each bounded wait left its own blocked thread");
    drop(held);
    assert!(wait_dead_within(&dir, "s", "n", Duration::from_secs(10)));
    assert_eq!(death_watches(), 0, "the watch outlived the host");
    let _ = std::fs::remove_dir_all(&dir);
}
