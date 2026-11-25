//! The simulated fleet: host daemons and the controller daemon (real `acpmux daemon run`, each its
//! own home, socket and process group), the latency proxy between them, and teardown.
//!
//! Every daemon is a `cmux_process::Child` this run holds (dropping it ends its process group) and
//! is written to `RUN_DIR/fanin-state.json` (pid, home, socket) the moment it starts, so
//! `coord-sim fanin teardown --out RUN_DIR` stops all of them after a crash. A run stops its own at
//! the end of each ramp, on an error, and when `--wall-clock-cap` passes (`ABORT`). Teardown from a
//! state file signals a recorded pid only while that daemon still answers: its home's `daemon.pid`
//! names the pid and its socket accepts (no process table is read).

use super::proc;
use cmux_process::{Child, Command, Stdio};
use serde_json::{Value, json};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread::Scope;
use std::time::{Duration, Instant};

/// Set when the wall-clock cap passed: every loop stops and the run fails.
pub static ABORT: AtomicBool = AtomicBool::new(false);

pub fn aborted() -> Result<(), String> {
    if ABORT.load(Ordering::Relaxed) {
        return Err("wall-clock cap passed: torn down".into());
    }
    Ok(())
}

/// One started daemon, as the state file records it.
#[derive(Clone, Debug)]
pub struct Rec {
    pub role: String,
    pub name: String,
    pub pid: u32,
    pub home: PathBuf,
    pub socket: PathBuf,
    pub bin: PathBuf,
    /// The agents' control folder (its `ctl` gets `exit` at teardown).
    pub fanin_dir: PathBuf,
}

impl Rec {
    fn json(&self) -> Value {
        json!({"role": self.role, "name": self.name, "pid": self.pid,
               "home": self.home, "socket": self.socket, "bin": self.bin, "fanin_dir": self.fanin_dir})
    }
    fn from_json(v: &Value) -> Option<Rec> {
        let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_owned);
        Some(Rec {
            role: s("role")?,
            name: s("name")?,
            pid: v.get("pid")?.as_u64()? as u32,
            home: s("home")?.into(),
            socket: s("socket")?.into(),
            bin: s("bin")?.into(),
            fanin_dir: s("fanin_dir")?.into(),
        })
    }
}

struct State {
    path: Option<PathBuf>,
    recs: Vec<Rec>,
}

static STATE: Mutex<State> = Mutex::new(State { path: None, recs: Vec::new() });

fn state() -> std::sync::MutexGuard<'static, State> {
    STATE.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

pub fn set_state_file(path: PathBuf) {
    state().path = Some(path);
}

fn save(s: &State) {
    if let Some(p) = &s.path {
        let procs: Vec<Value> = s.recs.iter().map(Rec::json).collect();
        let v = json!({"schema": "fanin-state.v1", "procs": procs});
        let _ = std::fs::write(p, format!("{v:#}\n"));
    }
}

/// A started daemon: its record and the child this run holds.
pub struct Daemon {
    pub rec: Rec,
    child: Child,
}

impl Daemon {
    pub fn pid(&self) -> u32 {
        self.rec.pid
    }

    /// Stops this daemon alone and reaps it; the CPU seconds of its whole life (this process's
    /// reaped-children time across the reap, which also counts the short `daemon shutdown` CLI).
    pub fn stop_measured(mut self, tck: f64) -> f64 {
        let before = proc::reaped_children_ticks();
        stop_rec(&self.rec);
        let _ = self.child.wait();
        forget(&[self.rec.pid]);
        proc::reaped_children_ticks().saturating_sub(before) as f64 / tck
    }

    /// Whether it has exited (and with what), without waiting.
    pub fn exited(&mut self) -> Option<String> {
        match self.child.try_wait() {
            Ok(Some(s)) => Some(s.to_string()),
            _ => None,
        }
    }
}

/// The environment every daemon (and so every agent) runs with: nothing from this process but
/// PATH, so no daemon finds the real user's homes, sessions or credentials.
fn env_for(cmd: &mut Command, rec_home: &Path, socket: &Path, agent_hosts: bool) {
    let scratch_home = rec_home.join("userhome");
    let _ = std::fs::create_dir_all(&scratch_home);
    cmd.env_clear()
        .env("PATH", std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".into()))
        .env("HOME", &scratch_home)
        .env("TMPDIR", std::env::temp_dir())
        .env("LANG", "C.UTF-8")
        .env("ACPMUX_HOME", rec_home)
        .env("ACPMUX_SOCKET", socket)
        .env("ACPMUX_LOGIN_ENV", "0")
        .env("ACPMUX_SPARE_HARNESS", "0")
        // No model probe sessions: only the sessions this run makes.
        .env("ACPMUX_PROBE_HARNESSES", "none")
        .env("ACPMUX_SESSION_CPU_CLASS", "normal")
        // A debug build ends with this process (daemon/owner_exit.rs); a release build ignores it.
        .env("ACPMUX_TEST_OWNER_PID", std::process::id().to_string());
    if !agent_hosts {
        cmd.env("ACPMUX_AGENT_HOSTS", "0");
    }
    // An A/B of the daemon's malloc arena cap (`malloc_arenas.rs`): the run's own setting wins.
    if let Some(arenas) = std::env::var_os("MALLOC_ARENA_MAX") {
        cmd.env("MALLOC_ARENA_MAX", arenas);
    }
}

/// The harness every daemon runs its sessions with: this binary's `fanin agent`.
fn harness(fanin_dir: &Path) -> Result<Value, String> {
    let exe = std::env::current_exe().map_err(|e| format!("current_exe: {e}"))?;
    Ok(json!({"fanin": {"argv": [exe, "fanin", "agent"],
                        "env": {"FANIN_DIR": fanin_dir}}}))
}

pub fn free_port() -> Result<u16, String> {
    let l = TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
    l.local_addr().map(|a| a.port()).map_err(|e| e.to_string())
}

pub fn token() -> String {
    // Loopback-only scratch daemons: unique, not secret.
    format!("fanin{:x}{:x}", std::process::id(), super::rpc::now_us())
}

/// Makes `p` (and its missing parents) and narrows it to its owner: acpmux refuses a state
/// directory under a writable, non-sticky ancestor.
pub fn private_dir(p: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(p).map_err(|e| format!("{}: {e}", p.display()))?;
    std::fs::set_permissions(p, std::fs::Permissions::from_mode(0o700))
        .map_err(|e| format!("{}: {e}", p.display()))
}

pub struct Spawn<'a> {
    pub bin: &'a Path,
    pub role: &'a str,
    pub name: &'a str,
    pub home: &'a Path,
    pub socket: &'a Path,
    pub fanin_dir: &'a Path,
    pub config: Value,
    pub agent_hosts: bool,
}

/// Writes the daemon's config (owner-only, as acpmux requires), starts `acpmux daemon run` in its
/// own process group, records it, and waits until its socket answers.
pub fn spawn(s: Spawn) -> Result<Daemon, String> {
    use std::os::unix::fs::PermissionsExt;
    private_dir(s.home)?;
    let mut config = s.config;
    if let Some(o) = config.as_object_mut() {
        o.insert("harnesses".into(), harness(s.fanin_dir)?);
        o.insert("defaultHarness".into(), json!("fanin"));
        o.insert("permissionPolicy".into(), json!("approve-all"));
    }
    let cfg = s.home.join("config.json");
    std::fs::write(&cfg, config.to_string()).map_err(|e| format!("{}: {e}", cfg.display()))?;
    std::fs::set_permissions(&cfg, std::fs::Permissions::from_mode(0o600))
        .map_err(|e| format!("{}: {e}", cfg.display()))?;
    let log = std::fs::File::create(s.home.join("daemon.stderr")).map_err(|e| e.to_string())?;
    let mut cmd = Command::new(s.bin);
    cmd.args(["daemon", "run", "--log", "warn"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(log)
        .process_group(0);
    env_for(&mut cmd, s.home, s.socket, s.agent_hosts);
    let started = Instant::now();
    let child = cmd.spawn().map_err(|e| format!("{}: {e}", s.bin.display()))?;
    let pid = child.id();
    let rec = Rec {
        role: s.role.into(),
        name: s.name.into(),
        pid,
        home: s.home.into(),
        socket: s.socket.into(),
        bin: s.bin.into(),
        fanin_dir: s.fanin_dir.into(),
    };
    {
        let mut st = state();
        st.recs.push(rec.clone());
        save(&st);
    }
    let mut d = Daemon { rec, child };
    loop {
        if std::os::unix::net::UnixStream::connect(s.socket).is_ok() {
            return Ok(d);
        }
        if let Some(how) = d.exited() {
            let err = std::fs::read_to_string(s.home.join("daemon.stderr")).unwrap_or_default();
            let tail: String =
                err.chars().rev().take(1500).collect::<Vec<_>>().into_iter().rev().collect();
            return Err(format!("{} {} exited ({how}) before its socket: {tail}", s.role, s.name));
        }
        if started.elapsed() > Duration::from_secs(90) {
            let mut v = vec![d];
            stop_all(&mut v);
            return Err(format!(
                "{} {} did not bind {} in 90 s",
                s.role,
                s.name,
                s.socket.display()
            ));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Reads a host daemon's peer token (`<home>/run/peer.token`), waiting for it to be written.
pub fn peer_token(home: &Path) -> Result<String, String> {
    let p = home.join("run").join("peer.token");
    let until = Instant::now() + Duration::from_secs(30);
    loop {
        if let Ok(t) = std::fs::read_to_string(&p)
            && !t.trim().is_empty()
        {
            return Ok(t.trim().to_owned());
        }
        if Instant::now() > until {
            return Err(format!("no peer token at {}", p.display()));
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The daemon's own `daemon status --json`, read through its CLI (bounded at 30 s).
pub fn status_json(rec: &Rec) -> Value {
    let mut cmd = Command::new(&rec.bin);
    cmd.args(["--json", "daemon", "status"]);
    env_for(&mut cmd, &rec.home, &rec.socket, false);
    bounded(cmd, Duration::from_secs(30))
        .and_then(|out| serde_json::from_slice(&out).ok())
        .unwrap_or(Value::Null)
}

/// Runs `cmd` to its end or `limit` (then it is killed); its stdout, or None.
fn bounded(mut cmd: Command, limit: Duration) -> Option<Vec<u8>> {
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    let mut child = cmd.spawn().ok()?;
    let mut stdout = child.stdout.take();
    std::thread::scope(|s| {
        let reader = s.spawn(move || {
            let mut buf = Vec::new();
            if let Some(o) = stdout.as_mut() {
                let _ = o.read_to_end(&mut buf);
            }
            buf
        });
        let done = matches!(child.wait_timeout(limit), Ok(Some(_)));
        if !done {
            let _ = child.kill();
            let _ = child.wait();
        }
        let out = reader.join().ok();
        out.filter(|_| done)
    })
}

/// Whether the recorded daemon still runs: its home's `daemon.pid` names its pid (the daemon
/// removes it when it stops) and its socket accepts.
fn alive(rec: &Rec) -> bool {
    let named = std::fs::read_to_string(rec.home.join("daemon.pid"))
        .is_ok_and(|t| t.trim() == rec.pid.to_string());
    named && std::os::unix::net::UnixStream::connect(&rec.socket).is_ok()
}

/// SIGTERM, then SIGKILL, to a recorded daemon's process group, while it still runs.
fn signal_group(rec: &Rec) {
    for (sig, wait) in [("-TERM", 3000u64), ("-KILL", 0)] {
        if !alive(rec) {
            return;
        }
        let _ = Command::new("kill")
            .args([sig, "--", &format!("-{}", rec.pid)])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
        let until = Instant::now() + Duration::from_millis(wait);
        while alive(rec) && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

/// Stops one daemon: its agents told to exit, `daemon shutdown --end-agents`, then its group.
fn stop_rec(rec: &Rec) {
    let _ = std::fs::write(rec.fanin_dir.join("ctl"), "exit");
    if !alive(rec) {
        return;
    }
    let mut cmd = Command::new(&rec.bin);
    cmd.args(["daemon", "shutdown", "--end-agents"]);
    env_for(&mut cmd, &rec.home, &rec.socket, false);
    let _ = bounded(cmd, Duration::from_secs(15));
    let until = Instant::now() + Duration::from_secs(5);
    while alive(rec) && Instant::now() < until {
        std::thread::sleep(Duration::from_millis(50));
    }
    signal_group(rec);
}

fn forget(pids: &[u32]) {
    let mut st = state();
    st.recs.retain(|r| !pids.contains(&r.pid));
    save(&st);
}

/// Stops (in parallel) and reaps daemons this run holds, and forgets them. Returns the CPU clock ticks
/// they used over their lives (reaped-children time across their reaps).
pub fn stop_all(daemons: &mut Vec<Daemon>) -> f64 {
    let before = proc::reaped_children_ticks();
    std::thread::scope(|s| {
        for d in daemons.iter_mut() {
            s.spawn(move || {
                stop_rec(&d.rec);
                let _ = d.child.wait();
            });
        }
    });
    forget(&daemons.iter().map(Daemon::pid).collect::<Vec<_>>());
    daemons.clear();
    proc::reaped_children_ticks().saturating_sub(before) as f64
}

/// Every daemon still recorded, stopped (the wall-clock cap's teardown).
pub fn stop_recorded() {
    let recs = state().recs.clone();
    std::thread::scope(|s| {
        for r in &recs {
            s.spawn(move || stop_rec(r));
        }
    });
}

/// `coord-sim fanin teardown --out RUN_DIR`: stops what RUN_DIR's state file names.
pub fn teardown_dir(dir: &Path) -> Result<(), String> {
    let p = dir.join("fanin-state.json");
    let text = std::fs::read_to_string(&p).map_err(|e| format!("{}: {e}", p.display()))?;
    let v: Value = serde_json::from_str(&text).map_err(|e| format!("{}: {e}", p.display()))?;
    let recs: Vec<Rec> = v
        .get("procs")
        .and_then(Value::as_array)
        .map(|a| a.iter().filter_map(Rec::from_json).collect())
        .unwrap_or_default();
    let live = recs.iter().filter(|r| alive(r)).count();
    std::thread::scope(|s| {
        for r in &recs {
            s.spawn(move || stop_rec(r));
        }
    });
    println!("{}", json!({"teardown": dir, "recorded": recs.len(), "were_live": live}));
    Ok(())
}

/// A TCP proxy to `backend` on loopback that holds every chunk `latency` before passing it on,
/// both ways (a WAN's one-way delay between controller and host). Its threads run in scope `s`
/// until `stop` is set and their connections close. Returns its port.
pub fn proxy<'s>(
    s: &'s Scope<'s, '_>,
    backend: u16,
    latency: Duration,
    stop: &'s AtomicBool,
) -> Result<u16, String> {
    let l = TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
    let port = l.local_addr().map_err(|e| e.to_string())?.port();
    l.set_nonblocking(true).map_err(|e| e.to_string())?;
    s.spawn(move || {
        while !stop.load(Ordering::Relaxed) {
            let conn = match l.accept() {
                Ok((c, _)) => c,
                Err(_) => {
                    std::thread::sleep(Duration::from_millis(20));
                    continue;
                }
            };
            let _ = conn.set_nonblocking(false);
            let Ok(up) = TcpStream::connect(("127.0.0.1", backend)) else { continue };
            let _ = (conn.set_nodelay(true), up.set_nodelay(true));
            let (Ok(c2), Ok(u2)) = (conn.try_clone(), up.try_clone()) else { continue };
            pump(s, conn, up, latency, stop);
            pump(s, u2, c2, latency, stop);
        }
    });
    Ok(port)
}

fn pump<'s>(
    s: &'s Scope<'s, '_>,
    mut from: TcpStream,
    mut to: TcpStream,
    latency: Duration,
    stop: &'s AtomicBool,
) {
    let (tx, rx) = mpsc::channel::<(Instant, Vec<u8>)>();
    // A read that waits at most 200 ms, so the reader sees `stop` once the run ends.
    let _ = from.set_read_timeout(Some(Duration::from_millis(200)));
    let closed = Arc::new(AtomicBool::new(false));
    let closed2 = closed.clone();
    s.spawn(move || {
        let mut buf = vec![0u8; 64 << 10];
        while !stop.load(Ordering::Relaxed) && !closed2.load(Ordering::Relaxed) {
            match from.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if tx.send((Instant::now() + latency, buf[..n].to_vec())).is_err() {
                        break;
                    }
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(_) => break,
            }
        }
        let _ = from.shutdown(std::net::Shutdown::Read);
    });
    s.spawn(move || {
        for (due, bytes) in rx {
            let now = Instant::now();
            if due > now {
                std::thread::sleep(due - now);
            }
            if to.write_all(&bytes).is_err() {
                closed.store(true, Ordering::Relaxed);
                break;
            }
        }
        let _ = to.shutdown(std::net::Shutdown::Write);
    });
}
