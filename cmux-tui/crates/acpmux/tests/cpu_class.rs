//! A session's harness starts below the GUI's CPU class on macOS (`cpu_class.rs`): background
//! (`PRIO_DARWIN_BG`) unless its profile, the daemon's env or config asks for `normal`. The class
//! is set as the harness starts, so the tools it runs inherit it: a shell the harness put in the
//! background is lowered too, as a direct child and under an agent host.
//!
//! The stand-in harness starts `sleep` in the background, writes its own pid and the sleeper's
//! to a FIFO the test reads, then execs fake_agent.py. The class is read with `ps -o pri=`: the
//! scheduler's base priority, 4 for a background (darwinbg) process and 31 for a default one.

#![cfg(target_os = "macos")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/). The reference test's
// variable is set as the process starts, never while tests run.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::stand_in().with_env(&[("ACPMUX_TEST_CPU_CLASS_REF", "normal")]);

use acpmux::agent::{ChildAgent, Tap};
use acpmux::agent_host::link::{self, HostLauncher};
use acpmux::agent_host::{self, SpawnSpec};
use acpmux::config::HarnessProfile;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// The scheduler's base priority of a darwinbg process (`MAXPRI_THROTTLE`).
const BACKGROUND_PRI: u32 = 4;

fn scratch(tag: &str) -> PathBuf {
    // Short: socket paths must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("acp-cpu-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::canonicalize(dir).unwrap()
}

/// `dir/pids`, a FIFO the stand-in harness writes "HARNESS SLEEPER" to.
fn pid_fifo(dir: &Path) -> PathBuf {
    let path = dir.join("pids");
    let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    path
}

/// The stand-in harness: a background sleeper (a tool the agent ran), both pids to `fifo`,
/// then the ACP stand-in.
fn harness_argv(fifo: &Path) -> Vec<String> {
    let script = format!(
        "sleep 120 & echo \"$$ $!\" > {}; exec python3 {}",
        daemon_env::sh_quote(fifo.display()),
        daemon_env::sh_quote(FAKE)
    );
    vec!["/bin/sh".into(), "-c".into(), script]
}

/// The harness's and the sleeper's pids, once the harness wrote them. A harness that never
/// writes them fails the test: the blocked read is then released by a writer that closes at once,
/// so no blocking thread outlives the test.
async fn read_pids(fifo: PathBuf) -> (i32, i32) {
    let path = fifo.clone();
    let mut read = tokio::task::spawn_blocking(move || std::fs::read_to_string(path).unwrap());
    let line = match tokio::time::timeout(Duration::from_secs(20), &mut read).await {
        Ok(line) => line.unwrap(),
        Err(_) => {
            use std::os::unix::fs::OpenOptionsExt;
            let _ =
                std::fs::OpenOptions::new().write(true).custom_flags(libc::O_NONBLOCK).open(&fifo);
            let _ = read.await;
            panic!("the harness did not write its pids in time");
        }
    };
    let mut pids = line.split_whitespace().map(|p| p.parse::<i32>().unwrap());
    (pids.next().unwrap(), pids.next().unwrap())
}

/// `ps -o pri=` of `pid`.
fn base_priority(pid: i32) -> u32 {
    let out = std::process::Command::new("/bin/ps")
        .args(["-o", "pri=", "-p", &pid.to_string()])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).trim().parse().unwrap_or_else(|_| {
        panic!("ps -o pri= -p {pid}: {:?}", String::from_utf8_lossy(&out.stdout))
    })
}

/// Ends the harness's process group (the sleeper with it).
fn end_group(harness: i32) {
    // SAFETY: signals the process group the harness leads.
    unsafe { libc::killpg(harness, libc::SIGKILL) };
}

async fn direct(dir: &Path, env: serde_json::Value) -> (Arc<ChildAgent>, i32, i32) {
    let fifo = pid_fifo(dir);
    let profile: HarnessProfile =
        serde_json::from_value(json!({"argv": harness_argv(&fifo), "env": env})).unwrap();
    let (inbound, _rx) = tokio::sync::mpsc::channel(16);
    let tap: Tap = Arc::new(|_, _, _| true);
    let agent = ChildAgent::spawn_with(
        "cpu",
        &profile,
        dir,
        inbound,
        tap,
        None,
        None,
        Some(("s-cpu", "cpu")),
    )
    .await
    .expect("spawn the harness");
    let (harness, sleeper) = read_pids(fifo).await;
    (agent, harness, sleeper)
}

#[tokio::test]
async fn cpu_class_a_direct_harness_and_the_tools_it_runs_start_at_background_class() {
    let dir = scratch("d");
    let (_agent, harness, sleeper) = direct(&dir, json!({})).await;
    let (h, s) = (base_priority(harness), base_priority(sleeper));
    end_group(harness);
    assert_eq!(h, BACKGROUND_PRI, "the harness runs at the GUI's class");
    assert_eq!(s, BACKGROUND_PRI, "a tool the harness started runs at the GUI's class");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn cpu_class_a_profile_can_keep_its_harness_at_normal_class() {
    let dir = scratch("n");
    let (_agent, harness, sleeper) =
        direct(&dir, json!({"ACPMUX_SESSION_CPU_CLASS": "normal"})).await;
    let (h, s) = (base_priority(harness), base_priority(sleeper));
    end_group(harness);
    assert!(h > BACKGROUND_PRI, "the opted-out harness was lowered: pri {h}");
    assert!(s > BACKGROUND_PRI, "the opted-out harness's tool was lowered: pri {s}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn cpu_class_a_profile_reference_that_resolves_to_normal_keeps_normal_class() {
    let dir = scratch("r");
    // ACPMUX_TEST_CPU_CLASS_REF=normal: set for this process by HERMETIC.
    let (_agent, harness, _sleeper) =
        direct(&dir, json!({"ACPMUX_SESSION_CPU_CLASS": "${env:ACPMUX_TEST_CPU_CLASS_REF}"})).await;
    let h = base_priority(harness);
    end_group(harness);
    assert!(h > BACKGROUND_PRI, "a reference that resolves to normal was lowered: pri {h}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn cpu_class_a_hosted_harness_and_the_tools_it_runs_start_at_background_class() {
    let dir = scratch("h");
    let fifo = pid_fifo(&dir);
    let hosts = dir.join("hosts");
    let argv = harness_argv(&fifo);
    // As the daemon sends it (`hub/hosts.rs`): its class decided there.
    let spec: SpawnSpec = serde_json::from_value(json!({
        "session_id": "s-cpu-h",
        "program": argv[0],
        "args": argv[1..],
        // The stand-in's environment: never the host's (its PATH has real agents).
        "env": daemon_env::vars(&dir, daemon_env::Agents::StandIn, &[]),
        "cwd": dir,
        "translator": null,
        "socket": agent_host::socket_path(&hosts, "s-cpu-h"),
        "hosts_dir": hosts,
        "buffer_cap": agent_host::DEFAULT_BUFFER_CAP,
        "cpu_class": "background",
    }))
    .unwrap();
    let launcher = HostLauncher { exe: daemon_env::bin().into(), prefix: Vec::new() };
    let record = link::spawn(&launcher, &spec).await.expect("spawn the host");
    let (harness, sleeper) = read_pids(fifo).await;
    assert_eq!(record.harness_pid, Some(harness as u32));
    let (h, s) = (base_priority(harness), base_priority(sleeper));
    end_group(harness);
    assert_eq!(h, BACKGROUND_PRI, "the hosted harness runs at the GUI's class");
    assert_eq!(s, BACKGROUND_PRI, "a tool the hosted harness started runs at the GUI's class");
    let _ = std::fs::remove_dir_all(&dir);
}
