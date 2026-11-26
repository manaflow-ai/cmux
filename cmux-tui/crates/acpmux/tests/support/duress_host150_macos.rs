//! macOS compatibility surface for the common duress harness.
//!
//! The Linux-only host150 and cgroup collectors are intentionally absent on macOS. The common
//! daemon, peer, CLI and RFD 0050 command measurements still run, and every omitted collector is
//! represented by an explicit empty field in the row rather than silently making the test a no-op.

use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

pub(super) const EXTRA_LEGS: [&str; 1] = [super::rfd0050::LEG];
pub(super) const BURST_LEG: &str = "peerburst";

pub(super) fn expand(legs: Vec<String>) -> Vec<String> {
    legs
}
pub(super) fn is_extra(leg: &str) -> bool {
    leg == super::rfd0050::LEG
}
pub(super) fn peers_for(_leg: &str, knob: usize) -> usize {
    knob
}
pub(super) fn extra_cap(_leg: &str) -> Duration {
    Duration::ZERO
}
pub(super) fn host150_memory_high() -> String {
    String::new()
}

#[derive(Default)]
pub(super) struct Wire {
    pub accepts: AtomicU64,
    pub frames: AtomicU64,
    pub pings: AtomicU64,
    pub pongs: AtomicU64,
    pub data: AtomicU64,
    pub bytes: AtomicU64,
    pub open: AtomicU64,
}

pub(super) async fn pump(
    mut client: tokio::net::TcpStream,
    mut server: tokio::net::TcpStream,
    wire: std::sync::Arc<Wire>,
) {
    wire.open.fetch_add(1, Ordering::Relaxed);
    let _ = tokio::io::copy_bidirectional(&mut client, &mut server).await;
    wire.open.fetch_sub(1, Ordering::Relaxed);
}

pub(super) struct Extras {
    pub notes: Vec<String>,
    pub stress: serde_json::Map<String, Value>,
}

impl Extras {
    pub(super) fn start(
        _leg: &str,
        _daemon_pid: u32,
        _wire: &dyn Fn() -> Wire,
        _cap: Duration,
    ) -> Self {
        Self { notes: vec![], stress: serde_json::Map::new() }
    }
    pub(super) fn stop(&mut self) -> Vec<String> {
        vec![]
    }
}

pub(super) struct Window;
impl Window {
    pub(super) fn open(_socket: &Path, _daemon_pid: u32, _wire: &Wire, _log: &Path) -> Self {
        Self
    }
}

pub(super) struct Presence;
impl Presence {
    pub(super) fn start(
        _socket: &Path,
        _peer_names: &[String],
        _cut_peers: &BTreeSet<String>,
        _daemon_pid: u32,
        _until: Instant,
    ) -> Self {
        Self
    }
}

pub(super) fn close(
    _window: Window,
    _extras: &Extras,
    _presence: Presence,
    _socket: &Path,
    _daemon_pid: u32,
    _wire: &Wire,
    _proxy_ports: &BTreeSet<u16>,
    _peer_names: &[String],
    _log: &Path,
) -> serde_json::Map<String, Value> {
    serde_json::Map::from_iter([
        ("presenceGapMs".into(), json!({"worst": null, "peersTracked": 0, "peersOver2s": 0})),
        ("linkDrops".into(), json!({"sampledDrops": 0, "stoppedAnswering": 0, "proxyDials": 0})),
        ("peerLinks".into(), json!({"daemonTcpToProxies": 0, "proxyLinksOpen": 0})),
        ("wire".into(), json!({"framesPerSec": 0, "pingsPerSec": 0, "pongsPerSec": 0})),
        ("spawns".into(), json!({"hostPerSec": null, "daemonTreeSeen": 0})),
        ("daemonCpu".into(), json!({"windowPct": null})),
        (
            "load".into(),
            json!({"target": null, "atClock": null, "rampSecs": null, "min": null, "p50": null, "max": null}),
        ),
        ("memory".into(), json!({"daemonRssKibMax": null, "memoryHighEvents": null})),
        ("phoneLink".into(), json!("not measured on macOS compatibility surface")),
    ])
}

pub(super) fn peer_targets(
    _before: &BTreeMap<String, Value>,
    _cut: &BTreeSet<String>,
) -> Vec<(String, String)> {
    vec![]
}

pub(super) fn peer_burst(_proxies: &[super::Proxy]) -> Value {
    json!({"unsupported": "macOS compatibility surface"})
}

pub(super) fn tool_call(cwd: &Path) -> super::Ran {
    let mut cmd = Command::new("/bin/sh");
    cmd.args(["-c", "ls -a . | head -n 5 >/dev/null"]).current_dir(cwd);
    super::run_command(cmd)
}

pub(super) fn summary_tail(_row: &Value) -> String {
    "; host150 collectors unavailable on macOS".into()
}
pub(super) fn markdown(_report: &Value) -> String {
    "\nmacOS note: Linux-only host150, cgroup and /proc collectors are omitted.\n".into()
}
