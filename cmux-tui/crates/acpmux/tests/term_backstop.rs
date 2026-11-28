//! A SIGTERM that no task reads still ends the daemon (`daemon/term_backstop.rs`).
//!
//! On a lane VM on 2026-11-28 a daemon whose every runtime worker was held got 29 SIGTERMs from
//! its service manager in four hours; none was read (no "stopping: SIGTERM" line), the stop's
//! watchdog is armed only after that read, and each one ran systemd's 90 s to SIGKILL.
//!
//! The debug seam `ACPMUX_TEST_STOP_UNREAD` parks the stop loop as it takes the SIGTERM, before
//! anything of the stop runs, as a held runtime does. `ACPMUX_TEST_TERM_BACKSTOP_MS` shortens the
//! backstop (30 s in a release build) so the test does not wait it out, or turns it off: the
//! stop as it was before the backstop, in the same harness.
//!
//! `TERM-BACKSTOP` prints one line per mode: `off` (how many were still running at 6 s: all, the
//! "before"), `held` (ms to exit with the backstop at 2 s, with and without `start` in
//! `acpmux.v2`, whose watchdog never arms here), and `free` (a stop not held, which never meets the
//! backstop). Each held exit leaves no pid file and exits with the stop's status.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};

/// The backstop the held runs use, and the window each held exit must land in.
const BACKSTOP_MS: u64 = 2000;
const HELD_MAX_MS: f64 = 4500.0;

/// How long a held stop with the backstop off is watched: three backstops past the signal.
const UNCUT: Duration = Duration::from_secs(6);

/// How long one step of a run (a start, a reply, the exit) may take before the test fails.
const STEP: Duration = Duration::from_secs(120);

struct Daemon {
    child: Child,
    stderr: PathBuf,
}

impl Daemon {
    /// Started over `home` with `env`, and serving: it answered `initialize` and wrote its pid
    /// file.
    fn start(scratch: &Path, home: &Path, env: &[(&str, String)], stderr: PathBuf) -> Self {
        let socket = scratch.join("s.sock");
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
        for (key, value) in env {
            command.env(key, value);
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
            "params": {"protocolVersion": 1, "clientInfo": {"name": "term-backstop"}}});
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
            self.dump();
            panic!("{why}");
        }
    }

    fn dump(&self) {
        let text = std::fs::read(&self.stderr).unwrap_or_default();
        eprint!("{}", String::from_utf8_lossy(&text));
    }

    fn sigterm(&self) {
        // SAFETY: the pid is this test's own child, not yet reaped.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGTERM) };
    }

    /// SIGTERM, then the exit within `within`: its ms and whether it exited with success, or
    /// `None` while it still runs.
    fn stop_within(&mut self, within: Duration) -> Option<(f64, bool)> {
        let sent = Instant::now();
        self.sigterm();
        while sent.elapsed() < within {
            if let Some(status) = self.child.try_wait().unwrap() {
                return Some((sent.elapsed().as_secs_f64() * 1000.0, status.success()));
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        None
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn write_config(home: &Path, start: bool) {
    let surfaces: &[&str] = if start { &["start"] } else { &[] };
    std::fs::create_dir_all(home).unwrap();
    std::fs::write(home.join("config.json"), json!({"acpmux.v2": surfaces}).to_string()).unwrap();
}

#[test]
fn an_unread_sigterm_ends_the_daemon_at_its_backstop() {
    let _ = HERMETIC;
    if !cfg!(debug_assertions) {
        eprintln!("TERM-BACKSTOP-SKIP a release build has no seam");
        return;
    }
    let scratch = daemon_env::Scratch::new("term-backstop");
    let home = scratch.join("acpmux");
    let held = |backstop: &str| {
        vec![
            ("ACPMUX_TEST_STOP_UNREAD", "1".to_string()),
            ("ACPMUX_TEST_TERM_BACKSTOP_MS", backstop.to_string()),
        ]
    };

    // Before: no backstop, and the stop never read its signal: still running.
    write_config(&home, true);
    let mut daemon = Daemon::start(&scratch, &home, &held("off"), scratch.join("off.stderr"));
    let off = daemon.stop_within(UNCUT);
    eprintln!(
        "TERM-BACKSTOP mode=off still_running_at_ms={} running={}",
        UNCUT.as_millis(),
        off.is_none()
    );
    drop(daemon);
    assert!(off.is_none(), "a held stop with no backstop exited: {off:?}");

    // After: the backstop ends it, with and without the watchdog's setting.
    for start in [true, false] {
        write_config(&home, start);
        let tag = if start { "held-start" } else { "held-empty" };
        let mut daemon = Daemon::start(
            &scratch,
            &home,
            &held(&BACKSTOP_MS.to_string()),
            scratch.join(format!("{tag}.stderr")),
        );
        let stopped = daemon.stop_within(STEP);
        eprintln!("TERM-BACKSTOP mode={tag} backstop_ms={BACKSTOP_MS} exit={stopped:?}");
        let Some((ms, success)) = stopped else {
            daemon.dump();
            panic!("{tag}: a held stop was still running {STEP:?} after SIGTERM");
        };
        if !success || !(BACKSTOP_MS as f64..HELD_MAX_MS).contains(&ms) {
            daemon.dump();
        }
        assert!(success, "{tag}: the backstop's exit was not the stop's status");
        assert!(
            (BACKSTOP_MS as f64..HELD_MAX_MS).contains(&ms),
            "{tag}: exited {ms:.0} ms after SIGTERM, not at its {BACKSTOP_MS} ms backstop"
        );
        assert!(!home.join("daemon.pid").exists(), "{tag}: the backstop's exit left the pid file");
    }

    // A stop that is not held never meets the backstop.
    write_config(&home, false);
    let free = vec![("ACPMUX_TEST_TERM_BACKSTOP_MS", BACKSTOP_MS.to_string())];
    let mut daemon = Daemon::start(&scratch, &home, &free, scratch.join("free.stderr"));
    let stopped = daemon.stop_within(STEP);
    eprintln!("TERM-BACKSTOP mode=free exit={stopped:?}");
    let Some((ms, success)) = stopped else { panic!("a free stop did not exit") };
    if !success || ms >= BACKSTOP_MS as f64 {
        daemon.dump();
    }
    assert!(success && ms < BACKSTOP_MS as f64, "a free stop took {ms:.0} ms or failed");
}
