//! An agent host start ends on a signal from the host, never on a clock
//! (P-AUSTIN B10). Austin's-day waves of 25 chats on a busy Mac failed 100 to
//! 150 of 150 to 200 chat opens with "agent host start did not finish within
//! 10s": every host was alive and working, and a fixed total-time budget
//! killed all of them. A start now ends when the host answers, when it exits
//! (its bootstrap pipe closes), or when its caller gives up (the host is then
//! ended); never because time passed.
//!
//! The wave tests run on tokio's paused clock: it jumps to the next timer
//! whenever the runtime waits, so any time budget in the start path runs out
//! before the stand-in host (`fake_slow_host.py`) answers. A start that does
//! not wait on a timer is decided only by what the host does.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts stand-in agent hosts (python3), no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::agent_host::link::{self, HostLauncher};
use acpmux::agent_host::{self, HostTimeout, SpawnSpec};
use std::ffi::OsString;
use std::path::{Path, PathBuf};

const FAKE_HOST: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_slow_host.py");

fn scratch(tag: &str) -> PathBuf {
    // Short: socket paths must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("ahw-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// The stand-in host in `mode` (`fake_slow_host.py`).
fn stand_in(mode: &[&str]) -> HostLauncher {
    let python = std::env::var_os("ACPMUX_TEST_PYTHON").expect("the hermetic python3");
    let mut prefix = vec![OsString::from(FAKE_HOST)];
    prefix.extend(mode.iter().map(OsString::from));
    HostLauncher { exe: python.into(), prefix }
}

fn spec(dir: &Path, session: &str) -> SpawnSpec {
    let hosts = dir.join("hosts");
    SpawnSpec {
        session_id: session.into(),
        program: "/bin/true".into(),
        args: Vec::new(),
        env: Vec::new(),
        cwd: dir.to_path_buf(),
        translator: None,
        codex_bridge: false,
        socket: agent_host::socket_path(&hosts, session),
        hosts_dir: hosts,
        buffer_cap: agent_host::DEFAULT_BUFFER_CAP,
        router_owner_fifo: None,
        cwd_pin: None,
        orphan_exit: None,
    }
}

/// A wave of chats opened at once, each host alive but slow to report ready
/// (a busy Mac): every start succeeds, whatever the clock says.
#[tokio::test(start_paused = true)]
async fn host_start_of_a_wave_of_slow_but_alive_hosts_all_succeed() {
    let dir = scratch("wave");
    let launcher = stand_in(&["slow", "0.3"]);
    let mut starts = tokio::task::JoinSet::new();
    for i in 0..25 {
        let (launcher, spec) = (launcher.clone(), spec(&dir, &format!("s{i}")));
        starts.spawn(async move { (i, link::spawn(&launcher, &spec).await) });
    }
    let mut failed = Vec::new();
    while let Some(joined) = starts.join_next().await {
        let (i, started) = joined.expect("a start task panicked");
        match started {
            Ok(record) => assert_eq!(record.session_id, format!("s{i}")),
            Err(e) => failed.push(format!("s{i}: {e:#}")),
        }
    }
    assert!(failed.is_empty(), "{} of 25 slow-but-alive hosts failed: {failed:?}", failed.len());
}

/// A host that exits before it answers fails its start on that exit, never
/// on a timer, and the error says how it exited.
#[tokio::test(start_paused = true)]
async fn host_start_fails_at_once_when_the_host_dies() {
    let dir = scratch("die");
    let err = link::spawn(&stand_in(&["die", "3"]), &spec(&dir, "s"))
        .await
        .expect_err("a host that exited cannot be ready");
    assert!(err.downcast_ref::<HostTimeout>().is_none(), "a death decided by a clock: {err:#}");
    let text = format!("{err:#}");
    assert!(text.contains("exited before it was ready"), "{text}");
    // It says how the host ended (`fake_slow_host.py die 3`).
    assert!(text.contains("exit status: 3"), "{text}");
}

/// A caller that gives up on a start (its chat closed, its own deadline)
/// ends the host it started: it never runs on with nobody waiting for it.
/// The stand-in host notes it ran on (a marker file) when it outlives the
/// drop long enough to see its bootstrap pipe close; ended first, it cannot.
/// Both ends free its lock at once, so the test waits on that, not a timer.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn host_start_its_caller_drops_ends_the_host() {
    let dir = scratch("drop");
    let lock = dir.join("host.lock");
    let fifo = dir.join("running");
    let marker = dir.join("ran-on");
    let c = std::ffi::CString::new(fifo.to_str().unwrap()).unwrap();
    // SAFETY: a NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    let launcher = stand_in(&[
        "hang",
        lock.to_str().unwrap(),
        fifo.to_str().unwrap(),
        marker.to_str().unwrap(),
    ]);
    let spec = spec(&dir, "s");
    let start = tokio::spawn(async move { link::spawn(&launcher, &spec).await });
    // The host holds its lock once it opened the FIFO.
    let running = tokio::task::spawn_blocking(move || std::fs::File::open(fifo).unwrap());
    let _running = running.await.unwrap();
    start.abort();
    assert!(start.await.unwrap_err().is_cancelled());
    let gone = tokio::task::spawn_blocking(move || {
        use std::os::fd::AsRawFd;
        let file = std::fs::OpenOptions::new().write(true).open(lock).unwrap();
        // SAFETY: a blocking lock on a descriptor this closure owns.
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) }
    });
    assert_eq!(gone.await.unwrap(), 0, "the host's lock");
    assert!(
        !marker.exists(),
        "the host of a start its caller dropped ran on: {}",
        std::fs::read_to_string(&marker).unwrap_or_default()
    );
}
