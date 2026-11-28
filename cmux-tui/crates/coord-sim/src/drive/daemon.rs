//! An isolated acpmux daemon for one run: its own scratch HOME, ACPMUX_HOME and socket, a cleared
//! environment (a bare PATH, so no real agent CLI is found), its own process group, and the
//! `coord-sim agent` harnesses in its config. Never the host's daemon.

use super::super::agent::now_us;
use cmux_process::{Child, Command, Stdio};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

pub struct Daemon {
    pub child: Child,
    pub pid: u32,
    pub socket: PathBuf,
    pub home: PathBuf,
    pub acpmux_home: PathBuf,
    pub bin: PathBuf,
}

/// One harness per coordinator: `sim<i>` runs `coord-sim agent` on that coordinator's script.
pub struct Harness {
    pub name: String,
    pub argv: Vec<String>,
}

impl Daemon {
    /// The environment of the daemon and of every `acpmux` CLI call made against it.
    pub fn env(&self) -> Vec<(String, String)> {
        env_for(&self.home, &self.acpmux_home, &self.socket)
    }

    /// The readiness reader runs in scope `s` until the daemon's stdout closes (`stop`).
    pub fn start<'s>(
        s: &'s std::thread::Scope<'s, '_>,
        bin: &Path,
        scratch: &Path,
        harnesses: &[Harness],
        log: &Path,
    ) -> Result<Daemon, String> {
        let home = scratch.join("home");
        let acpmux_home = scratch.join("acpmux");
        // acpmux refuses a state directory under a writable ancestor that is not sticky.
        use std::os::unix::fs::PermissionsExt;
        for d in [&home, &acpmux_home] {
            std::fs::create_dir_all(d).map_err(|e| format!("{}: {e}", d.display()))?;
        }
        for d in [scratch, &home, &acpmux_home] {
            std::fs::set_permissions(d, std::fs::Permissions::from_mode(0o700))
                .map_err(|e| format!("{}: {e}", d.display()))?;
        }
        if let Some(run) = scratch.parent() {
            let _ = std::fs::set_permissions(run, std::fs::Permissions::from_mode(0o755));
        }
        let mut hs = serde_json::Map::new();
        for h in harnesses {
            hs.insert(h.name.clone(), json!({"argv": h.argv}));
        }
        let first = harnesses.first().map(|h| h.name.clone()).unwrap_or_default();
        let config =
            json!({"harnesses": hs, "defaultHarness": first, "permissionPolicy": "approve-all"});
        let cfg_path = acpmux_home.join("config.json");
        // Owner-only: acpmux refuses a config another user could change.
        std::fs::write(&cfg_path, config.to_string())
            .and_then(|_| {
                std::fs::set_permissions(&cfg_path, std::fs::Permissions::from_mode(0o600))
            })
            .map_err(|e| format!("{}: {e}", cfg_path.display()))?;
        // Short: a Unix socket path has a 108-byte limit.
        let socket = std::env::temp_dir().join(format!(
            "cs-{}-{}.sock",
            std::process::id(),
            now_us() % 1_000_000
        ));
        let log_file = std::fs::File::create(log).map_err(|e| format!("{}: {e}", log.display()))?;

        let mut child = Command::new(bin)
            .args(["daemon", "run", "--ready-fd", "1", "--log", "warn"])
            .env_clear()
            .envs(env_for(&home, &acpmux_home, &socket))
            .current_dir(scratch)
            // Its own group (the default here): `stop` signals the group.
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::from(log_file))
            .spawn()
            .map_err(|e| format!("start {}: {e}", bin.display()))?;
        let pid = child.id();
        let stdout = child.stdout.take().ok_or("daemon stdout")?;
        let (tx, rx) = std::sync::mpsc::channel();
        s.spawn(move || {
            let mut ready = false;
            for line in BufReader::new(stdout).lines().map_while(Result::ok) {
                if !ready
                    && serde_json::from_str::<Value>(&line).ok().is_some_and(|v| v["ready"] == true)
                {
                    ready = true;
                    let _ = tx.send(());
                }
            }
        });
        let mut d = Daemon { child, pid, socket, home, acpmux_home, bin: bin.to_path_buf() };
        for _ in 0..180 {
            if rx.recv_timeout(Duration::from_millis(500)).is_ok() {
                return Ok(d);
            }
            if let Ok(Some(status)) = d.child.try_wait() {
                let tail = std::fs::read_to_string(log).unwrap_or_default();
                let tail: String = tail.lines().rev().take(5).collect::<Vec<_>>().join(" | ");
                d.stop();
                return Err(format!("acpmux daemon exited before ready ({status}): {tail}"));
            }
        }
        d.stop();
        Err(format!("acpmux daemon gave no readiness line in 90 s (log: {})", log.display()))
    }

    /// `acpmux daemon stop --end-agents` against this run's daemon: it stops (writing its store)
    /// and ends every agent host and agent it started, which otherwise outlive a daemon on
    /// purpose. A daemon still running 10 s later is ended with its process group (the `Child`).
    pub fn stop(&mut self) {
        let stopping = Command::new(&self.bin)
            .args(["daemon", "stop", "--end-agents"])
            .env_clear()
            .envs(self.env())
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
        if let Ok(mut c) = stopping {
            let _ = c.wait_timeout(Duration::from_secs(60));
        }
        if !matches!(self.child.wait_timeout(Duration::from_secs(10)), Ok(Some(_))) {
            let _ = self.child.kill();
            let _ = self.child.wait();
        }
        let _ = std::fs::remove_file(&self.socket);
    }
}

fn env_for(home: &Path, acpmux_home: &Path, socket: &Path) -> Vec<(String, String)> {
    let s = |p: &Path| p.display().to_string();
    vec![
        ("PATH".into(), "/usr/local/bin:/usr/bin:/bin".into()),
        ("HOME".into(), s(home)),
        ("TMPDIR".into(), std::env::temp_dir().display().to_string()),
        ("ACPMUX_HOME".into(), s(acpmux_home)),
        ("ACPMUX_SOCKET".into(), s(socket)),
        ("ACPMUX_LOGIN_ENV".into(), "0".into()),
        ("ACPMUX_SPARE_HARNESS".into(), "0".into()),
        ("ACPMUX_SESSION_CPU_CLASS".into(), "normal".into()),
        // A debug daemon and its hosts end when this driver does (`daemon/owner_exit.rs`).
        ("ACPMUX_TEST_OWNER_PID".into(), std::process::id().to_string()),
        ("ACPMUX_TEST_SESSION_TMP_BASE".into(), s(&home.join("session-tmp"))),
    ]
}

/// CPU ticks (user + system) of this process's reaped children, from `/proc/self/stat`
/// (cutime + cstime): read before a run and after its daemon is reaped, the difference is the
/// daemon's CPU (with the `acpmux send` calls and whatever the daemon itself reaped).
pub fn children_cpu_s() -> Option<f64> {
    let stat = std::fs::read_to_string("/proc/self/stat").ok()?;
    let fields: Vec<&str> = stat.rsplit_once(')')?.1.split_whitespace().collect();
    // After the name, field 3 is index 0: cutime is field 16, cstime 17 (proc(5)).
    let cutime: u64 = fields.get(13)?.parse().ok()?;
    let cstime: u64 = fields.get(14)?.parse().ok()?;
    Some((cutime + cstime) as f64 / clock_ticks())
}

fn clock_ticks() -> f64 {
    Command::new("getconf")
        .arg("CLK_TCK")
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(100.0)
}

/// Asks the daemon for its own gauges (`_acpmux/status`, what `acpmux daemon status` reads) every
/// 250 ms into `proc.ndjson` until `stop`. cmux-next reads no other process's /proc, so the
/// daemon's memory and queues are its own report:
/// `{"t_us","role":"daemon","rss_kb","peak_rss_kb","status_ms","queued_bytes","queues"}`;
/// `status_ms` is the status call's own latency (a probe of the daemon's responsiveness), and
/// `queued_bytes` the bytes waiting in every connection's outbound queue.
pub fn sample<'s>(
    s: &'s std::thread::Scope<'s, '_>,
    d: &Daemon,
    out: PathBuf,
    stop: Arc<AtomicBool>,
) -> std::thread::ScopedJoinHandle<'s, ()> {
    let socket = d.socket.clone();
    s.spawn(move || {
        let Ok(f) = std::fs::File::create(&out) else { return };
        let mut w = std::io::BufWriter::new(f);
        let Ok(conn) = super::rpc::Conn::connect(s, &socket, Box::new(|_, _| {})) else { return };
        while !stop.load(Ordering::Relaxed) {
            let t = now_us();
            let r = conn.call("_acpmux/status", json!({}), Duration::from_secs(30));
            let status_ms = now_us().saturating_sub(t) as f64 / 1000.0;
            let g = r.as_ref().ok().and_then(|r| r.v.pointer("/result/gauges").cloned()).unwrap_or(Value::Null);
            let kb = |p: &str| g.pointer(p).and_then(Value::as_u64).map(|b| b / 1024);
            let queues = g.get("queues").cloned().unwrap_or(Value::Null);
            let queued: u64 = find_numbers(&queues, "bytes");
            let line = json!({"t_us": t, "role": "daemon", "rss_kb": kb("/memory/rssBytes"),
                "peak_rss_kb": kb("/memory/peakRssBytes"), "status_ms": (status_ms * 10.0).round() / 10.0,
                "ok": r.is_ok(), "queued_bytes": queued, "queues": queues});
            let _ = writeln!(w, "{line}");
            let _ = w.flush();
            std::thread::sleep(Duration::from_millis(250));
        }
        conn.close();
    })
}

/// The sum of every number under a key named `key`, anywhere in `v`.
fn find_numbers(v: &Value, key: &str) -> u64 {
    match v {
        Value::Object(m) => m
            .iter()
            .map(|(k, x)| if k == key { x.as_u64().unwrap_or(0) } else { find_numbers(x, key) })
            .sum(),
        Value::Array(a) => a.iter().map(|x| find_numbers(x, key)).sum(),
        _ => 0,
    }
}
