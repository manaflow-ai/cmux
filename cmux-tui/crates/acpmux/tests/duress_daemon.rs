//! The duress bench: the real daemon under the load a busy fleet host carries, and what an agent
//! pays for `ls`, `send --no-wait`, `register` and a wake while it lasts.
//!
//! Why (2026-11-22): on a host at load 100-199 on 15 cores with 1,563 processes, a local
//! `acpmux ls` answered `daemon_unreachable` ("read step stalled after 4s/15s"), a live
//! session's registration read stale twice, and elsewhere a SIGKILLed harness read alive for 36+
//! minutes. This is the one harness that reproduces that load and gives the before and after
//! number of every fix. It changes nothing in the daemon; it only measures it.
//!
//! Each leg starts a fresh daemon (the real binary, `daemon_env`) over a small home:
//! `ACPMUX_DURESS_SESSIONS` (default 20) live sessions on the stand-in agent
//! (`tests/fake_agent.py`), two peers (hubs in this process behind TCP proxies the bench can cut,
//! as `god_daemon.rs` runs them), one external Claude Code session the desktop bridge lists (a
//! registry entry in `CLAUDE_CONFIG_DIR/sessions` for a `sleep` this bench owns), and the mesh
//! hub (`meshRelay.url` in config.json, `mesh_relay_config.rs`) pointed at a stub HTTP server
//! the bench controls. Then it applies the leg's stressors for `ACPMUX_DURESS_SECS` (default 90)
//! and measures, through the real CLI as a subprocess (what an agent pays, process start
//! included) and through one direct socket connection (the daemon's own share):
//!
//! - `ls`: `acpmux --json ls`, and `_acpmux/sessions`;
//! - `send`: `acpmux send --no-wait S TEXT`, and `_acpmux/send_queue`;
//! - `register`: `acpmux register NAME`, and `_acpmux/register`. Off macOS no process is proven
//!   to be Claude Code (`claude_peers::is_claude_code` reads codesign only; renew goes through
//!   the same proof, `hub/register.rs`), so no Linux path succeeds: the rows are labelled
//!   `register (refusal round trip)` and time the daemon's walk to that refusal;
//! - two control rows, timed the same way: `true` (spawning `/bin/true`, the host's floor for
//!   starting any process at this load) and `version` (`acpmux --version`, our start with no
//!   socket). Each leg's one-line `summary` splits CLI `ls` into floor, our start (`version` -
//!   `true`) and connect, hello and request (`ls` - `version`);
//! - `wake`: a prompt to an idle session until its turn starts: `acpmux send --wait` (until the
//!   reply, which the stand-in agent gives at once), and `session/prompt` until the first
//!   `session/update` for it.
//!
//! p50, p99, max, the outcomes by error code, and the count over 500 ms, n up to
//! `ACPMUX_DURESS_N` (default 100) each while the window lasts. Beside them, once a second,
//! `acpmux --json ls` is read and diffed: `falseDead` counts the live sessions, peer rows and the
//! external session that ever read dead, stale, disconnected or missing; `falseAlive` is the
//! seconds from a SIGKILL of one stand-in harness (and, separately, of the external session's
//! process) at the leg's start until `ls` stops reading it alive (`>Ns` when it never did). The
//! host's own state (cores, 1-min load, processes, `/proc/pressure/cpu` some avg10) is sampled
//! with it, so each number can be read against the load actually reached.
//!
//! Legs (`ACPMUX_DURESS_LEGS`, comma list, default all): `baseline`, `cpu`
//! (`ACPMUX_DURESS_CPU_X` x cores busy loops, default 10), `fork` (four loops spawning
//! `/bin/true`, and 2,000 sleeping processes), `disk` (the home on a tmpfs filled to 99% when
//! `sudo -n mount` works, else the daemon's file size limit cut so writes past 16 KiB fail with
//! EFBIG, labelled as such), `hub503`, `hubslow` (the stub hub accepts and answers nothing for
//! 30 s), `peercut` (every peer link cut and refused), `relay` and `relayfail` (`sendRelay.lsArgv`,
//! which plain `acpmux ls` runs for other machines' rows, is a stub that sleeps 30 s or exits 1;
//! `ls` rows counted), `bigchat` (the cpu leg plus three chats of `ACPMUX_DURESS_BIG_RECORDS`
//! records, default 100,000, 30+ sessions, 100 never-read attached readers, forks, resends of
//! one prompt id, watches, team sends, 300 sends to a held-down peer, `_acpmux/status` fanout
//! gauges, all under `MemoryHigh=768M` via `systemd-run --user --scope` when it works) and
//! `all`. The hub legs send to `HOST/NAME` on a machine no peer is configured for, so the daemon
//! posts to the hub; their send outcomes are `queued` or `send-refused:CODE`, and `hubPaths`
//! counts the hub's requests by path and answer. Every stressor runs in its own
//! process group under `timeout -s KILL` at `ACPMUX_DURESS_CAP_SECS` (default 120), a watchdog
//! thread and a Drop guard; the test fails if one could not be removed.
//!
//! Writes `duress-bench.json` (schema `acpmux.duress-bench.v1`) and `duress-bench.md` to
//! `$FAST_CHECKS_OUT` (else a scratch folder it prints) and prints the table. No gate yet.
//! Refuses to run unless `ACPMUX_DURESS=1`, and on any host whose name contains `cosmic-gray`.
//! Linux only. Each leg prints `DURESS-SUMMARY <line>`, and the daemon's own log (kept in the
//! scratch folder, off the home) is searched for ENOSPC, panics and socket loss
//! (`daemonLogFindings`; the disk leg also reads `home/daemon.log` a CLI-started daemon wrote).
//!
//! How to run it (a fleet Linux host through cmux-ci, never on a lane VM or cosmic-gray), from
//! the checkout root; `legs=a,b` after `--nocapture` picks legs for a before/after:
//!
//! ```text
//! cmux-ci test --route fleet -- 'cd cmux-tui && ACPMUX_DURESS=1 cargo test -p acpmux --release \
//!   --test duress_daemon -- --ignored --nocapture duress_bench legs=relay,bigchat'
//! ```
//!
//! `host150` (Leo's laptop, 2026-11-23: load 10 x cores, memory and swap pressure, 40 peers, a
//! fork storm at about 40 processes a second) and `peerscale` (the baseline at 1, 10, 20 and 40
//! peers) and `peerburst` (40 ready peer links cut in one instant; the row's `peerBurst` counts
//! the redials in the first 250 ms and second and how long until every link is open again) are
//! named on purpose, never by default, and so is `rfd0050` (RFD 0050 rule 7's drill: 90% of the
//! cores busy, the host's RAM held to 90% used, the mesh hub and the relay listing answering after
//! 100 s; rows `ls`, `send`, `send-far` and `daemon status`, `support/duress_rfd0050.rs`);
//! `ACPMUX_DURESS_PEERS` sets the other legs' peer
//! count (default 2). Every leg's row also carries the presence gap, link drops, peer links,
//! frames on the wire, peer notice gauges, spawns per second and a tool call's cost
//! (`support/duress_host150.rs`).
//!
//! (`ACPMUX_DURESS_LEGS=relay,bigchat` works too; libtest takes `legs=...` as a name filter that
//! matches nothing, so `duress_bench` must be named with it.)
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// host150, peerscale and the measures every leg's row gains (presence gap, links, notices, spawns).
#[path = "support/duress_host150.rs"]
mod host150;
// RFD 0050 rule 7's drill: 90% CPU and RAM, the broker answering in 100 s.
#[path = "support/duress_rfd0050.rs"]
mod rfd0050;
// The prompts go to tests/fake_agent.py; the knobs and the output folder hold no credential.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "ACPMUX_DURESS",
    "ACPMUX_DURESS_LEGS",
    "ACPMUX_DURESS_SECS",
    "ACPMUX_DURESS_CAP_SECS",
    "ACPMUX_DURESS_CPU_X",
    "ACPMUX_DURESS_SESSIONS",
    "ACPMUX_DURESS_N",
    "ACPMUX_DURESS_PEERS",
    "ACPMUX_DURESS_MEMORY_HIGH",
    "ACPMUX_DURESS_STARVE_CORES",
    "ACPMUX_DURESS_STARVE_X",
    "ACPMUX_DURESS_STARVE_IDLE",
    "ACPMUX_DURESS_STARVE_MEMORY_HIGH",
    "ACPMUX_DURESS_STARVE_CPU_MAX",
    "ACPMUX_DURESS_STARVE_DELAY_MS",
    "ACPMUX_DURESS_STARVE_JITTER_MS",
    "ACPMUX_DURESS_STARVE_STALL_MS",
    "ACPMUX_DURESS_STARVE_STALL_EVERY_S",
    // The commit under test, when the runner names it (else `git rev-parse HEAD`).
    "GITHUB_SHA",
    // The fleet's output directory, not a credential.
    "FAST_CHECKS_OUT",
    "ACPMUX_DURESS_BIG_RECORDS",
    // The bigchat leg's parts left out, to find which one slows the daemon (`bigchat_off`).
    "ACPMUX_DURESS_BIGCHAT_OFF",
    // How `systemd-run --user` reaches the user's manager, for the bigchat leg's memory ceiling.
    "XDG_RUNTIME_DIR",
    "DBUS_SESSION_BUS_ADDRESS",
]);

use acpmux::config::{Config, StoreMode};
use acpmux::god_fixture;
use acpmux::hub::Hub;
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{WsAuth, bind_ws, serve_ws_with};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use wait_timeout::ChildExt;

/// What one CLI call or socket request may take before it is counted as timed out.
const CALL_LIMIT: Duration = Duration::from_secs(30);
/// A sample over this is slow (the count the table shows).
const SLOW_MS: f64 = 500.0;
/// Peers and the rows each lists.
/// Peers by default (`ACPMUX_DURESS_PEERS`; Leo's Mac held ~40).
const PEERS: usize = 2;
const PEER_ROWS: usize = 5;
/// The name the external session is listed under (the registry entry's `name`).
const EXTERNAL_NAME: &str = "duress-external";
/// How long the stub hub holds a request in `hubslow`.
const HUB_HOLD: Duration = Duration::from_secs(30);
/// Sleeping processes of the fork leg.
const SLEEPERS: usize = 2000;
/// The tmpfs the disk leg puts the home on.
const TMPFS_MB: u64 = 256;
/// The file size limit of the disk leg's fallback.
const FSIZE_LIMIT: u64 = 16 << 10;

const ALL_LEGS: [&str; 11] = [
    "baseline",
    "cpu",
    "fork",
    "disk",
    "hub503",
    "hubslow",
    "peercut",
    "relay",
    "relayfail",
    "bigchat",
    "all",
];
/// How long the `relay` leg's listing stub sleeps before it answers.
const RELAY_SLEEP_SECS: u64 = 30;
/// The `bigchat` leg: chats with large logs, attached readers that never read, unsettled
/// deliveries.
const BIG_CHATS: usize = 3;
const SLOW_READERS: usize = 100;
const UNSETTLED: usize = 300;
/// The memory ceiling of the `bigchat` leg's daemon (`systemd-run --user -p MemoryHigh=`).
const MEMORY_HIGH: &str = "768M";

/// Whether the bigchat leg runs without `part` (`ACPMUX_DURESS_BIGCHAT_OFF`, a comma list of
/// `fork`, `resend`, `watch+team`, `outbox`, `gauges`, `readers`, `memoryhigh`, `cpu`): the
/// leg with one part off at a time says which part slows the daemon.
fn bigchat_off(part: &str) -> bool {
    std::env::var("ACPMUX_DURESS_BIGCHAT_OFF").is_ok_and(|v| v.split(',').any(|p| p.trim() == part))
}

fn env_or<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name).ok().and_then(|v| v.trim().parse().ok()).unwrap_or(default)
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

fn ms_f(d: Duration) -> f64 {
    d.as_secs_f64() * 1000.0
}

struct Knobs {
    legs: Vec<String>,
    window: Duration,
    cap: Duration,
    cpu_x: usize,
    sessions: usize,
    n: usize,
    /// Peers behind proxies (`ACPMUX_DURESS_PEERS`, default [`PEERS`]).
    peers: usize,
    /// Records in each of the bigchat leg's chats.
    big_records: usize,
}

impl Knobs {
    fn from_env() -> Self {
        // `legs=cpu,disk` after `--`: libtest takes it as a second name filter (it matches no
        // test, so it selects nothing) and refuses a `--legs` flag, so the word carries no dashes.
        let from_args = std::env::args().find_map(|a| a.strip_prefix("legs=").map(str::to_owned));
        let legs = from_args
            .or_else(|| std::env::var("ACPMUX_DURESS_LEGS").ok())
            .filter(|v| !v.trim().is_empty())
            .map(|v| v.split(',').map(|l| l.trim().to_owned()).filter(|l| !l.is_empty()).collect())
            .unwrap_or_else(|| ALL_LEGS.iter().map(|l| (*l).to_owned()).collect::<Vec<_>>());
        let legs = host150::expand(legs);
        for leg in &legs {
            assert!(
                ALL_LEGS.contains(&leg.as_str()) || host150::is_extra(leg),
                "unknown leg {leg:?}; legs: {ALL_LEGS:?} and {:?}",
                host150::EXTRA_LEGS
            );
        }
        let window = Duration::from_secs(env_or("ACPMUX_DURESS_SECS", 90u64).max(5));
        let cap = Duration::from_secs(env_or("ACPMUX_DURESS_CAP_SECS", 120u64))
            .max(window + Duration::from_secs(10));
        Self {
            legs,
            window,
            cap,
            cpu_x: env_or("ACPMUX_DURESS_CPU_X", 10usize).max(1),
            sessions: env_or("ACPMUX_DURESS_SESSIONS", 20usize).max(4),
            n: env_or("ACPMUX_DURESS_N", 100usize).max(1),
            peers: env_or("ACPMUX_DURESS_PEERS", PEERS).clamp(1, 200),
            big_records: env_or("ACPMUX_DURESS_BIG_RECORDS", 100_000usize).max(4),
        }
    }
}

/// The stressors of one leg.
#[derive(Clone, Copy, Default, Debug)]
struct Stress {
    cpu: bool,
    fork: bool,
    disk: bool,
    hub503: bool,
    hubslow: bool,
    peercut: bool,
    /// The send relay's listing (`sendRelay.lsArgv`): 1 sleeps [`RELAY_SLEEP_SECS`], 2 exits 1.
    relay: u8,
    bigchat: bool,
    /// Leo's laptop: load 10 x cores, memory and swap pressure, 40 peers, a fork storm.
    host150: bool,
    /// RFD 0050 rule 7: 90% CPU and RAM held, the broker answering in 100 s (`rfd0050`).
    rfd0050: bool,
}

impl Stress {
    fn of(leg: &str) -> Self {
        let mut s = Stress::default();
        match leg {
            "baseline" => {}
            "cpu" => s.cpu = true,
            "fork" => s.fork = true,
            "disk" => s.disk = true,
            "hub503" => s.hub503 = true,
            "hubslow" => s.hubslow = true,
            "peercut" => s.peercut = true,
            "relay" => s.relay = 1,
            "relayfail" => s.relay = 2,
            // The stall of 2026-11-22: big chats resent and forked under CPU load and memory
            // pressure, with readers that never read.
            "bigchat" => {
                s.bigchat = true;
                s.cpu = true;
            }
            // hub503 and hubslow cannot both hold: the stub answers 503 slowly is neither. `all`
            // takes hubslow, the one that held a reader in the field.
            "all" => {
                s = Stress { cpu: true, fork: true, disk: true, hubslow: true, peercut: true, ..s }
            }
            "host150" => s.host150 = true,
            rfd0050::LEG => s.rfd0050 = true,
            // peerscaleN: the baseline at N peers (`host150::peers_for`).
            l if l.starts_with("peerscale") => {}
            // starved: the daemon pinned with its load, capped and far (`host150::starved`).
            "starved" => {}
            // peerburst: every ready link cut at once (`host150::peer_burst`).
            "peerburst" => {}
            _ => unreachable!(),
        }
        s
    }
}

// ---------------------------------------------------------------------------------------------
// The host's own state.

fn hostname() -> String {
    std::fs::read_to_string("/proc/sys/kernel/hostname").unwrap_or_default().trim().to_owned()
}

fn cores() -> usize {
    std::thread::available_parallelism().map_or(1, |n| n.get())
}

fn load1() -> Option<f64> {
    std::fs::read_to_string("/proc/loadavg").ok()?.split_whitespace().next()?.parse().ok()
}

fn psi_cpu_some_avg10() -> Option<f64> {
    let text = std::fs::read_to_string("/proc/pressure/cpu").ok()?;
    let some = text.lines().find(|l| l.starts_with("some"))?;
    some.split_whitespace().find_map(|f| f.strip_prefix("avg10=")).and_then(|v| v.parse().ok())
}

/// Every process's pid, and its `/proc/PID/stat` fields from the state on.
fn procs() -> Vec<(i32, Vec<String>)> {
    let Ok(dir) = std::fs::read_dir("/proc") else { return vec![] };
    dir.flatten()
        .filter_map(|e| e.file_name().to_str()?.parse::<i32>().ok())
        .filter_map(|pid| {
            let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
            let rest = stat.rsplit_once(')')?.1;
            Some((pid, rest.split_whitespace().map(str::to_owned).collect()))
        })
        .collect()
}

fn proc_count() -> usize {
    std::fs::read_dir("/proc")
        .map(|d| {
            d.flatten()
                .filter(|e| e.file_name().to_str().is_some_and(|n| n.parse::<u32>().is_ok()))
                .count()
        })
        .unwrap_or(0)
}

/// Live (not zombie) processes in process group `pgid`. Fields from the state: 0 state, 2 pgrp.
fn group_members(pgid: i32) -> usize {
    procs()
        .iter()
        .filter(|(_, f)| f.get(2).and_then(|g| g.parse::<i32>().ok()) == Some(pgid))
        .filter(|(_, f)| f.first().map(String::as_str) != Some("Z"))
        .count()
}

#[derive(Default, Clone)]
struct HostSample {
    load1_max: f64,
    load1_start: Option<f64>,
    procs_max: usize,
    psi_max: Option<f64>,
}

impl HostSample {
    fn take(&mut self) {
        if let Some(l) = load1() {
            self.load1_start.get_or_insert(l);
            self.load1_max = self.load1_max.max(l);
        }
        self.procs_max = self.procs_max.max(proc_count());
        if let Some(p) = psi_cpu_some_avg10() {
            self.psi_max = Some(self.psi_max.map_or(p, |m: f64| m.max(p)));
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Stressors: each a process group under `timeout -s KILL`, killed by the leg, a watchdog and Drop.

/// Process groups of stressors still running, for the watchdog.
static LIVE_GROUPS: Mutex<Vec<i32>> = Mutex::new(Vec::new());

fn kill_group(pgid: i32) {
    // SAFETY: a negative pid signals the group this bench made; SIGKILL has no handler.
    unsafe { libc::kill(-pgid, libc::SIGKILL) };
}

struct Stressor {
    name: String,
    child: Option<Child>,
    pgid: i32,
}

impl Stressor {
    fn spawn(name: &str, script: &str, cap: Duration) -> std::io::Result<Self> {
        let timeout = Path::new("/usr/bin/timeout");
        let mut cmd = if timeout.exists() {
            let mut c = Command::new(timeout);
            c.args(["-s", "KILL", &cap.as_secs().to_string(), "/bin/sh", "-c", script]);
            c
        } else {
            let mut c = Command::new("/bin/sh");
            c.args(["-c", script]);
            c
        };
        cmd.process_group(0).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        let child = cmd.spawn()?;
        let pgid = child.id() as i32;
        LIVE_GROUPS.lock().unwrap().push(pgid);
        Ok(Self { name: name.to_owned(), child: Some(child), pgid })
    }

    /// Kills its group and waits until no member runs: an error when one still does after 15 s.
    fn stop(&mut self) -> Result<(), String> {
        let Some(mut child) = self.child.take() else { return Ok(()) };
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            kill_group(self.pgid);
            let _ = child.try_wait();
            let left = group_members(self.pgid);
            if left == 0 {
                let _ = child.wait_timeout(Duration::from_secs(1));
                LIVE_GROUPS.lock().unwrap().retain(|g| *g != self.pgid);
                return Ok(());
            }
            if Instant::now() > deadline {
                return Err(format!(
                    "stressor {} (pgid {}): {left} processes left",
                    self.name, self.pgid
                ));
            }
            std::thread::sleep(Duration::from_millis(200));
        }
    }
}

impl Drop for Stressor {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

/// Kills every stressor group still running at `cap` from now, unless disarmed first.
struct Watchdog(Arc<AtomicBool>);

impl Watchdog {
    fn arm(cap: Duration) -> Self {
        let disarmed = Arc::new(AtomicBool::new(false));
        let flag = disarmed.clone();
        std::thread::spawn(move || {
            let until = Instant::now() + cap;
            while Instant::now() < until {
                if flag.load(Ordering::SeqCst) {
                    return;
                }
                std::thread::sleep(Duration::from_millis(250));
            }
            for g in LIVE_GROUPS.lock().unwrap().iter() {
                eprintln!("duress watchdog: cap reached, killing stressor group {g}");
                kill_group(*g);
            }
        });
        Self(disarmed)
    }
}

impl Drop for Watchdog {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

fn cpu_script(count: usize) -> String {
    format!("i=0; while [ $i -lt {count} ]; do ( while :; do :; done ) & i=$((i+1)); done; wait")
}

fn fork_script() -> String {
    format!(
        "i=0; while [ $i -lt {SLEEPERS} ]; do /bin/sleep 100000 & i=$((i+1)); done; \
         for j in 1 2 3 4; do ( while :; do /bin/true; done ) & done; wait"
    )
}

// ---------------------------------------------------------------------------------------------
// The disk stressor.

enum Disk {
    /// The home is a tmpfs this bench mounted.
    Tmpfs {
        mount: PathBuf,
        filler: PathBuf,
    },
    /// The daemon runs with SIGXFSZ ignored; its soft RLIMIT_FSIZE is cut during the window.
    Rlimit,
    Skipped(String),
}

fn sudo(args: &[&str]) -> Result<(), String> {
    let out = Command::new("/usr/bin/sudo")
        .arg("-n")
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("sudo: {e}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(format!("sudo -n {}: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim()))
    }
}

/// The home on a tmpfs of [`TMPFS_MB`], or why not.
fn mount_tmpfs(home: &Path) -> Result<(), String> {
    std::fs::create_dir_all(home).map_err(|e| e.to_string())?;
    // SAFETY: getuid/getgid have no preconditions.
    let (uid, gid) = unsafe { (libc::getuid(), libc::getgid()) };
    let opts = format!("size={TMPFS_MB}m,mode=0700,uid={uid},gid={gid}");
    sudo(&["/bin/mount", "-t", "tmpfs", "-o", &opts, "tmpfs", &home.display().to_string()])
}

fn statvfs(path: &Path) -> Option<(u64, u64)> {
    let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).ok()?;
    // SAFETY: a zeroed statvfs is a valid out parameter; `c` is a valid C string.
    let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
    (unsafe { libc::statvfs(c.as_ptr(), &mut s) } == 0)
        .then(|| (s.f_blocks * s.f_frsize, s.f_bavail * s.f_frsize))
}

/// Fills the filesystem at `filler`'s folder until under 1% of it is free: the bytes written.
fn fill(filler: &Path) -> Result<u64, String> {
    let dir = filler.parent().unwrap();
    let (total, _) = statvfs(dir).ok_or("statvfs")?;
    let mut f = std::fs::File::create(filler).map_err(|e| e.to_string())?;
    let block = vec![0x5a_u8; 1 << 20];
    let mut written = 0u64;
    loop {
        let (_, free) = statvfs(dir).ok_or("statvfs")?;
        if free * 100 < total {
            break;
        }
        let chunk = ((free - total / 100) as usize).clamp(4096, block.len());
        match f.write_all(&block[..chunk]) {
            Ok(()) => written += chunk as u64,
            Err(_) => break,
        }
    }
    let _ = f.sync_all();
    Ok(written)
}

fn set_fsize(pid: u32, limit: u64) -> Result<(), String> {
    let mut old: libc::rlimit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: reading this process's... the target's limits into `old`.
    if unsafe { libc::prlimit(pid as i32, libc::RLIMIT_FSIZE, std::ptr::null(), &mut old) } != 0 {
        return Err(format!("prlimit read: {}", std::io::Error::last_os_error()));
    }
    let new = libc::rlimit { rlim_cur: limit.min(old.rlim_max), rlim_max: old.rlim_max };
    // SAFETY: `new` is a valid rlimit; only the soft limit moves, within the hard one.
    if unsafe { libc::prlimit(pid as i32, libc::RLIMIT_FSIZE, &new, std::ptr::null_mut()) } != 0 {
        return Err(format!("prlimit set: {}", std::io::Error::last_os_error()));
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// The stub mesh hub.

const HUB_OK: u8 = 0;
/// The `rfd0050` leg's far send: a machine no peer is configured for, so it goes to the broker.
const RFD0050_FAR: &str = "duress-far-host/duress-far";
const HUB_503: u8 = 1;
const HUB_SLOW: u8 = 2;
/// Answers every request, after [`rfd0050::BROKER_SECS`].
const HUB_LATE: u8 = 3;

struct StubHub {
    port: u16,
    mode: Arc<AtomicU8>,
    requests: Arc<AtomicU64>,
    /// Requests by method and path (query cut), with the answer's status.
    paths: Arc<Mutex<BTreeMap<String, u64>>>,
    stop: Arc<AtomicBool>,
}

impl StubHub {
    fn start() -> Self {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let mode = Arc::new(AtomicU8::new(HUB_OK));
        let requests = Arc::new(AtomicU64::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let paths = Arc::new(Mutex::new(BTreeMap::new()));
        let (m, r, s, ps) = (mode.clone(), requests.clone(), stop.clone(), paths.clone());
        std::thread::spawn(move || {
            for conn in listener.incoming() {
                if s.load(Ordering::SeqCst) {
                    return;
                }
                let Ok(conn) = conn else { continue };
                let (m, r, s, ps) = (m.clone(), r.clone(), s.clone(), ps.clone());
                std::thread::spawn(move || serve_hub(conn, &m, &r, &ps, &s));
            }
        });
        Self { port, mode, requests, paths, stop }
    }

    fn set(&self, mode: u8) {
        self.mode.store(mode, Ordering::SeqCst);
    }
}

impl Drop for StubHub {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        let _ = std::net::TcpStream::connect(("127.0.0.1", self.port));
    }
}

fn serve_hub(
    conn: std::net::TcpStream,
    mode: &AtomicU8,
    requests: &AtomicU64,
    paths: &Mutex<BTreeMap<String, u64>>,
    stop: &AtomicBool,
) {
    let _ = conn.set_read_timeout(Some(Duration::from_secs(60)));
    let mut reader = BufReader::new(match conn.try_clone() {
        Ok(c) => c,
        Err(_) => return,
    });
    let mut writer = conn;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 || stop.load(Ordering::SeqCst) {
            return;
        }
        let path = line.split_whitespace().nth(1).unwrap_or("/").to_owned();
        let mut length = 0usize;
        loop {
            let mut h = String::new();
            if reader.read_line(&mut h).unwrap_or(0) == 0 {
                return;
            }
            let h = h.trim_end();
            if h.is_empty() {
                break;
            }
            if let Some((k, v)) = h.split_once(':')
                && k.eq_ignore_ascii_case("content-length")
            {
                length = v.trim().parse().unwrap_or(0);
            }
        }
        let mut body = vec![0u8; length.min(1 << 20)];
        if reader.read_exact(&mut body).is_err() {
            return;
        }
        requests.fetch_add(1, Ordering::SeqCst);
        let held = mode.load(Ordering::SeqCst);
        let verb = line.split_whitespace().next().unwrap_or("?");
        let bare = path.split('?').next().unwrap_or("");
        let answered = match held {
            HUB_SLOW => "held",
            HUB_LATE => "late",
            HUB_503 => "503",
            _ => "200",
        };
        *paths.lock().unwrap().entry(format!("{verb} {bare} {answered}")).or_default() += 1;
        if held == HUB_LATE {
            std::thread::sleep(Duration::from_secs(rfd0050::BROKER_SECS));
        }
        let answer = match held {
            HUB_SLOW => {
                std::thread::sleep(HUB_HOLD);
                return;
            }
            HUB_503 => ("503 Service Unavailable", r#"{"error":"unavailable"}"#.to_owned()),
            _ => {
                if path.starts_with("/v1/mesh/inbox") {
                    // A long poll with nothing in it, short so the leg changes mode promptly.
                    std::thread::sleep(Duration::from_secs(1));
                }
                // A send's receipt (`mesh.rs` `Receipt`), else an empty listing.
                ("200 OK", r#"{"messageId":"duress-m","state":"queued","messages":[],"sessions":[],"ok":true}"#.to_owned())
            }
        };
        let text = format!(
            "HTTP/1.1 {}\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{}",
            answer.0,
            answer.1.len(),
            answer.1
        );
        if writer.write_all(text.as_bytes()).is_err() {
            return;
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Peers: in-process hubs behind proxies that can be cut and held down (as `god_daemon.rs`).

struct Proxy {
    port: u16,
    up: Arc<AtomicBool>,
    links: Arc<Mutex<Vec<tokio::task::AbortHandle>>>,
    /// Dials and frames through it (`host150::pump`).
    wire: Arc<host150::Wire>,
}

impl Proxy {
    async fn start(backend: u16) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let up = Arc::new(AtomicBool::new(true));
        let links: Arc<Mutex<Vec<tokio::task::AbortHandle>>> = Arc::default();
        let wire: Arc<host150::Wire> = Arc::default();
        let (u, held, w) = (up.clone(), links.clone(), wire.clone());
        tokio::spawn(async move {
            while let Ok((client, _)) = listener.accept().await {
                if !u.load(Ordering::SeqCst) {
                    drop(client);
                    continue;
                }
                w.accepts.fetch_add(1, Ordering::Relaxed);
                let w = w.clone();
                let task = tokio::spawn(async move {
                    let Ok(server) = tokio::net::TcpStream::connect(("127.0.0.1", backend)).await
                    else {
                        return;
                    };
                    host150::pump(client, server, w).await;
                });
                held.lock().unwrap().push(task.abort_handle());
            }
        });
        Self { port, up, links, wire }
    }

    fn cut(&self, hold_down: bool) {
        self.up.store(!hold_down, Ordering::SeqCst);
        for link in self.links.lock().unwrap().drain(..) {
            link.abort();
        }
    }

    fn restore(&self) {
        self.up.store(true, Ordering::SeqCst);
    }
}

async fn peers(scratch: &Path, count: usize) -> (Value, Vec<Proxy>, Vec<Arc<Hub>>) {
    let (mut config, mut proxies, mut hubs) = (serde_json::Map::new(), vec![], vec![]);
    for p in 0..count {
        let name = format!("peer{p:02}");
        let mut cfg = Config::default();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        for i in 0..PEER_ROWS {
            store.save(&serde_json::from_value(god_fixture::peer_meta(&name, i)).unwrap()).unwrap();
        }
        let hub = Hub::new(cfg, store);
        let home = scratch.join(format!("peer-{p}"));
        std::fs::create_dir_all(&home).unwrap();
        let auth = PeerAuth::create(&home).unwrap();
        let token = std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
        let listener = bind_ws("127.0.0.1:0").await.unwrap();
        let backend = listener.local_addr().unwrap().port();
        let auth = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
        tokio::spawn(serve_ws_with(hub.clone(), listener, "tok".into(), auth));
        let proxy = Proxy::start(backend).await;
        config.insert(
            name,
            json!({"url": format!("ws://127.0.0.1:{}", proxy.port), "token": "tok",
                   "peerToken": token.trim()}),
        );
        proxies.push(proxy);
        hubs.push(hub);
    }
    (Value::Object(config), proxies, hubs)
}

// ---------------------------------------------------------------------------------------------
// The daemon, the CLI and a socket client.

struct Daemon {
    child: Child,
    socket: PathBuf,
    log: PathBuf,
}

impl Daemon {
    fn start(
        scratch: &Path,
        home: &Path,
        claude: &Path,
        ignore_xfsz: bool,
        memory_high: Option<&str>,
    ) -> Result<Self, String> {
        let socket = scratch.join("s.sock");
        let log = scratch.join("daemon.log");
        let stderr = std::fs::OpenOptions::new().create(true).append(true).open(&log).unwrap();
        let mut cmd = match memory_high {
            // A transient scope runs the command itself, so the daemon stays this bench's child.
            Some(high) => {
                let mut c = Command::new("/usr/bin/systemd-run");
                c.args(["--user", "--scope", "--quiet", "-p", &format!("MemoryHigh={high}"), "--"])
                    .arg(pinned_bin());
                daemon_env::apply(&mut c, scratch, daemon_env::Agents::StandIn, &[]);
                for key in ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"] {
                    if let Ok(v) = std::env::var(key) {
                        c.env(key, v);
                    }
                }
                c
            }
            None => daemon_env::command_at(pinned_bin(), scratch, daemon_env::Agents::StandIn, &[]),
        };
        // The daemon logs to its stdout (`log_sink.rs`): both go to a file in the scratch folder,
        // off the home, so a full home (the disk leg) still leaves its log readable.
        let stdout = stderr.try_clone().unwrap();
        // A `dhat-heap` build's heap by allocation site (`heap_profile.rs`), written when the
        // daemon stops, into `ACPMUX_DURESS_DHAT_DIR` (one file per daemon started).
        if let Some(dir) = std::env::var_os("ACPMUX_DURESS_DHAT_DIR") {
            static N: AtomicU64 = AtomicU64::new(0);
            let _ = std::fs::create_dir_all(&dir);
            let file = PathBuf::from(dir).join(format!(
                "dhat-{}-{}.json",
                std::process::id(),
                N.fetch_add(1, Ordering::SeqCst)
            ));
            cmd.env(acpmux::heap_profile::OUT_ENV, file);
        }
        cmd.args(["daemon", "run", "--log", "info,acpmux::hub::desktop_bridge=debug"])
            .env("ACPMUX_HOME", home)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("CLAUDE_CONFIG_DIR", claude)
            .stdin(Stdio::null())
            .stdout(Stdio::from(stdout))
            .stderr(Stdio::from(stderr));
        if ignore_xfsz {
            // SAFETY: only `signal`, async-signal-safe, between fork and exec. SIG_IGN survives
            // exec, so a write past the cut file size limit fails with EFBIG instead of killing
            // the daemon, as a full disk fails writes with ENOSPC.
            unsafe {
                cmd.pre_exec(|| {
                    libc::signal(libc::SIGXFSZ, libc::SIG_IGN);
                    Ok(())
                });
            }
        }
        let started = Instant::now();
        let mut child = cmd.spawn().map_err(|e| format!("spawn the daemon: {e}"))?;
        while UnixStream::connect(&socket).is_err() {
            if started.elapsed() > Duration::from_secs(120)
                || child.try_wait().ok().flatten().is_some()
            {
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!("the daemon did not bind its socket: {}", log_tail(&log)));
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        Ok(Self { child, socket, log })
    }

    fn pid(&self) -> u32 {
        self.child.id()
    }

    /// How the daemon this bench started ended, or none while it runs (a zombie is ended).
    fn exited(&mut self) -> Option<String> {
        use std::os::unix::process::ExitStatusExt;
        let status = self.child.try_wait().ok().flatten()?;
        Some(match (status.code(), status.signal()) {
            (Some(c), _) => format!("exit {c}"),
            (None, Some(s)) => format!("signal {s}"),
            _ => "ended".into(),
        })
    }
}

/// Lines of a daemon log that say why it stopped, failed a write or lost its socket.
fn log_findings(path: &Path) -> Vec<String> {
    let text = String::from_utf8_lossy(&std::fs::read(path).unwrap_or_default()).into_owned();
    const MARKS: [&str; 13] = [
        "No space left",
        "space left",
        "ENOSPC",
        "os error 28",
        "panicked",
        "stopping",
        "socket",
        "exiting",
        "fatal",
        "ERROR",
        "home watch",
        "lost",
        "desktop bridge",
    ];
    let mut seen = BTreeSet::new();
    text.lines()
        .filter(|l| MARKS.iter().any(|m| l.contains(m)))
        .map(|l| l.chars().take(400).collect::<String>())
        // The first of each distinct line, timestamps aside.
        .filter(|l| seen.insert(l.split_once(' ').map_or(l.as_str(), |(_, r)| r).to_owned()))
        .take(40)
        .collect()
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // SAFETY: the pid is this bench's own child, not yet reaped.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        // A heap profile is written on the way out, which takes longer than a plain stop.
        let stop = if std::env::var_os("ACPMUX_DURESS_DHAT_DIR").is_some() { 600 } else { 20 };
        if self.child.wait_timeout(Duration::from_secs(stop)).ok().flatten().is_none() {
            let _ = self.child.kill();
            let _ = self.child.wait_timeout(Duration::from_secs(5));
        }
    }
}

fn log_tail(path: &Path) -> String {
    let text = std::fs::read(path).unwrap_or_default();
    let tail = &text[text.len().saturating_sub(4096)..];
    String::from_utf8_lossy(tail).into_owned()
}

/// What the CLI runs with: the daemon's home, socket and Claude folder.
#[derive(Clone)]
struct Cli {
    scratch: PathBuf,
    home: PathBuf,
    socket: PathBuf,
    claude: PathBuf,
    cwd: PathBuf,
}

struct Ran {
    took: Duration,
    ok: bool,
    code: String,
    stdout: String,
    /// The error's text as the CLI printed it (empty on success), for the report's examples.
    text: String,
}

impl Cli {
    fn run(&self, args: &[&str]) -> Ran {
        let mut cmd =
            daemon_env::command_at(pinned_bin(), &self.scratch, daemon_env::Agents::StandIn, &[]);
        cmd.args(args)
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("CLAUDE_CONFIG_DIR", &self.claude)
            .current_dir(&self.cwd);
        run_command(cmd)
    }
}

/// `prog args` timed as a CLI call is (`/bin/true`: the floor for starting any process).
fn run_plain(prog: &str, args: &[&str]) -> Ran {
    let mut cmd = Command::new(prog);
    cmd.args(args);
    run_command(cmd)
}

/// `cmd` run to its end (or `CALL_LIMIT`), its wall time from spawn to reaped exit.
fn run_command(mut cmd: Command) -> Ran {
    {
        cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
        let started = Instant::now();
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                return Ran {
                    took: started.elapsed(),
                    ok: false,
                    code: format!("spawn: {}", e.kind()),
                    stdout: String::new(),
                    text: e.to_string(),
                };
            }
        };
        // Readers so a large reply never blocks the child on a full pipe.
        let mut out = child.stdout.take().unwrap();
        let mut err = child.stderr.take().unwrap();
        let out_t = std::thread::spawn(move || {
            let mut s = String::new();
            let _ = out.read_to_string(&mut s);
            s
        });
        let err_t = std::thread::spawn(move || {
            let mut s = String::new();
            let _ = err.read_to_string(&mut s);
            s
        });
        let status = child.wait_timeout(CALL_LIMIT).ok().flatten();
        let took = started.elapsed();
        let timed_out = status.is_none();
        if timed_out {
            let _ = child.kill();
            let _ = child.wait();
        }
        let stdout = out_t.join().unwrap_or_default();
        let stderr = err_t.join().unwrap_or_default();
        let ok = status.is_some_and(|s| s.success());
        let exit = status.and_then(|s| s.code());
        let code = if timed_out {
            format!("cli_timeout_{}s", CALL_LIMIT.as_secs())
        } else if ok {
            "ok".into()
        } else {
            error_code(&format!("{stdout}\n{stderr}"), exit)
        };
        // On success too: a notice the command printed while it worked around a part (the
        // relay legs' "other machines' sessions are not listed").
        let text = stderr.trim().chars().take(600).collect();
        Ran { took, ok, code, stdout, text }
    }
}

/// Lines the CLI prints while it waits or works around a part it could not read: notices, not
/// the command's outcome (`slow_notice.rs`, `send_relay.rs`, `ls.rs`).
fn is_notice(line: &str) -> bool {
    line.contains("has not answered") && line.contains("still waiting")
        || line.starts_with("acpmux: other machines' sessions are not listed")
        || line.starts_with("acpmux: the tools of")
}

/// A failed command's final outcome: the code of its JSON error envelope, else a known phrase,
/// else its first line that is not a notice (the error the command ended on), cut short; with
/// the exit code when it is not 1.
fn error_code(text: &str, exit: Option<i32>) -> String {
    let lines: Vec<&str> =
        text.lines().map(str::trim).filter(|l| !l.is_empty() && !is_notice(l)).collect();
    let rest = lines.join("\n");
    let mut code = None;
    for key in ["\"code\":\"", "\"code\": \""] {
        if let Some(at) = rest.find(key) {
            let tail = &rest[at + key.len()..];
            if let Some(end) = tail.find('"') {
                code = Some(tail[..end].to_owned());
                break;
            }
        }
    }
    let code = code
        .or_else(|| {
            ["daemon_unreachable", "step stalled", "No space left", "File too large"]
                .into_iter()
                .find(|p| rest.contains(p))
                .map(str::to_owned)
        })
        .unwrap_or_else(|| {
            let line = lines.first().copied().unwrap_or("no output");
            // A path in the line (a scratch folder) would split one cause into many codes.
            line.split(" at /").next().unwrap_or(line).chars().take(80).collect()
        });
    match exit {
        Some(c) if c != 1 => format!("{code} (exit {c})"),
        _ => code,
    }
}

/// One socket connection, with a deadline on every call.
struct Rpc {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Rpc {
    fn connect(path: &Path) -> Result<Self, String> {
        let s = UnixStream::connect(path).map_err(|e| format!("connect: {}", e.kind()))?;
        s.set_read_timeout(Some(CALL_LIMIT)).ok();
        s.set_write_timeout(Some(CALL_LIMIT)).ok();
        let reader = BufReader::new(s.try_clone().map_err(|e| e.to_string())?);
        let mut rpc = Self { reader, writer: s, next: 0 };
        rpc.call(
            "initialize",
            json!({"protocolVersion": 1, "clientInfo": {"name": "duress-bench"}}),
            CALL_LIMIT,
        )?;
        Ok(rpc)
    }

    fn request(&mut self, method: &str, params: Value) -> Result<u64, String> {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.writer
            .write_all(format!("{line}\n").as_bytes())
            .map_err(|e| format!("write: {}", e.kind()))?;
        Ok(self.next)
    }

    fn read_until(
        &mut self,
        deadline: Instant,
        mut pred: impl FnMut(&Value) -> bool,
    ) -> Result<Value, String> {
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Err(format!("socket_timeout_{}s", CALL_LIMIT.as_secs()));
            }
            self.writer.set_read_timeout(Some(left)).ok();
            let mut line = String::new();
            match self.reader.read_line(&mut line) {
                Ok(0) => return Err("socket_closed".into()),
                Ok(_) => {}
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    return Err(format!("socket_timeout_{}s", CALL_LIMIT.as_secs()));
                }
                Err(e) => return Err(format!("read: {}", e.kind())),
            }
            let Ok(v) = serde_json::from_str::<Value>(&line) else { continue };
            if pred(&v) {
                return Ok(v);
            }
        }
    }

    fn call(&mut self, method: &str, params: Value, limit: Duration) -> Result<Value, String> {
        let deadline = Instant::now() + limit;
        let id = self.request(method, params)?;
        let v = self.read_until(deadline, |v| is_response(v, id))?;
        match v.get("error") {
            Some(e) => Err(rpc_error_code(e)),
            None => Ok(v["result"].clone()),
        }
    }
}

fn is_response(v: &Value, id: u64) -> bool {
    v.get("method").is_none() && v.get("id") == Some(&json!(id))
}

fn rpc_error_code(e: &Value) -> String {
    if let Some(reason) = e["data"]["reason"].as_str() {
        return reason.to_owned();
    }
    if let Some(code) = e["data"]["code"].as_str() {
        return code.to_owned();
    }
    let msg = e["message"].as_str().unwrap_or("");
    // `register.not_found: ...` and the like: the prefix before the colon.
    if let Some((head, _)) = msg.split_once(':')
        && !head.contains(' ')
    {
        return head.to_owned();
    }
    format!("rpc {}: {}", e["code"], msg.chars().take(60).collect::<String>())
}

/// The rows of a list reply (`{"sessions": [...]}` or a bare array).
fn rows(v: &Value) -> Vec<Value> {
    v["sessions"].as_array().or_else(|| v.as_array()).cloned().unwrap_or_default()
}

fn row_key(row: &Value) -> Option<String> {
    let name = row["name"].as_str().or_else(|| row["sessionId"].as_str())?;
    Some(match row["peer"].as_str().filter(|p| !p.is_empty()) {
        Some(peer) => format!("{peer}/{}", row["sessionId"].as_str().unwrap_or(name)),
        None => name.to_owned(),
    })
}

/// Why a row reads not alive, or none when it reads alive.
fn not_alive(row: &Value) -> Option<String> {
    if row["stale"] == true {
        return Some("stale".into());
    }
    if row["peer"].as_str().is_some_and(|p| !p.is_empty())
        && let Some(state) = row["peerState"].as_str()
        && state != "connected"
        && state != "degraded"
    {
        return Some(format!("peerState={state}"));
    }
    for key in ["alive", "agentAlive", "agentRunning", "connected", "reachable"] {
        if row[key] == false {
            return Some(format!("{key}=false"));
        }
    }
    const DEAD: [&str; 14] = [
        "dead",
        "exited",
        "crashed",
        "failed",
        "error",
        "disconnected",
        "unreachable",
        "unknown",
        "stopped",
        "ended",
        "closed",
        "lost",
        "gone",
        "stale",
    ];
    for key in ["status", "state", "agentState", "liveness"] {
        if let Some(s) = row[key].as_str()
            && DEAD.contains(&s)
        {
            return Some(format!("{key}={s}"));
        }
    }
    None
}

// ---------------------------------------------------------------------------------------------
// Samples.

#[derive(Default)]
struct Samples {
    ms: Vec<f64>,
    outcomes: BTreeMap<String, u64>,
    /// The first full error text of each outcome but `ok`.
    examples: BTreeMap<String, String>,
    /// Rows each successful `ls` returned.
    rows: Vec<usize>,
}

impl Samples {
    fn add(&mut self, took: Duration, outcome: &str) {
        self.ms.push(ms_f(took));
        *self.outcomes.entry(outcome.to_owned()).or_default() += 1;
    }

    fn example(&mut self, outcome: &str, text: &str) {
        if outcome != "ok" && !text.is_empty() {
            self.examples.entry(outcome.to_owned()).or_insert_with(|| text.to_owned());
        }
    }

    fn errors(&self) -> u64 {
        self.outcomes.iter().filter(|(k, _)| !is_success(k)).map(|(_, n)| n).sum()
    }

    fn json(&self) -> Value {
        let mut s = self.ms.clone();
        s.sort_by(f64::total_cmp);
        let at = |q: f64| (!s.is_empty()).then(|| s[((s.len() - 1) as f64 * q).round() as usize]);
        json!({
            "n": s.len(), "p50Ms": at(0.5), "p95Ms": at(0.95), "p99Ms": at(0.99), "maxMs": s.last(),
            "over500Ms": s.iter().filter(|m| **m > SLOW_MS).count(),
            "errors": self.errors(), "outcomes": self.outcomes, "examples": self.examples,
            "rowsMin": self.rows.iter().min(), "rowsMax": self.rows.iter().max(),
        })
    }
}

/// An outcome that is the operation's answer: `ok`, or the refusal every Linux register gets.
fn is_success(outcome: &str) -> bool {
    outcome == "ok" || outcome == "queued" || outcome.starts_with("refused:")
}

/// A register's outcome: off macOS the daemon refuses every caller (no process is proven to be
/// Claude Code), so its `register.*` refusals are its answer.
fn register_outcome(code: &str) -> String {
    if code.starts_with("register.") || code.contains("Claude Code") {
        format!("refused:{code}")
    } else {
        code.to_owned()
    }
}

/// A send to another machine's session (the hub legs): `queued` when the CLI said the hub or the
/// outbox took it, `ok` when it went otherwise, else `send-refused:` and the code (an error).
fn send_outcome(r: &Ran) -> String {
    if r.ok {
        let said = format!("{}\n{}", r.stdout, r.text).to_ascii_lowercase();
        if said.contains("queued") { "queued".into() } else { "ok".into() }
    } else {
        format!("send-refused:{}", r.code)
    }
}

/// The op's name in the report: off macOS every register is refused (`claude_peers.rs`
/// `is_claude_code` reads codesign only), so its rows time a refusal's round trip.
fn op_label(op: &str) -> String {
    if op == "register" && !cfg!(target_os = "macos") {
        "register (refusal round trip)".into()
    } else {
        op.to_owned()
    }
}

// ---------------------------------------------------------------------------------------------
// Liveness.

#[derive(Default)]
struct Liveness {
    polls: u64,
    poll_errors: BTreeMap<String, u64>,
    /// Tracked keys that read not alive at least once, and why the first time.
    false_dead: BTreeMap<String, String>,
    harness_gone_after: Option<f64>,
    external_gone_after: Option<f64>,
    harness_rows: Vec<Value>,
    external_rows: Vec<Value>,
    host: HostSample,
}

struct Tracked {
    /// Keys that read alive before the stressors, but for the two killed ones.
    live: BTreeSet<String>,
    harness: Option<String>,
    external: Option<String>,
    killed_at: Instant,
}

fn poll_liveness(cli: &Cli, tracked: &Tracked, until: Instant, out: &Mutex<Liveness>) {
    while Instant::now() < until {
        let tick = Instant::now();
        out.lock().unwrap().host.take();
        let ran = cli.run(&["--json", "ls"]);
        let mut l = out.lock().unwrap();
        l.polls += 1;
        let parsed: Option<Value> = serde_json::from_str(&ran.stdout).ok();
        match (&ran.ok, parsed) {
            (true, Some(v)) => {
                let by_key: BTreeMap<String, Value> =
                    rows(&v).into_iter().filter_map(|r| Some((row_key(&r)?, r))).collect();
                for key in &tracked.live {
                    let why = match by_key.get(key) {
                        None => Some("missing".to_owned()),
                        Some(r) => not_alive(r),
                    };
                    if let Some(why) = why {
                        l.false_dead.entry(key.clone()).or_insert(why);
                    }
                }
                let since = tracked.killed_at.elapsed().as_secs_f64();
                if let Some(h) = &tracked.harness {
                    let row = by_key.get(h);
                    if l.harness_rows.len() < 3 || l.harness_gone_after.is_none() {
                        let keep = row.cloned().unwrap_or(Value::Null);
                        if l.harness_rows.len() < 3 {
                            l.harness_rows.push(keep);
                        }
                    }
                    if l.harness_gone_after.is_none() && row.is_none_or(|r| not_alive(r).is_some())
                    {
                        l.harness_gone_after = Some(since);
                        l.harness_rows.push(row.cloned().unwrap_or(Value::Null));
                    }
                }
                if let Some(e) = &tracked.external {
                    let row = by_key.get(e);
                    if l.external_rows.len() < 3 {
                        l.external_rows.push(row.cloned().unwrap_or(Value::Null));
                    }
                    if l.external_gone_after.is_none() && row.is_none_or(|r| not_alive(r).is_some())
                    {
                        l.external_gone_after = Some(since);
                        l.external_rows.push(row.cloned().unwrap_or(Value::Null));
                    }
                }
            }
            (true, None) => *l.poll_errors.entry("unparsable".into()).or_default() += 1,
            (false, _) => *l.poll_errors.entry(ran.code.clone()).or_default() += 1,
        }
        drop(l);
        if let Some(rest) = Duration::from_secs(1).checked_sub(tick.elapsed()) {
            std::thread::sleep(rest);
        }
    }
}

/// The pid of a stand-in harness working in `cwd`.
fn harness_in(cwd: &Path) -> Option<i32> {
    let want = std::fs::canonicalize(cwd).ok()?;
    procs().into_iter().map(|(pid, _)| pid).find(|pid| {
        let cmd = std::fs::read(format!("/proc/{pid}/cmdline")).unwrap_or_default();
        String::from_utf8_lossy(&cmd).contains("fake_agent.py")
            && std::fs::read_link(format!("/proc/{pid}/cwd")).is_ok_and(|c| c == want)
    })
}

// ---------------------------------------------------------------------------------------------
// One leg.

struct LegOut {
    row: Value,
    removal_errors: Vec<String>,
}

#[allow(clippy::too_many_lines)]
async fn leg(name: &str, k: &Knobs) -> LegOut {
    let stress = Stress::of(name);
    let scratch_dir = daemon_env::Scratch::new(&format!("duress-{name}"));
    let scratch = scratch_dir.to_path_buf();
    let home = scratch.join("acpmux");
    let claude = scratch.join("claude");
    let work = scratch.join("work");
    let mut notes: Vec<String> = vec![];
    let mut removal_errors: Vec<String> = vec![];
    let mut stress_json_early = serde_json::Map::new();

    // The disk leg's home on a tmpfs, mounted before anything is written to it.
    let mut disk = Disk::Skipped("not in this leg".into());
    if stress.disk {
        disk = match mount_tmpfs(&home) {
            Ok(()) => Disk::Tmpfs { mount: home.clone(), filler: home.join("duress-filler") },
            Err(why) => {
                notes
                    .push(format!("disk: no tmpfs ({why}); RLIMIT_FSIZE {FSIZE_LIMIT} B fallback"));
                Disk::Rlimit
            }
        };
    }
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(claude.join("sessions")).unwrap();

    // The peers, the stub hub, the config and the bridge setting.
    let peer_count = host150::peers_for(name, k.peers);
    let (peer_config, proxies, _hubs) = peers(&scratch, peer_count).await;
    let hub = StubHub::start();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut config = json!({
        "peers": peer_config,
        // `claude` too: the desktop bridge lists the external session as a `claude` chat and
        // refuses one this host has no profile for ("unknown harness \"claude\"").
        "harnesses": {"fake": {"argv": ["python3", fake]}, "claude": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
        "meshRelay": {"url": format!("http://127.0.0.1:{}", hub.port), "tokenCommand": ["/bin/echo", "duress-token"]},
    });
    // The relay legs: the send relay's listing (`sendRelay.lsArgv`), which plain `acpmux ls`
    // runs (`cli/send_relay.rs` `relay_ls`), is a stub that sleeps or fails.
    if stress.relay > 0 || stress.rfd0050 {
        let script = scratch.join("relay-ls.sh");
        let body = if stress.rfd0050 {
            rfd0050::relay_ls_body()
        } else if stress.relay == 1 {
            format!("#!/bin/sh\nsleep {RELAY_SLEEP_SECS}\necho '{{\"sessions\":[]}}'\n")
        } else {
            "#!/bin/sh\necho 'relay: listing failed' >&2\nexit 1\n".to_owned()
        };
        std::fs::write(&script, body).unwrap();
        std::fs::set_permissions(&script, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .unwrap();
        config["sendRelay"] =
            json!({"argv": ["/bin/true"], "lsArgv": [script.display().to_string()]});
        stress_json_early.insert(
            "relayLs".into(),
            json!(if stress.rfd0050 {
                format!("sleeps {}s", rfd0050::BROKER_SECS)
            } else if stress.relay == 1 {
                format!("sleeps {RELAY_SLEEP_SECS}s")
            } else {
                "exits 1".into()
            }),
        );
    }
    // The bigchat leg's chats, written through this build's store before the daemon starts, then
    // pointed at the stand-in agent so a prompt to one runs.
    let mut big: Vec<String> = vec![];
    if stress.bigchat {
        let made = Instant::now();
        match god_fixture::write_scale_home(&home, BIG_CHATS, k.big_records / 4, 1) {
            Ok(ids) => {
                for id in &ids {
                    let meta_path = home.join("sessions").join(id).join("session.json");
                    if let Ok(text) = std::fs::read_to_string(&meta_path)
                        && let Ok(mut meta) = serde_json::from_str::<Value>(&text)
                    {
                        meta["harness"] = json!("fake");
                        meta["harnessArgv"] = json!(["python3", fake]);
                        meta["cwd"] = json!(work.display().to_string());
                        let _ = std::fs::write(&meta_path, meta.to_string());
                    }
                }
                big = ids;
                stress_json_early.insert(
                    "bigChats".into(),
                    json!(format!(
                        "{} x {} records, written in {:.0}s",
                        big.len(),
                        k.big_records,
                        made.elapsed().as_secs_f64()
                    )),
                );
            }
            Err(e) => notes.push(format!("bigchat: fixtures failed: {e}")),
        }
    }
    let host150_high = host150::host150_memory_high();
    let memory_high = if (stress.bigchat && !bigchat_off("memoryhigh")) || stress.host150 {
        let high = if stress.host150 { host150_high.as_str() } else { MEMORY_HIGH };
        match memory_ceiling_works() {
            Ok(()) => {
                stress_json_early.insert("memoryHigh".into(), json!(high));
                Some(high)
            }
            Err(why) => {
                notes.push(format!("memory pressure skipped: {why}"));
                None
            }
        }
    } else {
        None
    };
    let config_path = home.join("config.json");
    std::fs::write(&config_path, config.to_string()).unwrap();
    std::fs::set_permissions(&config_path, std::os::unix::fs::PermissionsExt::from_mode(0o600))
        .unwrap();
    let settings = daemon_env::home(&scratch).join(".config/cmux");
    std::fs::create_dir_all(&settings).unwrap();
    std::fs::write(
        settings.join("cmux-next.json"),
        r#"{"agents":{"desktopBridge":{"enabled":true}}}"#,
    )
    .unwrap();

    // The external Claude Code session: a sleep this bench owns, its registry entry and transcript.
    let ext_cwd = work.join("external");
    std::fs::create_dir_all(&ext_cwd).unwrap();
    let mut external = Command::new("/bin/sleep")
        .arg("100000")
        .process_group(0)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let ext_pid = external.id();
    let ext_session = "11111111-2222-4333-8444-555555555555";
    let ext_cwd_s = ext_cwd.display().to_string();
    std::fs::write(
        claude.join("sessions").join(format!("{ext_pid}.json")),
        json!({"pid": ext_pid, "sessionId": ext_session, "cwd": ext_cwd_s, "entrypoint": "claude-desktop",
               "kind": "interactive", "name": EXTERNAL_NAME, "startedAt": now_ms(), "version": "2.1.0",
               "messagingSocketPath": ext_cwd.join("inbox.sock").display().to_string()})
        .to_string(),
    )
    .unwrap();
    let project = ext_cwd_s.replace(['/', '.'], "-");
    god_fixture::write_claude_jsonl(
        &claude.join("projects").join(project).join(format!("{ext_session}.jsonl")),
        ext_session,
        &ext_cwd_s,
        8,
        8 << 10,
    )
    .unwrap();

    let mut daemon = match Daemon::start(&scratch, &home, &claude, stress.disk, memory_high) {
        Ok(d) => d,
        Err(e) => {
            let _ = external.kill();
            let _ = external.wait();
            if let Disk::Tmpfs { mount, .. } = &disk {
                let _ = sudo(&["/bin/umount", "-l", &mount.display().to_string()]);
            }
            return LegOut { row: json!({"leg": name, "error": e}), removal_errors };
        }
    };
    let cli = Cli {
        scratch: scratch.clone(),
        home: home.clone(),
        socket: daemon.socket.clone(),
        claude: claude.clone(),
        cwd: work.clone(),
    };

    // The live sessions, each in its own folder (so its harness is found by its cwd), and a
    // first turn each so every harness runs.
    let setup = Instant::now();
    // The bigchat leg: 30 sessions at least beside the big chats.
    let count = if stress.bigchat { k.sessions.max(30) } else { k.sessions };
    let names: Vec<String> = (0..count).map(|i| format!("s{i:02}")).collect();
    let mut setup_errors: BTreeMap<String, u64> = BTreeMap::new();
    for n in &names {
        let dir = work.join(n);
        std::fs::create_dir_all(&dir).unwrap();
        let c = Cli { cwd: dir, ..cli.clone() };
        let made = c.run(&["--json", "new", "-d", "-n", n, "-m", "fake"]);
        if !made.ok {
            *setup_errors.entry(format!("new: {}", made.code)).or_default() += 1;
        }
    }
    let rpc_setup = Rpc::connect(&daemon.socket);
    let ids: BTreeMap<String, String> = match rpc_setup {
        Ok(mut r) => r
            .call("_acpmux/sessions", json!({}), CALL_LIMIT)
            .map(|v| {
                rows(&v)
                    .into_iter()
                    .filter_map(|row| {
                        let id =
                            row["sessionId"].as_str().or_else(|| row["id"].as_str())?.to_owned();
                        Some((row["name"].as_str()?.to_owned(), id))
                    })
                    .collect()
            })
            .unwrap_or_default(),
        Err(e) => {
            *setup_errors.entry(format!("socket: {e}")).or_default() += 1;
            BTreeMap::new()
        }
    };
    for n in &names {
        let sent = cli.run(&["send", "--wait", "--timeout", "30", n, "hello"]);
        if !sent.ok {
            *setup_errors.entry(format!("first turn: {}", sent.code)).or_default() += 1;
        }
    }
    // Peers listed and the external session bridged: up to 30 s.
    let expect_peer_rows = peer_count * PEER_ROWS;
    let mut before: BTreeMap<String, Value> = BTreeMap::new();
    let listed_by = Instant::now() + Duration::from_secs(30);
    loop {
        let ran = cli.run(&["--json", "ls"]);
        if let Ok(v) = serde_json::from_str::<Value>(&ran.stdout) {
            before = rows(&v).into_iter().filter_map(|r| Some((row_key(&r)?, r))).collect();
        }
        let peer_rows =
            before.values().filter(|r| r["peer"].as_str().is_some_and(|p| !p.is_empty())).count();
        let ext = before.contains_key(EXTERNAL_NAME);
        if (peer_rows >= expect_peer_rows && ext) || Instant::now() > listed_by {
            if peer_rows < expect_peer_rows {
                notes.push(format!("setup: {peer_rows} of {expect_peer_rows} peer rows listed"));
            }
            if !ext {
                notes.push("setup: the external session was never listed".into());
            }
            break;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    let setup_s = setup.elapsed().as_secs_f64();
    let live_before: BTreeSet<String> =
        before.iter().filter(|(_, r)| not_alive(r).is_none()).map(|(k, _)| k.clone()).collect();
    let external_key = before.keys().find(|k| k.as_str() == EXTERNAL_NAME).cloned();
    let sample_rows: Vec<Value> = before.values().take(2).cloned().collect();

    // The stressors.
    let watchdog = Watchdog::arm(k.cap + host150::extra_cap(name));
    let mut stressors: Vec<Stressor> = vec![];
    let mut stress_json = std::mem::take(&mut stress_json_early);
    if stress.bigchat
        && let Ok(off) = std::env::var("ACPMUX_DURESS_BIGCHAT_OFF")
    {
        stress_json.insert("bigchatOff".into(), json!(off));
    }
    if stress.cpu && !(stress.bigchat && bigchat_off("cpu")) {
        let count = k.cpu_x * cores();
        match Stressor::spawn("cpu", &cpu_script(count), k.cap) {
            Ok(s) => stressors.push(s),
            Err(e) => notes.push(format!("cpu: spawn failed: {e}")),
        }
        stress_json.insert("cpuLoops".into(), json!(count));
    }
    // RFD 0050 rule 7: 90% of the cores busy, the host's RAM held to 90% used, the broker late.
    let mut rfd_cpu0 = None;
    if stress.rfd0050 {
        let cap = k.cap + host150::extra_cap(name);
        let loops = rfd0050::cpu_loops(cores());
        match Stressor::spawn("rfd0050-cpu", &cpu_script(loops), cap) {
            Ok(s) => stressors.push(s),
            Err(e) => notes.push(format!("rfd0050 cpu: spawn failed: {e}")),
        }
        stress_json.insert("cpuLoops".into(), json!(loops));
        stress_json.insert("memUsedPctBefore".into(), json!(rfd0050::mem_used_pct()));
        match rfd0050::hog_bytes() {
            Some(0) | None => notes.push("rfd0050 ram: no hog (already at 90% used)".into()),
            Some(bytes) => match Stressor::spawn("rfd0050-ram", &rfd0050::hog_script(bytes), cap) {
                Ok(s) => {
                    stressors.push(s);
                    stress_json.insert("ramHogMiB".into(), json!(bytes >> 20));
                }
                Err(e) => notes.push(format!("rfd0050 ram: spawn failed: {e}")),
            },
        }
        hub.set(HUB_LATE);
        stress_json.insert("brokerAnswersAfterSecs".into(), json!(rfd0050::BROKER_SECS));
        // The hog touches its pages in 64 MiB steps: give it time to hold them.
        let by = Instant::now() + Duration::from_secs(30);
        while Instant::now() < by
            && rfd0050::mem_used_pct().is_some_and(|p| p < 88.0)
            && stress_json.contains_key("ramHogMiB")
        {
            std::thread::sleep(Duration::from_millis(500));
        }
        stress_json.insert("memUsedPctAtClock".into(), json!(rfd0050::mem_used_pct()));
        rfd_cpu0 = rfd0050::cpu_jiffies();
    }
    if stress.fork {
        match Stressor::spawn("fork", &fork_script(), k.cap) {
            Ok(s) => stressors.push(s),
            Err(e) => notes.push(format!("fork: spawn failed: {e}")),
        }
    }
    let disk_note = match &disk {
        Disk::Tmpfs { filler, .. } => match fill(filler) {
            Ok(bytes) => {
                let (total, free) = statvfs(filler.parent().unwrap()).unwrap_or((0, 0));
                stress_json.insert("diskFillerBytes".into(), json!(bytes));
                format!("tmpfs {TMPFS_MB} MiB, {free} of {total} B free")
            }
            Err(e) => format!("skipped: tmpfs fill failed: {e}"),
        },
        Disk::Rlimit => match set_fsize(daemon.pid(), FSIZE_LIMIT) {
            Ok(()) => format!("rlimit-fsize {FSIZE_LIMIT} B on the daemon (EFBIG, not ENOSPC)"),
            Err(e) => {
                disk = Disk::Skipped(e.clone());
                format!("skipped: {e}")
            }
        },
        Disk::Skipped(why) if stress.disk => format!("skipped: {why}"),
        Disk::Skipped(_) => String::new(),
    };
    if stress.disk {
        stress_json.insert("disk".into(), json!(disk_note));
    }
    if stress.hub503 {
        hub.set(HUB_503);
    }
    if stress.hubslow {
        hub.set(HUB_SLOW);
    }
    if stress.peercut {
        for p in &proxies {
            p.cut(true);
        }
    }
    // Give the load a moment to build before the kills and the clock.
    if stress.cpu || stress.fork || stress.rfd0050 {
        std::thread::sleep(Duration::from_secs(3));
    }
    // host150's stressors and its wait for the load; peerscale's quiet span.
    let wire_sum = |w: &host150::Wire| {
        for p in &proxies {
            for (to, from) in [
                (&w.accepts, &p.wire.accepts),
                (&w.frames, &p.wire.frames),
                (&w.pings, &p.wire.pings),
                (&w.pongs, &p.wire.pongs),
                (&w.data, &p.wire.data),
                (&w.bytes, &p.wire.bytes),
            ] {
                to.fetch_add(from.load(Ordering::Relaxed), Ordering::Relaxed);
            }
            w.open.fetch_add(p.wire.open.load(Ordering::Relaxed), Ordering::Relaxed);
        }
    };
    let wire_now = || {
        let w = host150::Wire::default();
        wire_sum(&w);
        w
    };
    let mut extras =
        host150::Extras::start(name, daemon.pid(), &wire_now, k.cap + host150::extra_cap(name));
    notes.append(&mut extras.notes);
    stress_json.extend(extras.stress.clone());
    if name == host150::BURST_LEG {
        stress_json.insert("peerBurst".into(), host150::peer_burst(&proxies));
    }

    // The kills: one harness and the external session's process.
    let harness_name = names.first().cloned();
    let harness_pid = harness_name.as_ref().and_then(|n| harness_in(&work.join(n)));
    if let Some(pid) = harness_pid {
        // SAFETY: a stand-in harness this bench's daemon started, found by its cwd.
        unsafe { libc::kill(pid, libc::SIGKILL) };
    } else {
        notes.push("false-alive: no stand-in harness found to kill".into());
    }
    let killed_at = Instant::now();
    let _ = external.kill();
    let _ = external.wait();
    let tracked = Tracked {
        live: live_before
            .iter()
            .filter(|k| Some(*k) != harness_name.as_ref() && Some(*k) != external_key.as_ref())
            // A cut peer's rows reading disconnected is the truth, not a false dead: only the
            // local sessions are tracked while the peers are cut (peer keys are `peer/id`).
            .filter(|k| !((stress.peercut || stress.bigchat) && k.contains('/')))
            .cloned()
            .collect(),
        harness: harness_pid.and(harness_name.clone()),
        external: external_key.clone(),
        killed_at,
    };
    let until =
        killed_at + if stress.rfd0050 { k.window.max(rfd0050::WINDOW_MIN) } else { k.window };
    // Peers down on purpose: every one in peercut, the held one (peer00) in bigchat.
    let peer_names: Vec<String> = (0..peer_count).map(|p| format!("peer{p:02}")).collect();
    let cut_peers: BTreeSet<String> = if stress.peercut {
        peer_names.iter().cloned().collect()
    } else if stress.bigchat {
        ["peer00".to_owned()].into()
    } else {
        BTreeSet::new()
    };
    let proxy_ports: BTreeSet<u16> = proxies.iter().map(|p| p.port).collect();
    let window_open = host150::Window::open(&daemon.socket, daemon.pid(), &wire_now(), &daemon.log);
    let presence =
        host150::Presence::start(&daemon.socket, &peer_names, &cut_peers, daemon.pid(), until);
    let hub_requests_before = hub.requests.load(Ordering::SeqCst);
    let hub_paths_before = hub.paths.lock().unwrap().clone();

    // The bigchat leg's load: slow readers on the big chats, one peer held down so sends to its
    // sessions stay unsettled in the outbox, and the drivers until the window ends.
    let mut readers: Vec<Rpc> = vec![];
    let mut drivers = vec![];
    if stress.bigchat {
        let (held, failed) = if bigchat_off("readers") {
            (vec![], BTreeMap::new())
        } else {
            slow_readers(&daemon.socket, &big)
        };
        stress_json.insert("slowReaders".into(), json!({"attached": held.len(), "failed": failed}));
        readers = held;
        // The first peer (`peers` names it `peer00`) held down.
        let far: Vec<String> = proxies
            .first()
            .map(|p| {
                p.cut(true);
                before
                    .values()
                    .filter(|r| r["peer"].as_str() == Some("peer00"))
                    .filter_map(|r| Some(format!("peer00/{}", r["name"].as_str()?)))
                    .collect()
            })
            .unwrap_or_default();
        stress_json.insert("heldPeerTargets".into(), json!(far.len()));
        let live: Vec<String> = names.iter().skip(1).filter_map(|n| ids.get(n).cloned()).collect();
        drivers = bigchat_drivers(&daemon.socket, &big, &live, &far, &work, until);
    }

    // The liveness poll beside the measurements.
    let liveness = Arc::new(Mutex::new(Liveness::default()));
    let poller = {
        let (cli, liveness) = (cli.clone(), liveness.clone());
        let tracked = Tracked {
            live: tracked.live.clone(),
            harness: tracked.harness.clone(),
            external: tracked.external.clone(),
            killed_at,
        };
        std::thread::spawn(move || poll_liveness(&cli, &tracked, until, &liveness))
    };

    // The measurements, round robin until each has n or the window ends. Two control rows beside
    // the CLI's: `true` (spawning /bin/true, the host's floor for starting any process at this
    // load) and `version` (`acpmux --version`: our binary's exec and runtime start, no socket).
    // CLI ls minus `version` is connect, hello and request; `version` minus `true` is our start.
    // Sends to a session on a peer: the hub legs address another machine instead.
    let peer_targets = if stress.hub503 || stress.hubslow {
        vec![]
    } else {
        host150::peer_targets(&before, &cut_peers)
    };
    let mut ids_with_peers = ids.clone();
    ids_with_peers.extend(peer_targets.iter().cloned());
    let pairs: Vec<(&str, &str)> = [
        ("true", "cli"),
        ("version", "cli"),
        ("ls", "cli"),
        ("ls", "socket"),
        ("send", "cli"),
        ("send", "socket"),
        ("register", "cli"),
        ("register", "socket"),
        ("wake", "cli"),
        ("wake", "socket"),
        // One agent tool call's process (`host150::tool_call`).
        ("toolcall", "cli"),
    ]
    .into_iter()
    .chain(
        (stress.bigchat || stress.rfd0050)
            .then_some([("status", "cli"), ("status", "socket")])
            .into_iter()
            .flatten(),
    )
    // RFD 0050: a send the daemon hands to the late broker, beside the local one.
    .chain(
        stress
            .rfd0050
            .then_some([("send-far", "cli"), ("send-far", "socket")])
            .into_iter()
            .flatten(),
    )
    .chain(
        (!peer_targets.is_empty())
            .then_some([("send-peer", "cli"), ("send-peer", "socket")])
            .into_iter()
            .flatten(),
    )
    .collect();
    let mut samples: BTreeMap<(String, String), Samples> = BTreeMap::new();
    let mut rpc: Option<Rpc> = None;
    // The hub legs address a session on a machine no peer is configured for (`HOST/NAME`), so the
    // daemon posts it to the hub (`server/mesh_send.rs`): 503 or held, it answers queued or not.
    let far_target: Option<String> =
        (stress.hub503 || stress.hubslow).then(|| "duress-far-host/duress-far".to_owned());
    if let Some(t) = &far_target {
        stress_json.insert("sendTarget".into(), json!(t));
    }
    let send_targets: Vec<String> = match &far_target {
        // The hub legs send to a session on another machine, so the daemon calls the hub.
        Some(t) => vec![t.clone()],
        None => names.iter().skip(1).take(names.len() / 2).cloned().collect(),
    };
    let wake_targets: Vec<&String> = names.iter().skip(1 + names.len() / 2).collect();
    let mut round = 0usize;
    'window: while Instant::now() < until {
        let mut any = false;
        for &(op, via) in &pairs {
            if Instant::now() >= until {
                break 'window;
            }
            let key = (op.to_owned(), via.to_owned());
            if samples.get(&key).is_some_and(|s| s.ms.len() >= k.n) {
                continue;
            }
            any = true;
            let send_to = send_targets[round % send_targets.len().max(1)].as_str();
            let wake_to = wake_targets[round % wake_targets.len().max(1)];
            let peer_to = peer_targets.get(round % peer_targets.len().max(1)).map(|(t, _)| t);
            let entry = samples.entry(key).or_default();
            if via == "cli" {
                let r = match op {
                    "true" => run_plain("/bin/true", &[]),
                    "version" => cli.run(&["--version"]),
                    "ls" => cli.run(&["--json", "ls"]),
                    "status" => cli.run(&["--json", "daemon", "status"]),
                    "send-far" => {
                        cli.run(&["send", "--no-wait", RFD0050_FAR, &format!("duress {round}")])
                    }
                    "send" => cli.run(&["send", "--no-wait", send_to, &format!("duress {round}")]),
                    "send-peer" => cli.run(&[
                        "send",
                        "--no-wait",
                        peer_to.map_or("", String::as_str),
                        &format!("duress {round}"),
                    ]),
                    "toolcall" => host150::tool_call(&work),
                    "register" => cli.run(&["register", &format!("duress-reg-{round}")]),
                    _ => cli.run(&[
                        "send",
                        "--wait",
                        "--timeout",
                        "30",
                        wake_to,
                        &format!("wake {round}"),
                    ]),
                };
                let outcome = match op {
                    "register" => register_outcome(&r.code),
                    "send" if far_target.is_some() => send_outcome(&r),
                    "send-far" => send_outcome(&r),
                    _ => r.code.clone(),
                };
                if op == "ls"
                    && r.ok
                    && let Ok(v) = serde_json::from_str::<Value>(&r.stdout)
                {
                    entry.rows.push(rows(&v).len());
                }
                entry.example(&outcome, &r.text);
                entry.add(r.took, &outcome);
            } else {
                let (op, send_to) = match (op, peer_to) {
                    ("send-peer", Some(t)) => ("send", t.as_str()),
                    ("send-far", _) => ("send", RFD0050_FAR),
                    _ => (op, send_to),
                };
                let (took, outcome, listed) = socket_op(
                    &mut rpc,
                    &daemon.socket,
                    op,
                    send_to,
                    wake_to,
                    &ids_with_peers,
                    round,
                );
                if let Some(n) = listed {
                    entry.rows.push(n);
                }
                entry.example(&outcome, &outcome);
                entry.add(took, &outcome);
            }
        }
        round += 1;
        if !any {
            // Every op has its n: the rest of the window is the liveness poll's.
            std::thread::sleep(Duration::from_millis(200));
        }
    }
    let _ = poller.join();
    if stress.rfd0050 {
        stress_json.insert(
            "cpuBusyPct".into(),
            json!(rfd0050::busy_pct(rfd_cpu0, rfd0050::cpu_jiffies())),
        );
        stress_json.insert("memUsedPctAtEnd".into(), json!(rfd0050::mem_used_pct()));
    }
    let measures = host150::close(
        window_open,
        &extras,
        presence,
        &daemon.socket,
        daemon.pid(),
        &wire_now(),
        &proxy_ports,
        &peer_names,
        &daemon.log,
    );
    let mut drivers_json = serde_json::Map::new();
    for d in drivers {
        match d.join() {
            Ok((name, v)) => drop(drivers_json.insert(name, v)),
            Err(_) => drop(drivers_json.insert("panicked".into(), json!(true))),
        }
    }
    let readers_held = readers.len();
    drop(readers);
    let hub_requests = hub.requests.load(Ordering::SeqCst) - hub_requests_before;
    let hub_paths: BTreeMap<String, u64> = hub
        .paths
        .lock()
        .unwrap()
        .iter()
        .map(|(k, v)| (k.clone(), v - hub_paths_before.get(k).copied().unwrap_or(0)))
        .filter(|(_, v)| *v > 0)
        .collect();

    // Remove the stressors: groups, filler, limits, proxies, hub.
    for s in &mut stressors {
        if let Err(e) = s.stop() {
            removal_errors.push(e);
        }
    }
    removal_errors.extend(extras.stop());
    drop(watchdog);
    match &disk {
        Disk::Tmpfs { filler, .. } => {
            if let Err(e) = std::fs::remove_file(filler)
                && e.kind() != std::io::ErrorKind::NotFound
            {
                removal_errors.push(format!("disk filler: {e}"));
            }
        }
        Disk::Rlimit => {
            if let Err(e) = set_fsize(daemon.pid(), libc::RLIM_INFINITY) {
                removal_errors.push(format!("disk rlimit: {e}"));
            }
        }
        Disk::Skipped(_) => {}
    }
    hub.set(HUB_OK);
    for p in &proxies {
        p.restore();
    }
    // `try_wait`, not `/proc/PID`: a daemon that ended but is not reaped (a zombie) has one.
    let daemon_ended = daemon.exited();
    let daemon_alive = daemon_ended.is_none();
    let daemon_log = log_tail(&daemon.log);
    let findings = log_findings(&daemon.log);
    // The disk leg: a daemon the CLI started after this one ended logs into the full home.
    let home_log = home.join("daemon.log");
    let home_findings =
        if stress.disk && home_log.exists() { log_findings(&home_log) } else { vec![] };
    drop(rpc);
    drop(daemon);
    let heap = heap_sites();
    for p in &proxies {
        p.cut(false);
    }
    if let Disk::Tmpfs { mount, .. } = &disk
        && let Err(e) = sudo(&["/bin/umount", &mount.display().to_string()])
    {
        // A lazy unmount still removes it from the tree once the last user closes.
        if let Err(e2) = sudo(&["/bin/umount", "-l", &mount.display().to_string()]) {
            removal_errors.push(format!("disk tmpfs: {e}; lazy: {e2}"));
        }
    }

    let l = liveness.lock().unwrap();
    // The window the leg held, not the knob: `rfd0050` holds at least its `WINDOW_MIN`.
    let window_s = until.saturating_duration_since(killed_at).as_secs();
    let gone = |g: Option<f64>, tracked: bool| -> Value {
        match (tracked, g) {
            (false, _) => json!("not tracked"),
            (true, Some(s)) => json!(format!("{s:.1}s")),
            (true, None) => json!(format!(">{window_s}s")),
        }
    };
    let ops_json: Vec<Value> = samples
        .iter()
        .map(|((op, via), s)| {
            let mut v = s.json();
            v["op"] = json!(op);
            // The register rows say what they time; `op` stays `register` for readers of v1.
            v["label"] = json!(op_label(op));
            v["via"] = json!(via);
            v
        })
        .collect();
    let row = json!({
        "leg": name,
        "stressors": stress_json,
        "windowSecs": window_s,
        "setupSecs": setup_s,
        "setupErrors": setup_errors,
        "host": {"cores": cores(), "load1Start": l.host.load1_start, "load1Max": l.host.load1_max,
                 "procsMax": l.host.procs_max, "psiCpuSomeAvg10Max": l.host.psi_max},
        "ops": ops_json,
        "liveness": {
            "tracked": tracked.live.len(),
            "polls": l.polls,
            "pollErrors": l.poll_errors,
            "falseDead": l.false_dead.len(),
            "falseDeadKeys": l.false_dead,
            "falseAliveHarness": gone(l.harness_gone_after, tracked.harness.is_some()),
            "falseAliveExternal": gone(l.external_gone_after, tracked.external.is_some()),
            "harnessRows": l.harness_rows,
            "externalRows": l.external_rows,
        },
        "hubRequests": hub_requests,
        "hubPaths": hub_paths,
        "drivers": drivers_json,
        "slowReadersHeldToEnd": readers_held,
        "daemonAliveAtEnd": daemon_alive,
        "daemonEnded": daemon_ended,
        "daemonLogFindings": findings,
        "homeDaemonLogFindings": home_findings,
        "sampleRows": sample_rows,
        "notes": notes,
        "daemonLogTail": daemon_log.chars().rev().take(1500).collect::<String>().chars().rev().collect::<String>(),
    });
    let mut row = row;
    if let Value::Object(m) = &mut row {
        m.extend(measures);
    }
    row["summary"] = json!(summary(&row));
    let _ = external.kill();
    let _ = external.wait();
    drop(scratch_dir);
    if let Some(h) = heap {
        row["heap"] = h;
    }
    LegOut { row, removal_errors }
}

/// The newest dhat profile in `ACPMUX_DURESS_DHAT_DIR` (a `dhat-heap` build), by site: the
/// bytes each held at the heap's peak, grouped by its first three frames in acpmux's own source.
fn heap_sites() -> Option<Value> {
    let dir = std::env::var_os("ACPMUX_DURESS_DHAT_DIR")?;
    let newest = std::fs::read_dir(&dir)
        .ok()?
        .filter_map(|e| e.ok())
        .filter(|e| e.file_name().to_string_lossy().starts_with("dhat-"))
        .max_by_key(|e| e.metadata().and_then(|m| m.modified()).ok())?
        .path();
    let doc: Value = serde_json::from_str(&std::fs::read_to_string(&newest).ok()?).ok()?;
    let ftbl: Vec<&str> =
        doc["ftbl"].as_array()?.iter().map(|f| f.as_str().unwrap_or("")).collect();
    let mut sites: BTreeMap<String, (u64, u64, u64)> = BTreeMap::new();
    let mut peak = 0u64;
    for pp in doc["pps"].as_array()? {
        let frames: Vec<&str> = pp["fs"]
            .as_array()
            .map(|a| a.iter().filter_map(|i| ftbl.get(i.as_u64()? as usize).copied()).collect())
            .unwrap_or_default();
        let own: Vec<String> = frames
            .iter()
            .filter(|f| {
                f.contains("acpmux/src/")
                    && !f.contains("src/main.rs")
                    && !f.contains("heap_profile")
            })
            .take(3)
            .map(|f| {
                let f = f.split_once(": ").map_or(*f, |(_, r)| r);
                let (name, file) = f.rsplit_once(" (").unwrap_or((f, ""));
                let name = name.split("::h").next().unwrap_or(name);
                let name: Vec<&str> =
                    name.split('<').next().unwrap_or(name).rsplit("::").take(2).collect();
                let file = file.trim_end_matches(')').rsplit("acpmux/src/").next().unwrap_or(file);
                format!("{} ({file})", name.into_iter().rev().collect::<Vec<_>>().join("::"))
            })
            .collect();
        let key = if own.is_empty() { "[outside acpmux]".to_owned() } else { own.join(" < ") };
        let gb = pp["gb"].as_u64().unwrap_or(0);
        let e = sites.entry(key).or_default();
        e.0 += gb;
        e.1 += pp["eb"].as_u64().unwrap_or(0);
        e.2 += pp["gbk"].as_u64().unwrap_or(0);
        peak += gb;
    }
    let mut rows: Vec<_> = sites.into_iter().collect();
    rows.sort_by_key(|(_, (gb, _, _))| std::cmp::Reverse(*gb));
    for (site, (gb, eb, blocks)) in rows.iter().take(40) {
        eprintln!(
            "DURESS-HEAP peak {:>8} KiB end {:>8} KiB blocks {blocks:>8} {site}",
            gb >> 10,
            eb >> 10
        );
    }
    Some(json!({
        "profile": newest.display().to_string(),
        "peakBytes": peak,
        "byPeak": rows.iter().take(40).map(|(s, (gb, eb, n))| json!({"site": s, "peakBytes": gb, "endBytes": eb, "peakBlocks": n})).collect::<Vec<_>>(),
    }))
}

/// The binary under test, copied once into a folder this run owns. On a shared runner another
/// job's cargo build replaces `target/release/acpmux` mid-run, and the daemon swaps itself to
/// the new build ("update: ... was replaced"): round 2's peercut and all legs measured a handover
/// to some other build, not the build under test.
static PINNED: std::sync::OnceLock<(daemon_env::Scratch, PathBuf)> = std::sync::OnceLock::new();

fn pinned_bin() -> &'static Path {
    &PINNED
        .get_or_init(|| {
            let dir = daemon_env::Scratch::new("duress-bin");
            let copy = dir.path().join("acpmux");
            std::fs::copy(daemon_env::bin(), &copy).expect("copy the acpmux binary");
            std::fs::set_permissions(&copy, std::os::unix::fs::PermissionsExt::from_mode(0o755))
                .unwrap();
            (dir, copy)
        })
        .1
}

/// Whether `systemd-run --user --scope -p MemoryHigh=` works here, or why not.
fn memory_ceiling_works() -> Result<(), String> {
    let tool = Path::new("/usr/bin/systemd-run");
    if !tool.exists() {
        return Err("no /usr/bin/systemd-run".into());
    }
    let mut child = Command::new(tool)
        .args([
            "--user",
            "--scope",
            "--quiet",
            "-p",
            &format!("MemoryHigh={MEMORY_HIGH}"),
            "/bin/true",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("systemd-run: {e}"))?;
    let status = child.wait_timeout(Duration::from_secs(10)).ok().flatten();
    let mut err = String::new();
    if let Some(mut e) = child.stderr.take() {
        let _ = e.read_to_string(&mut err);
    }
    match status {
        Some(s) if s.success() => Ok(()),
        Some(_) => Err(format!("systemd-run --user: {}", err.lines().next().unwrap_or("failed"))),
        None => {
            let _ = child.kill();
            let _ = child.wait();
            Err("systemd-run --user did not answer in 10s".into())
        }
    }
}

/// One socket call timed into `samples`, the connection renewed after a transport error.
fn timed_call(
    rpc: &mut Option<Rpc>,
    socket: &Path,
    samples: &mut Samples,
    method: &str,
    params: Value,
) -> Option<Value> {
    let started = Instant::now();
    if rpc.is_none() {
        match Rpc::connect(socket) {
            Ok(r) => *rpc = Some(r),
            Err(e) => {
                samples.example(&e, &e);
                samples.add(started.elapsed(), &e);
                std::thread::sleep(Duration::from_millis(200));
                return None;
            }
        }
    }
    let asked = Instant::now();
    let out = rpc.as_mut().unwrap().call(method, params, CALL_LIMIT);
    let took = asked.elapsed();
    match out {
        Ok(v) => {
            samples.add(took, "ok");
            Some(v)
        }
        Err(e) => {
            if e.starts_with("socket_") || e.starts_with("read:") || e.starts_with("write:") {
                *rpc = None;
            }
            samples.example(&e, &e);
            samples.add(took, &e);
            None
        }
    }
}

/// The bigchat leg's load, beside the measurements until `until`: forks of the big chats (the
/// fork view's exclusive lock), resends of one prompt id to them and to live sessions (the
/// prompt ledger's kind-index scan), watches, team messages, `UNSETTLED` deliveries to a peer
/// held down (the outbox book), and `_acpmux/status` read for its fanout gauges. Each thread's
/// numbers, by driver.
fn bigchat_drivers(
    socket: &Path,
    big: &[String],
    live: &[String],
    far: &[String],
    cwd: &Path,
    until: Instant,
) -> Vec<std::thread::JoinHandle<(String, Value)>> {
    let mut threads = vec![];
    let spawn = |name: &str, f: Box<dyn FnOnce() -> Value + Send>| {
        let name = name.to_owned();
        if bigchat_off(&name) {
            return std::thread::spawn(move || (name, json!("off")));
        }
        std::thread::spawn(move || (name, f()))
    };
    let (sock, b, c) = (socket.to_owned(), big.to_vec(), cwd.display().to_string());
    threads.push(spawn(
        "fork",
        Box::new(move || {
            let (mut rpc, mut s, mut j) = (None, Samples::default(), 0usize);
            while Instant::now() < until && !b.is_empty() {
                let id = &b[j % b.len()];
                timed_call(
                    &mut rpc,
                    &sock,
                    &mut s,
                    "session/fork",
                    json!({"sessionId": id, "cwd": c,
                    "_meta": {"acpmux": {"name": format!("bigfork-{j}")}}}),
                );
                j += 1;
            }
            s.json()
        }),
    ));
    let (sock, b, l) = (socket.to_owned(), big.to_vec(), live.to_vec());
    threads.push(spawn(
        "resend",
        Box::new(move || {
            let (mut rpc, mut s, mut j) = (None, Samples::default(), 0usize);
            let targets: Vec<String> = b.iter().chain(l.iter().take(4)).cloned().collect();
            while Instant::now() < until && !targets.is_empty() {
                let id = &targets[j % targets.len()];
                // The same prompt id every time: after the first, each is a resend.
                timed_call(
                    &mut rpc,
                    &sock,
                    &mut s,
                    "_acpmux/send_queue",
                    json!({"request": {
                    "sessionId": id, "prompt": [{"type": "text", "text": "duress resend"}],
                    "_meta": {"acpmux": {"promptId": format!("duress-resend-{id}")}}}}),
                );
                j += 1;
            }
            s.json()
        }),
    ));
    let (sock, b) = (socket.to_owned(), big.to_vec());
    threads.push(spawn(
        "watch+team",
        Box::new(move || {
            let (mut rpc, mut watch, mut team, mut j) =
                (None, Samples::default(), Samples::default(), 0usize);
            while Instant::now() < until && !b.is_empty() {
                let id = &b[j % b.len()];
                timed_call(
                    &mut rpc,
                    &sock,
                    &mut watch,
                    "_acpmux/watch_add",
                    json!({"sessions": [id], "once": true}),
                );
                timed_call(
                    &mut rpc,
                    &sock,
                    &mut team,
                    "_acpmux/team/send",
                    json!({"to": "@duress/agent", "body": format!("duress team {j}"),
                           "idempotencyKey": format!("duress-team-{}", j % 8)}),
                );
                j += 1;
                std::thread::sleep(Duration::from_millis(250));
            }
            json!({"watchAdd": watch.json(), "teamSend": team.json()})
        }),
    ));
    let (sock, f) = (socket.to_owned(), far.to_vec());
    threads.push(spawn(
        "outbox",
        Box::new(move || {
            let (mut rpc, mut s) = (None, Samples::default());
            for j in 0..UNSETTLED {
                if Instant::now() >= until || f.is_empty() {
                    break;
                }
                timed_call(&mut rpc, &sock, &mut s, "_acpmux/send_queue", json!({"request": {
                    "sessionId": f[j % f.len()], "prompt": [{"type": "text", "text": format!("duress held {j}")}],
                    "_meta": {"acpmux": {"promptId": format!("duress-held-{j}")}}}}));
            }
            s.json()
        }),
    ));
    let sock = socket.to_owned();
    threads.push(spawn(
        "gauges",
        Box::new(move || {
            let (mut rpc, mut s) = (None, Samples::default());
            let (mut last, mut max_ms, mut max_dropped) = (Value::Null, 0f64, 0u64);
            // What every connection's outbound queue held together, at its most, and the
            // status's queues row then (`server/queue_gauge.rs`).
            let (mut held_max, mut conns_max, mut queues_at_max) = (0u64, 0u64, Value::Null);
            while Instant::now() < until {
                if let Some(v) = timed_call(&mut rpc, &sock, &mut s, "_acpmux/status", json!({})) {
                    let queues = &v["gauges"]["queues"];
                    let held = queues["heldBytes"].as_u64().unwrap_or(0);
                    conns_max = conns_max.max(queues["connections"].as_u64().unwrap_or(0));
                    if held >= held_max {
                        held_max = held;
                        queues_at_max = queues.clone();
                        if let Some(rows) = queues_at_max.get_mut("largest") {
                            *rows = json!(rows.as_array().map_or(0, Vec::len));
                        }
                    }
                    let fanout = v["gauges"]["recordWrites"]["fanout"].clone();
                    max_ms = max_ms.max(fanout["maxMs"].as_f64().unwrap_or(0.0));
                    max_dropped = max_dropped.max(fanout["dropped"].as_u64().unwrap_or(0));
                    if !fanout.is_null() {
                        last = fanout;
                    }
                }
                std::thread::sleep(Duration::from_secs(2));
            }
            json!({"status": s.json(), "fanoutLast": last, "fanoutMaxMs": max_ms,
                   "fanoutDroppedMax": max_dropped, "queuesHeldMaxBytes": held_max,
                   "queuesConnectionsMax": conns_max, "queuesAtMax": queues_at_max})
        }),
    ));
    threads
}

/// Connections attached to the big chats' event streams from their start that never read: the
/// daemon's writes to them fill the socket buffers. How many attached, and the failures.
fn slow_readers(socket: &Path, big: &[String]) -> (Vec<Rpc>, BTreeMap<String, u64>) {
    let (mut held, mut failed) = (vec![], BTreeMap::new());
    for i in 0..SLOW_READERS {
        let Some(id) = big.get(i % big.len().max(1)) else { break };
        match Rpc::connect(socket).and_then(|mut r| {
            r.request(
                "_acpmux/attach",
                json!({"sessionId": id, "eventStream": true, "afterSeq": 0, "visible": false}),
            )?;
            Ok(r)
        }) {
            Ok(r) => held.push(r),
            Err(e) => *failed.entry(e).or_default() += 1,
        }
    }
    (held, failed)
}

fn socket_op(
    rpc: &mut Option<Rpc>,
    socket: &Path,
    op: &str,
    send_to: &str,
    wake_to: &str,
    ids: &BTreeMap<String, String>,
    round: usize,
) -> (Duration, String, Option<usize>) {
    let started = Instant::now();
    if rpc.is_none() {
        match Rpc::connect(socket) {
            Ok(r) => *rpc = Some(r),
            Err(e) => return (started.elapsed(), e, None),
        }
    }
    let r = rpc.as_mut().unwrap();
    // Timed from the request: the connection is kept, its connect timed only when it is new.
    let asked = Instant::now();
    let id_of = |name: &str| ids.get(name).cloned().unwrap_or_else(|| name.to_owned());
    let mut listed = None;
    let result: Result<(), String> = match op {
        "ls" => r.call("_acpmux/sessions", json!({}), CALL_LIMIT).map(|v| {
            listed = Some(rows(&v).len());
        }),
        "status" => r.call("_acpmux/status", json!({}), CALL_LIMIT).map(|_| ()),
        "send" => r
            .call(
                "_acpmux/send_queue",
                json!({"request": {"sessionId": id_of(send_to),
                       "prompt": [{"type": "text", "text": format!("duress socket {round}")}],
                       "_meta": {"acpmux": {"promptId": format!("duress-{}-{round}", now_ms())}}}}),
                CALL_LIMIT,
            )
            .map(|_| ()),
        "register" => match r.call(
            "_acpmux/register",
            json!({"name": format!("duress-sreg-{round}")}),
            CALL_LIMIT,
        ) {
            Ok(_) => Ok(()),
            Err(e) => Err(register_outcome(&e)),
        },
        _ => wake(r, &id_of(wake_to), round),
    };
    let took = asked.elapsed();
    match result {
        Ok(()) => (took, "ok".into(), listed),
        Err(e) => {
            if e.starts_with("socket_") || e.starts_with("read:") || e.starts_with("write:") {
                // The connection's state is unknown after a timeout: a fresh one next time.
                *rpc = None;
            }
            let e =
                if op == "send" && send_to.contains('/') { format!("send-refused:{e}") } else { e };
            (took, e, None)
        }
    }
}

/// A prompt to an idle session, timed until its first `session/update`; then its turn's end, so
/// the next wake finds it idle.
fn wake(r: &mut Rpc, id: &str, round: usize) -> Result<(), String> {
    let deadline = Instant::now() + CALL_LIMIT;
    let req = r.request(
        "session/prompt",
        json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("wake socket {round}")}]}),
    )?;
    let first = r.read_until(deadline, |v| {
        is_response(v, req)
            || (v["method"] == "session/update" && v["params"]["sessionId"] == json!(id))
    })?;
    if let Some(e) = first.get("error").filter(|_| is_response(&first, req)) {
        return Err(rpc_error_code(e));
    }
    // The time is taken by the caller when this returns; the turn's end is read on the next call's
    // deadline instead of here, so only the start is timed.
    if !is_response(&first, req) {
        let end = Instant::now() + CALL_LIMIT;
        let _ = r.read_until(end, |v| is_response(v, req));
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// The report.

/// The p99 (ms) of `op` via `via` in a leg's row.
fn p99_of(row: &Value, op: &str, via: &str) -> Option<f64> {
    row["ops"]
        .as_array()?
        .iter()
        .find(|o| o["op"].as_str().is_some_and(|n| n.starts_with(op)) && o["via"] == via)?["p99Ms"]
        .as_f64()
}

/// A leg in one line: the CLI's p99s, false dead and alive, and the split of CLI `ls` into the
/// host's floor for any process (`true`), our start (`version` - `true`) and connect, hello and
/// request (`ls` - `version`).
fn summary(row: &Value) -> String {
    let ms = |v: Option<f64>| v.map_or("-".into(), |m| format!("{m:.0}ms"));
    let (t, v, ls) =
        (p99_of(row, "true", "cli"), p99_of(row, "version", "cli"), p99_of(row, "ls", "cli"));
    let diff = |a: Option<f64>, b: Option<f64>| a.zip(b).map(|(a, b)| a - b);
    let l = &row["liveness"];
    let mut line = format!(
        "{}: p99 cli ls {} send {} register(refusal) {} socket ls {}; false-dead {} of {}; \
         false-alive harness {} external {}; split floor(/bin/true) {} + start(version-true) {} + \
         connect/hello/request(ls-version) {}",
        row["leg"].as_str().unwrap_or(""),
        ms(ls),
        ms(p99_of(row, "send", "cli")),
        ms(p99_of(row, "register", "cli")),
        ms(p99_of(row, "ls", "socket")),
        l["falseDead"],
        l["tracked"],
        l["falseAliveHarness"].as_str().unwrap_or("-"),
        l["falseAliveExternal"].as_str().unwrap_or("-"),
        ms(t),
        ms(diff(v, t)),
        ms(diff(ls, v)),
    );
    line.push_str(&host150::summary_tail(row));
    if t.is_some_and(|t| t > SLOW_MS) {
        line.push_str(
            "; FLOOR OVER 500ms: spawning /bin/true alone misses the target at this load",
        );
    }
    line
}

fn commit() -> String {
    if let Ok(sha) = std::env::var("GITHUB_SHA")
        && !sha.is_empty()
    {
        return sha;
    }
    Command::new("git")
        .args(["-C", env!("CARGO_MANIFEST_DIR"), "rev-parse", "HEAD"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o: Output| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_else(|| "unknown".into())
}

fn fmt_ms(v: &Value) -> String {
    v.as_f64().map_or_else(|| "-".into(), |m| format!("{m:.0}"))
}

fn markdown(report: &Value) -> String {
    let mut md = String::new();
    md.push_str(&format!(
        "acpmux duress bench: host {} ({} cores), commit {}\n\n",
        report["host"].as_str().unwrap_or(""),
        report["cores"],
        report["commit"].as_str().unwrap_or("").chars().take(12).collect::<String>()
    ));
    md.push_str(
        "| leg | op | via | n | p50 ms | p99 ms | max ms | >500ms | errors | error codes | p95 ms |\n",
    );
    md.push_str("|---|---|---|---|---|---|---|---|---|---|---|\n");
    for leg in report["legs"].as_array().into_iter().flatten() {
        let name = leg["leg"].as_str().unwrap_or("");
        if let Some(e) = leg["error"].as_str() {
            md.push_str(&format!(
                "| {name} | - | - | - | - | - | - | - | - | leg failed: {e} | - |\n"
            ));
            continue;
        }
        for op in leg["ops"].as_array().into_iter().flatten() {
            let codes: Vec<String> = op["outcomes"]
                .as_object()
                .into_iter()
                .flatten()
                .filter(|(k, _)| k.as_str() != "ok")
                .map(|(k, v)| format!("{k} x{v}"))
                .collect();
            md.push_str(&format!(
                "| {name} | {} | {} | {} | {} | {} | {} | {} | {} | {} | {} |\n",
                op["label"].as_str().or(op["op"].as_str()).unwrap_or(""),
                op["via"].as_str().unwrap_or(""),
                op["n"],
                fmt_ms(&op["p50Ms"]),
                fmt_ms(&op["p99Ms"]),
                fmt_ms(&op["maxMs"]),
                op["over500Ms"],
                op["errors"],
                codes.join(", ").replace('|', "/"),
                fmt_ms(&op["p95Ms"]),
            ));
        }
    }
    md.push_str("\n| leg | false-dead (of tracked) | false-alive harness | false-alive external | ls polls (failed) | load1 start/max | procs max | psi cpu avg10 max | hub reqs | stressors / notes |\n");
    md.push_str("|---|---|---|---|---|---|---|---|---|---|\n");
    for leg in report["legs"].as_array().into_iter().flatten() {
        if leg.get("error").is_some() {
            continue;
        }
        let l = &leg["liveness"];
        let failed: u64 =
            l["pollErrors"].as_object().into_iter().flatten().filter_map(|(_, v)| v.as_u64()).sum();
        let h = &leg["host"];
        let mut notes: Vec<String> = leg["stressors"]
            .as_object()
            .into_iter()
            .flatten()
            .map(|(k, v)| {
                format!("{k}={}", v.as_str().map_or_else(|| v.to_string(), str::to_owned))
            })
            .collect();
        notes.extend(
            leg["notes"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|n| n.as_str().map(str::to_owned)),
        );
        md.push_str(&format!(
            "| {} | {} of {} | {} | {} | {} ({}) | {}/{} | {} | {} | {} | {} |\n",
            leg["leg"].as_str().unwrap_or(""),
            l["falseDead"],
            l["tracked"],
            l["falseAliveHarness"].as_str().unwrap_or(""),
            l["falseAliveExternal"].as_str().unwrap_or(""),
            l["polls"],
            failed,
            h["load1Start"].as_f64().map_or("-".into(), |v| format!("{v:.1}")),
            h["load1Max"].as_f64().map_or("-".into(), |v| format!("{v:.1}")),
            h["procsMax"],
            h["psiCpuSomeAvg10Max"].as_f64().map_or("-".into(), |v| format!("{v:.1}")),
            leg["hubRequests"],
            notes.join("; ").replace('|', "/")
        ));
    }
    md.push_str(&host150::markdown(report));
    md.push_str("\nPer leg:\n\n");
    for leg in report["legs"].as_array().into_iter().flatten() {
        let name = leg["leg"].as_str().unwrap_or("");
        md.push_str(&format!("- {}\n", leg["summary"].as_str().unwrap_or(name)));
        for key in
            ["hubPaths", "drivers", "daemonEnded", "daemonLogFindings", "homeDaemonLogFindings"]
        {
            let v = &leg[key];
            let empty = v.is_null()
                || v.as_object().is_some_and(serde_json::Map::is_empty)
                || v.as_array().is_some_and(Vec::is_empty);
            if !empty {
                md.push_str(&format!("  - {key}: `{}`\n", v.to_string().replace('`', "'")));
            }
        }
        for op in leg["ops"].as_array().into_iter().flatten() {
            let ex = &op["examples"];
            if ex.as_object().is_some_and(|m| !m.is_empty()) || !op["rowsMin"].is_null() {
                md.push_str(&format!(
                    "  - {} {}: rows {}..{}, examples `{}`\n",
                    op["label"].as_str().or(op["op"].as_str()).unwrap_or(""),
                    op["via"].as_str().unwrap_or(""),
                    op["rowsMin"],
                    op["rowsMax"],
                    ex.to_string().replace('`', "'").chars().take(1200).collect::<String>()
                ));
            }
        }
    }
    md
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "manual: loads the host for minutes; ACPMUX_DURESS=1 on a fleet Linux host"]
async fn duress_bench() {
    let host = hostname();
    if host.to_ascii_lowercase().contains("cosmic-gray") {
        eprintln!("duress bench: refused on {host}: never load cosmic-gray");
        return;
    }
    if std::env::var("ACPMUX_DURESS").as_deref() != Ok("1") {
        eprintln!("duress bench: set ACPMUX_DURESS=1 to run it (it loads the whole host)");
        return;
    }
    let k = Knobs::from_env();
    eprintln!(
        "duress bench on {host}: legs {:?}, window {:?}, cap {:?}, cpu x{}, {} sessions, n {}",
        k.legs, k.window, k.cap, k.cpu_x, k.sessions, k.n
    );
    let mut legs = vec![];
    let mut removal_errors = vec![];
    for name in k.legs.clone() {
        eprintln!("duress bench: leg {name}");
        let out = leg(&name, &k).await;
        eprintln!("DURESS-LEG {}", out.row);
        eprintln!("DURESS-SUMMARY {}", out.row["summary"].as_str().unwrap_or("(leg failed)"));
        removal_errors.extend(out.removal_errors.into_iter().map(|e| format!("{name}: {e}")));
        legs.push(out.row);
        // Let the host settle between legs, so one leg's load is not the next one's.
        std::thread::sleep(Duration::from_secs(10));
    }
    let report = json!({
        "schema": "acpmux.duress-bench.v1",
        "host": host,
        "cores": cores(),
        "commit": commit(),
        "knobs": {"legs": k.legs, "windowSecs": k.window.as_secs(), "capSecs": k.cap.as_secs(),
                  "cpuX": k.cpu_x, "sessions": k.sessions, "n": k.n, "peers": k.peers},
        "legs": legs,
        "removalErrors": removal_errors,
    });
    let md = markdown(&report);
    let keep = daemon_env::Scratch::under(&std::env::temp_dir(), "duress-out", true);
    let out = std::env::var_os("FAST_CHECKS_OUT")
        .map(PathBuf::from)
        .unwrap_or_else(|| keep.to_path_buf());
    std::fs::create_dir_all(&out).unwrap();
    std::fs::write(out.join("duress-bench.json"), serde_json::to_string_pretty(&report).unwrap())
        .unwrap();
    std::fs::write(out.join("duress-bench.md"), &md).unwrap();
    println!("{md}");
    println!("duress bench: wrote {}", out.join("duress-bench.json").display());
    assert!(removal_errors.is_empty(), "stressors that could not be removed: {removal_errors:?}");
}
