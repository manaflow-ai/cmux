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
//!   to be Claude Code (`claude_peers::is_claude_code`), so the daemon refuses every register on
//!   Linux: this times the daemon's walk to that refusal (ancestry, the Claude registry scan),
//!   counted as `refused`, not as a success;
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
//! 30 s), `peercut` (every peer link cut and refused), and `all`. Every stressor runs in its own
//! process group under `timeout -s KILL` at `ACPMUX_DURESS_CAP_SECS` (default 120), a watchdog
//! thread and a Drop guard; the test fails if one could not be removed.
//!
//! Writes `duress-bench.json` (schema `acpmux.duress-bench.v1`) and `duress-bench.md` to
//! `$FAST_CHECKS_OUT` (else a scratch folder it prints) and prints the table. No gate yet.
//! Refuses to run unless `ACPMUX_DURESS=1`, and on any host whose name contains `cosmic-gray`.
//! Linux only. Run:
//! `ACPMUX_DURESS=1 cargo test -p acpmux --release --test duress_daemon -- --ignored --nocapture`.
#![cfg(target_os = "linux")]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// The prompts go to tests/fake_agent.py; the knobs and the output folder hold no credential.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().keep(&[
    "ACPMUX_DURESS",
    "ACPMUX_DURESS_LEGS",
    "ACPMUX_DURESS_SECS",
    "ACPMUX_DURESS_CAP_SECS",
    "ACPMUX_DURESS_CPU_X",
    "ACPMUX_DURESS_SESSIONS",
    "ACPMUX_DURESS_N",
    // The commit under test, when the runner names it (else `git rev-parse HEAD`).
    "GITHUB_SHA",
    // The fleet's output directory, not a credential.
    "FAST_CHECKS_OUT",
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

const ALL_LEGS: [&str; 8] =
    ["baseline", "cpu", "fork", "disk", "hub503", "hubslow", "peercut", "all"];

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
}

impl Knobs {
    fn from_env() -> Self {
        let legs = std::env::var("ACPMUX_DURESS_LEGS")
            .ok()
            .filter(|v| !v.trim().is_empty())
            .map(|v| v.split(',').map(|l| l.trim().to_owned()).filter(|l| !l.is_empty()).collect())
            .unwrap_or_else(|| ALL_LEGS.iter().map(|l| (*l).to_owned()).collect::<Vec<_>>());
        for leg in &legs {
            assert!(ALL_LEGS.contains(&leg.as_str()), "unknown leg {leg:?}; legs: {ALL_LEGS:?}");
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
            // hub503 and hubslow cannot both hold: the stub answers 503 slowly is neither. `all`
            // takes hubslow, the one that held a reader in the field.
            "all" => {
                s = Stress { cpu: true, fork: true, disk: true, hubslow: true, peercut: true, ..s }
            }
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
const HUB_503: u8 = 1;
const HUB_SLOW: u8 = 2;

struct StubHub {
    port: u16,
    mode: Arc<AtomicU8>,
    requests: Arc<AtomicU64>,
    stop: Arc<AtomicBool>,
}

impl StubHub {
    fn start() -> Self {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let mode = Arc::new(AtomicU8::new(HUB_OK));
        let requests = Arc::new(AtomicU64::new(0));
        let stop = Arc::new(AtomicBool::new(false));
        let (m, r, s) = (mode.clone(), requests.clone(), stop.clone());
        std::thread::spawn(move || {
            for conn in listener.incoming() {
                if s.load(Ordering::SeqCst) {
                    return;
                }
                let Ok(conn) = conn else { continue };
                let (m, r, s) = (m.clone(), r.clone(), s.clone());
                std::thread::spawn(move || serve_hub(conn, &m, &r, &s));
            }
        });
        Self { port, mode, requests, stop }
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

fn serve_hub(conn: std::net::TcpStream, mode: &AtomicU8, requests: &AtomicU64, stop: &AtomicBool) {
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
        let answer = match mode.load(Ordering::SeqCst) {
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
                ("200 OK", r#"{"messages":[],"sessions":[],"ok":true}"#.to_owned())
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
}

impl Proxy {
    async fn start(backend: u16) -> Self {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let up = Arc::new(AtomicBool::new(true));
        let links: Arc<Mutex<Vec<tokio::task::AbortHandle>>> = Arc::default();
        let (u, held) = (up.clone(), links.clone());
        tokio::spawn(async move {
            while let Ok((mut client, _)) = listener.accept().await {
                if !u.load(Ordering::SeqCst) {
                    drop(client);
                    continue;
                }
                let task = tokio::spawn(async move {
                    let Ok(mut server) =
                        tokio::net::TcpStream::connect(("127.0.0.1", backend)).await
                    else {
                        return;
                    };
                    let _ = tokio::io::copy_bidirectional(&mut client, &mut server).await;
                });
                held.lock().unwrap().push(task.abort_handle());
            }
        });
        Self { port, up, links }
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

async fn peers(scratch: &Path) -> (Value, Vec<Proxy>, Vec<Arc<Hub>>) {
    let (mut config, mut proxies, mut hubs) = (serde_json::Map::new(), vec![], vec![]);
    for p in 0..PEERS {
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
    ) -> Result<Self, String> {
        let socket = scratch.join("s.sock");
        let log = scratch.join("daemon.log");
        let stderr = std::fs::OpenOptions::new().create(true).append(true).open(&log).unwrap();
        let mut cmd = daemon_env::command(scratch, daemon_env::Agents::StandIn, &[]);
        cmd.args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", home)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("CLAUDE_CONFIG_DIR", claude)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
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
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // SAFETY: the pid is this bench's own child, not yet reaped.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
        if self.child.wait_timeout(Duration::from_secs(20)).ok().flatten().is_none() {
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
}

impl Cli {
    fn run(&self, args: &[&str]) -> Ran {
        let mut cmd = daemon_env::command(&self.scratch, daemon_env::Agents::StandIn, &[]);
        cmd.args(args)
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("CLAUDE_CONFIG_DIR", &self.claude)
            .current_dir(&self.cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let started = Instant::now();
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(e) => {
                return Ran {
                    took: started.elapsed(),
                    ok: false,
                    code: format!("spawn: {}", e.kind()),
                    stdout: String::new(),
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
        let code = if timed_out {
            format!("cli_timeout_{}s", CALL_LIMIT.as_secs())
        } else if ok {
            "ok".into()
        } else {
            error_code(&format!("{stdout}\n{stderr}"))
        };
        Ran { took, ok, code, stdout }
    }
}

/// An error's code as the CLI prints it (`"code": "..."` in a JSON envelope), else a known
/// phrase, else the first line, cut short.
fn error_code(text: &str) -> String {
    for key in ["\"code\":\"", "\"code\": \""] {
        if let Some(at) = text.find(key) {
            let rest = &text[at + key.len()..];
            if let Some(end) = rest.find('"') {
                return rest[..end].to_owned();
            }
        }
    }
    for phrase in
        ["daemon_unreachable", "step stalled", "timed out", "No space left", "File too large"]
    {
        if text.contains(phrase) {
            return phrase.to_owned();
        }
    }
    let line = text.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("no output");
    line.chars().take(80).collect()
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
}

impl Samples {
    fn add(&mut self, took: Duration, outcome: &str) {
        self.ms.push(ms_f(took));
        *self.outcomes.entry(outcome.to_owned()).or_default() += 1;
    }

    fn errors(&self) -> u64 {
        self.outcomes.iter().filter(|(k, _)| !is_success(k)).map(|(_, n)| n).sum()
    }

    fn json(&self) -> Value {
        let mut s = self.ms.clone();
        s.sort_by(f64::total_cmp);
        let at = |q: f64| (!s.is_empty()).then(|| s[((s.len() - 1) as f64 * q).round() as usize]);
        json!({
            "n": s.len(), "p50Ms": at(0.5), "p99Ms": at(0.99), "maxMs": s.last(),
            "over500Ms": s.iter().filter(|m| **m > SLOW_MS).count(),
            "errors": self.errors(), "outcomes": self.outcomes,
        })
    }
}

/// An outcome that is the operation's answer: `ok`, or the refusal every Linux register gets.
fn is_success(outcome: &str) -> bool {
    outcome == "ok" || outcome.starts_with("refused:")
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
    let (peer_config, proxies, _hubs) = peers(&scratch).await;
    let hub = StubHub::start();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let config = json!({
        "peers": peer_config,
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
        "meshRelay": {"url": format!("http://127.0.0.1:{}", hub.port), "tokenCommand": ["/bin/echo", "duress-token"]},
    });
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
               "kind": "interactive", "name": EXTERNAL_NAME, "startedAt": now_ms(), "version": "2.1.0"})
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

    let daemon = match Daemon::start(&scratch, &home, &claude, stress.disk) {
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
    let names: Vec<String> = (0..k.sessions).map(|i| format!("s{i:02}")).collect();
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
    let expect_peer_rows = PEERS * PEER_ROWS;
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
    let watchdog = Watchdog::arm(k.cap);
    let mut stressors: Vec<Stressor> = vec![];
    let mut stress_json = serde_json::Map::new();
    if stress.cpu {
        let count = k.cpu_x * cores();
        match Stressor::spawn("cpu", &cpu_script(count), k.cap) {
            Ok(s) => stressors.push(s),
            Err(e) => notes.push(format!("cpu: spawn failed: {e}")),
        }
        stress_json.insert("cpuLoops".into(), json!(count));
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
    if stress.cpu || stress.fork {
        std::thread::sleep(Duration::from_secs(3));
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
            .filter(|k| !(stress.peercut && k.contains('/')))
            .cloned()
            .collect(),
        harness: harness_pid.and(harness_name.clone()),
        external: external_key.clone(),
        killed_at,
    };
    let until = killed_at + k.window;
    let hub_requests_before = hub.requests.load(Ordering::SeqCst);

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

    // The measurements, round robin until each has n or the window ends.
    let ops = ["ls", "send", "register", "wake"];
    let mut samples: BTreeMap<(String, String), Samples> = BTreeMap::new();
    let mut rpc: Option<Rpc> = None;
    let send_targets: Vec<&String> = names.iter().skip(1).take(names.len() / 2).collect();
    let wake_targets: Vec<&String> = names.iter().skip(1 + names.len() / 2).collect();
    let mut round = 0usize;
    'window: while Instant::now() < until {
        let mut any = false;
        for op in ops {
            for via in ["cli", "socket"] {
                if Instant::now() >= until {
                    break 'window;
                }
                let key = (op.to_owned(), via.to_owned());
                if samples.get(&key).is_some_and(|s| s.ms.len() >= k.n) {
                    continue;
                }
                any = true;
                let send_to = send_targets[round % send_targets.len().max(1)];
                let wake_to = wake_targets[round % wake_targets.len().max(1)];
                let (took, outcome) = if via == "cli" {
                    let r = match op {
                        "ls" => cli.run(&["--json", "ls"]),
                        "send" => {
                            cli.run(&["send", "--no-wait", send_to, &format!("duress {round}")])
                        }
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
                    let outcome = if op == "register" { register_outcome(&r.code) } else { r.code };
                    (r.took, outcome)
                } else {
                    socket_op(&mut rpc, &daemon.socket, op, send_to, wake_to, &ids, round)
                };
                samples.entry(key).or_default().add(took, &outcome);
            }
        }
        round += 1;
        if !any {
            // Every op has its n: the rest of the window is the liveness poll's.
            std::thread::sleep(Duration::from_millis(200));
        }
    }
    let _ = poller.join();
    let hub_requests = hub.requests.load(Ordering::SeqCst) - hub_requests_before;

    // Remove the stressors: groups, filler, limits, proxies, hub.
    for s in &mut stressors {
        if let Err(e) = s.stop() {
            removal_errors.push(e);
        }
    }
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
    let daemon_alive = std::fs::metadata(format!("/proc/{}", daemon.pid())).is_ok();
    let daemon_log = log_tail(&daemon.log);
    drop(rpc);
    drop(daemon);
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
    let window_s = k.window.as_secs();
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
        "daemonAliveAtEnd": daemon_alive,
        "sampleRows": sample_rows,
        "notes": notes,
        "daemonLogTail": daemon_log.chars().rev().take(1500).collect::<String>().chars().rev().collect::<String>(),
    });
    let _ = external.kill();
    let _ = external.wait();
    drop(scratch_dir);
    LegOut { row, removal_errors }
}

fn socket_op(
    rpc: &mut Option<Rpc>,
    socket: &Path,
    op: &str,
    send_to: &str,
    wake_to: &str,
    ids: &BTreeMap<String, String>,
    round: usize,
) -> (Duration, String) {
    let started = Instant::now();
    if rpc.is_none() {
        match Rpc::connect(socket) {
            Ok(r) => *rpc = Some(r),
            Err(e) => return (started.elapsed(), e),
        }
    }
    let r = rpc.as_mut().unwrap();
    // Timed from the request: the connection is kept, its connect timed only when it is new.
    let asked = Instant::now();
    let id_of = |name: &str| ids.get(name).cloned().unwrap_or_else(|| name.to_owned());
    let result: Result<(), String> = match op {
        "ls" => r.call("_acpmux/sessions", json!({}), CALL_LIMIT).map(|_| ()),
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
        Ok(()) => (took, "ok".into()),
        Err(e) => {
            if e.starts_with("socket_") || e.starts_with("read:") || e.starts_with("write:") {
                // The connection's state is unknown after a timeout: a fresh one next time.
                *rpc = None;
            }
            (took, e)
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
        "| leg | op | via | n | p50 ms | p99 ms | max ms | >500ms | errors | error codes |\n",
    );
    md.push_str("|---|---|---|---|---|---|---|---|---|---|\n");
    for leg in report["legs"].as_array().into_iter().flatten() {
        let name = leg["leg"].as_str().unwrap_or("");
        if let Some(e) = leg["error"].as_str() {
            md.push_str(&format!("| {name} | - | - | - | - | - | - | - | - | leg failed: {e} |\n"));
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
                "| {name} | {} | {} | {} | {} | {} | {} | {} | {} | {} |\n",
                op["op"].as_str().unwrap_or(""),
                op["via"].as_str().unwrap_or(""),
                op["n"],
                fmt_ms(&op["p50Ms"]),
                fmt_ms(&op["p99Ms"]),
                fmt_ms(&op["maxMs"]),
                op["over500Ms"],
                op["errors"],
                codes.join(", ").replace('|', "/")
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
                  "cpuX": k.cpu_x, "sessions": k.sessions, "n": k.n},
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
