//! The stop's hard exit, over a god home and a small one in one harness (W3, 2026-11-20).
//! Leo: "it's unacceptable to be having so many of these connectivity issues"; the app waited
//! 38 s on a stop whose runtime was held (hq `docs/design/agent-service-v2.md`, row 10).
//!
//! With `start` in `acpmux.v2`, a stop held by the debug seam `ACPMUX_TEST_STOP_STALL` (it parks
//! the stop right after it began, as a stop whose runtime is held does) still ends 800 ms in: the
//! watchdog's thread calls `_exit` with the stop's own status and removes the pid file
//! (`daemon/stop_watchdog.rs`). With the setting empty there is no watchdog, so the same held
//! stop is still running 1,500 ms in, and a stop that is not held is base's.
//!
//! Each run starts the daemon over the home, waits until it answers and has written its pid
//! file, sends SIGTERM and times the process's exit. `STOP-WATCHDOG` prints one line for each
//! home and mode: held stops with `start` (p50, p95, max; every one in [700, 1000) ms), held stops
//! with the setting empty (how many were still running at 1,500 ms: all of them), and stops not
//! held with `start` and with the setting empty (p50, p95, max). The god home's held p95 is at
//! most 1.2 times the small one's.
//!
//! The sizes are a fleet run's: `ACPMUX_WATCHDOG_RUNS` (default 3 for each home and mode) and
//! `ACPMUX_WATCHDOG_GOD_SCALE` (default 0.02 of `Shape::god`). The measured run, on Linux CI:
//! `ACPMUX_WATCHDOG_RUNS=50 ACPMUX_WATCHDOG_GOD_SCALE=1 cargo test -p acpmux --test
//! stop_watchdog -- --nocapture` (a debug build: only it has the seam).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No agent starts; the sizes hold no credential.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::deny().keep(&["ACPMUX_WATCHDOG_RUNS", "ACPMUX_WATCHDOG_GOD_SCALE"]);

use acpmux::god_fixture::{self, Shape};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

/// The bound on every held stop with `start`, and the earliest it may end (its hard point is
/// 800 ms in).
const STOP_MS: f64 = 1000.0;
const HARD_FLOOR_MS: f64 = 700.0;

/// How long a held stop with the setting empty is watched: well past where `start` cuts it.
const UNCUT: Duration = Duration::from_millis(1500);

/// How long one step of a run (a start, a reply, the exit) may take before the test fails.
const STEP: Duration = Duration::from_secs(120);

fn env_or<T: std::str::FromStr>(name: &str, default: T) -> T {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// `Shape::god` at `scale` with no peers (a stop does not wait on them), and the small shape.
fn shapes() -> [Shape; 2] {
    let scale = env_or("ACPMUX_WATCHDOG_GOD_SCALE", 0.02f64).clamp(0.001, 1.0);
    let god = Shape::god();
    let by = |n: usize| ((n as f64 * scale).ceil() as usize).max(1);
    let god = Shape {
        chats: by(god.chats),
        god_messages: by(god.god_messages),
        god_bytes: (god.god_bytes as f64 * scale) as u64,
        peers: 0,
        ..god
    };
    [Shape { peers: 0, ..Shape::small() }, god]
}

fn write_config(home: &Path, start: bool) {
    let surfaces: &[&str] = if start { &["start"] } else { &[] };
    let config = json!({"acpmux.v2": surfaces});
    std::fs::write(home.join("config.json"), config.to_string()).unwrap();
}

struct Daemon {
    child: Child,
    stderr: PathBuf,
}

impl Daemon {
    /// Started over `home`, and serving: it answered `initialize` and wrote its pid file.
    fn start(scratch: &Path, home: &Path, held: bool, stderr: PathBuf) -> Self {
        let socket = scratch.join("s.sock");
        // A held stop this test killed left its pid file; the wait below is for this daemon's.
        let pid_file = home.join("daemon.pid");
        let _ = std::fs::remove_file(&pid_file);
        let log = std::fs::File::create(&stderr).expect("create the daemon's stderr file");
        let mut command = daemon_env::acpmux(scratch);
        command
            .args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", home)
            .env("ACPMUX_SOCKET", &socket)
            .env("ACPMUX_CATALOG_FETCH", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::from(log));
        if held {
            command.env("ACPMUX_TEST_STOP_STALL", "1");
        }
        let spawned = Instant::now();
        let mut daemon = Self { child: command.spawn().unwrap(), stderr };
        let stream = loop {
            if let Ok(stream) = UnixStream::connect(&socket) {
                break stream;
            }
            daemon.fail_if(spawned.elapsed() >= STEP, "the daemon did not bind its socket");
            std::thread::sleep(Duration::from_millis(1));
        };
        stream.set_read_timeout(Some(STEP)).unwrap();
        let hello = json!({"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": 1, "clientInfo": {"name": "stop-watchdog"}}});
        (&stream).write_all(format!("{hello}\n").as_bytes()).unwrap();
        let mut reader = BufReader::new(&stream);
        let answered = loop {
            let mut line = String::new();
            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                break false;
            }
            let v: Value = serde_json::from_str(&line).unwrap_or_default();
            if v.get("method").is_none() && v["id"] == 1 {
                break true;
            }
        };
        daemon.fail_if(!answered, "the daemon did not answer initialize");
        while !pid_file.exists() {
            daemon.fail_if(spawned.elapsed() >= STEP, "the daemon wrote no pid file");
            std::thread::sleep(Duration::from_millis(5));
        }
        daemon
    }

    fn fail_if(&mut self, failed: bool, why: &str) {
        if failed {
            let _ = self.child.kill();
            let _ = self.child.wait();
            let text = std::fs::read(&self.stderr).unwrap_or_default();
            eprint!("{}", String::from_utf8_lossy(&text));
            panic!("{why}");
        }
    }

    fn sigterm(&self) {
        // SAFETY: the pid is this test's own child, not yet reaped.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
    }

    /// SIGTERM, then the exit: how long it took in ms, and whether it exited with success.
    fn stop(&mut self) -> (f64, bool) {
        let sent = Instant::now();
        self.sigterm();
        let status = self.child.wait().unwrap();
        (sent.elapsed().as_secs_f64() * 1000.0, status.success())
    }

    /// SIGTERM, then whether the process still runs after `within`.
    fn still_running_after(&mut self, within: Duration) -> bool {
        let sent = Instant::now();
        self.sigterm();
        while sent.elapsed() < within {
            if self.child.try_wait().unwrap().is_some() {
                return false;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        true
    }
}

/// A run that panics, or a held stop left running, does not leave its daemon writing into a
/// scratch folder being removed.
impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// p50, p95 and max of `samples`.
fn spread(samples: &[f64]) -> (f64, f64, f64) {
    let mut sorted = samples.to_vec();
    sorted.sort_by(f64::total_cmp);
    let at = |q: f64| sorted[((sorted.len() - 1) as f64 * q).round() as usize];
    (at(0.5), at(0.95), sorted[sorted.len() - 1])
}

/// Held stops whose hard exit left the daemon's pid file, over the whole run.
static PID_LEFT: AtomicUsize = AtomicUsize::new(0);

/// Stops of one home and mode: their ms and how many did not exit with success.
fn timed(scratch: &Path, home: &Path, held: bool, runs: usize, tag: &str) -> (Vec<f64>, usize) {
    let (mut ms, mut failed) = (Vec::new(), 0);
    for run in 0..runs {
        let stderr = scratch.join(format!("daemon-{tag}-{run}.stderr"));
        let mut daemon = Daemon::start(scratch, home, held, stderr);
        let (took, success) = daemon.stop();
        if !success || (held && !(HARD_FLOOR_MS..STOP_MS).contains(&took)) {
            let text = std::fs::read(&daemon.stderr).unwrap_or_default();
            eprint!("{}", String::from_utf8_lossy(&text));
        }
        ms.push(took);
        failed += usize::from(!success);
        if held && home.join("daemon.pid").exists() {
            let text = std::fs::read(&daemon.stderr).unwrap_or_default();
            eprint!("{}", String::from_utf8_lossy(&text));
            eprintln!("STOP-WATCHDOG-PID-LEFT mode={tag} run={run} ms={took:.0}");
            PID_LEFT.fetch_add(1, Ordering::Relaxed);
        }
    }
    (ms, failed)
}

fn print_row(home: &str, mode: &str, ms: &[f64], failed: usize) -> f64 {
    let (p50, p95, max) = spread(ms);
    eprintln!(
        "STOP-WATCHDOG home={home} mode={mode} n={} p50={p50:.0} p95={p95:.0} max={max:.0} failed={failed}",
        ms.len()
    );
    p95
}

#[test]
fn a_held_stop_exits_at_800_ms_with_start_and_is_not_cut_without_it() {
    let _ = HERMETIC;
    if !cfg!(debug_assertions) {
        eprintln!("STOP-WATCHDOG-SKIP a release build has no stall seam");
        return;
    }
    let runs = env_or("ACPMUX_WATCHDOG_RUNS", 3usize).max(1);
    let mut held_p95 = Vec::new();
    for shape in shapes() {
        let scratch = daemon_env::Scratch::new(&format!("watchdog-{}", shape.name));
        let home = scratch.join("acpmux");
        let claude = daemon_env::home(&scratch).join(".claude");
        god_fixture::write_home(&home, &claude, &scratch.join("work"), &shape).unwrap();
        let name = shape.name;

        write_config(&home, true);
        let (held, held_failed) = timed(&scratch, &home, true, runs, "start-held");
        held_p95.push(print_row(name, "start-held", &held, held_failed));
        let (free, free_failed) = timed(&scratch, &home, false, runs, "start-free");
        print_row(name, "start-free", &free, free_failed);

        write_config(&home, false);
        let mut running = 0;
        for run in 0..runs {
            let stderr = scratch.join(format!("daemon-empty-held-{run}.stderr"));
            let mut daemon = Daemon::start(&scratch, &home, true, stderr);
            running += usize::from(daemon.still_running_after(UNCUT));
        }
        eprintln!(
            "STOP-WATCHDOG home={name} mode=empty-held n={runs} still_running_at_ms={} running={running}",
            UNCUT.as_millis()
        );
        let (base, base_failed) = timed(&scratch, &home, false, runs, "empty-free");
        print_row(name, "empty-free", &base, base_failed);

        assert_eq!(held_failed, 0, "{name}: a held stop with start did not exit with success");
        let (_, _, max) = spread(&held);
        assert!(
            max < STOP_MS && held.iter().all(|ms| *ms >= HARD_FLOOR_MS),
            "{name}: held stops with start took {held:?} ms, not 800 ms each"
        );
        assert_eq!(running, runs, "{name}: a held stop with the setting empty was cut");
        assert_eq!(free_failed + base_failed, 0, "{name}: a stop that is not held failed");
    }
    let left = PID_LEFT.load(Ordering::Relaxed);
    eprintln!("STOP-WATCHDOG pid_file_left={left}");
    assert_eq!(left, 0, "a hard exit left the daemon's pid file");
    let &[small, god] = &held_p95[..] else { unreachable!() };
    assert!(
        god <= small * 1.2,
        "the god home's held p95 {god:.0} ms is over 1.2x the small one's {small:.0} ms"
    );
}
