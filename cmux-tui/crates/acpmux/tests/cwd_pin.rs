//! A harness pinned to a folder (`cwd_pin.rs`: a sub-session's folder as its start checked it)
//! execs only in that very folder. Started by path after another folder took the pinned one's
//! place, its spawn fails before it runs, as a direct child and under an agent host, and nothing
//! runs in the folder that took the place; started in the pinned folder itself, it runs.
//!
//! A sub-session start has no point between its last check (`CheckedFolder::still_at`) and the
//! exec where a test can swap the folder deterministically, so these tests swap it before the
//! spawn and drive the exec-time check itself. The stand-in harness (fake_agent.py) leaves a
//! `harness-started-here` file in the folder it starts in.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::agent::{ChildAgent, Tap};
use acpmux::agent_host::link::{self, HostLauncher};
use acpmux::agent_host::{self, SpawnSpec};
use acpmux::config::HarnessProfile;
use acpmux::cwd_pin::CwdPin;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::sync::Arc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
/// What the stand-in harness leaves in the folder it starts in.
const MARKER: &str = "harness-started-here";
/// The harness: it leaves [`MARKER`] in its folder, then runs fake_agent.py.
const LEAVE_MARKER: &str = "import os, sys; open('harness-started-here', 'w').close(); \
     os.execvp(sys.executable, [sys.executable, sys.argv[1]])";

fn scratch(tag: &str) -> PathBuf {
    // Short: socket paths must stay under the macOS limit.
    let dir = std::env::temp_dir().join(format!("acp-pin-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::canonicalize(dir).unwrap()
}

/// `dir/checked`, pinned, then moved away, with another folder renamed into its path; the
/// path, and the pin of the folder that was there.
fn swapped(dir: &Path) -> (PathBuf, CwdPin) {
    let at = dir.join("checked");
    std::fs::create_dir_all(&at).unwrap();
    std::fs::create_dir_all(dir.join("stand-in")).unwrap();
    let pin = CwdPin::of(&at).unwrap();
    std::fs::rename(&at, dir.join("checked-moved")).unwrap();
    std::fs::rename(dir.join("stand-in"), &at).unwrap();
    assert_ne!(CwdPin::of(&at), Some(pin), "another folder is at the path now");
    (at, pin)
}

fn argv() -> Vec<String> {
    vec!["python3".into(), "-c".into(), LEAVE_MARKER.into(), FAKE.into()]
}

async fn direct(cwd: &Path, pin: Option<CwdPin>) -> Option<Arc<ChildAgent>> {
    let profile: HarnessProfile = serde_json::from_value(json!({"argv": argv()})).unwrap();
    let (inbound, _rx) = tokio::sync::mpsc::channel(16);
    let tap: Tap = Arc::new(|_, _, _| true);
    CwdPin::scope(pin, ChildAgent::spawn("pinned", &profile, cwd, inbound, tap)).await.ok()
}

#[tokio::test]
async fn a_pinned_direct_harness_never_execs_in_a_swapped_folder() {
    let dir = scratch("d");
    let (at, pin) = swapped(&dir);
    let spawned = direct(&at, Some(pin)).await;
    assert!(
        spawned.is_none(),
        "the harness started in the folder that took the pinned one's place"
    );
    assert!(!at.join(MARKER).exists(), "it ran there");
    assert!(!dir.join("checked-moved").join(MARKER).exists());
    // Pinned to the folder that is there: it starts (and ends when dropped).
    assert!(direct(&at, CwdPin::of(&at)).await.is_some(), "a pinned harness in its own folder");
    let _ = std::fs::remove_dir_all(&dir);
}

#[tokio::test]
async fn a_pinned_hosted_harness_never_execs_in_a_swapped_folder() {
    let dir = scratch("h");
    let (at, pin) = swapped(&dir);
    let hosts = dir.join("hosts");
    let argv = argv();
    let spec = SpawnSpec {
        session_id: "pinned".into(),
        program: argv[0].clone(),
        args: argv[1..].to_vec(),
        // The stand-in's environment: never the host's (its PATH has real agents).
        env: daemon_env::vars(&dir, daemon_env::Agents::StandIn, &[]),
        cwd: at.clone(),
        translator: None,
        codex_bridge: false,
        socket: agent_host::socket_path(&hosts, "pinned"),
        hosts_dir: hosts,
        buffer_cap: agent_host::DEFAULT_BUFFER_CAP,
        router_owner_fifo: None,
        cwd_pin: Some(pin),
    };
    let launcher = HostLauncher { exe: daemon_env::bin().into(), prefix: Vec::new() };
    let started = link::spawn(&launcher, &spec).await;
    let error = started.expect_err("the host started its harness in the swapped folder");
    assert!(format!("{error:#}").contains("spawn harness process"), "{error:#}");
    assert!(!at.join(MARKER).exists(), "it ran there");
    assert!(!dir.join("checked-moved").join(MARKER).exists());
    let _ = std::fs::remove_dir_all(&dir);
}
