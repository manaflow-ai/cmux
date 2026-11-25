//! The `agent hook emit` fallback answers inside its installed hook timeout.
//!
//! On a host without the `cmux-tui-hook` helper, a wrapped Claude launch
//! installs `cmux-tui agent hook emit --source claude --event EVENT` for every
//! event except `PreToolUse` (claude_session_hook_settings). Claude kills a
//! hook at its installed timeout (5 s) and shows "A hook didn't answer in time".
//! This runs that command against a daemon that is gone, one that accepts and
//! never answers, and one that answers each request after 3 s: without
//! `--deadline-ms` (the command before, measured only) and with the 3500 ms the
//! installer now writes for 5 s (`emit_deadline_ms`), which must end under 4.5 s.

#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

/// What the installer writes for a hook installed with 5 s.
const DEADLINE_MS: &str = "3500";
/// The agent's 5 s timeout less half a second for process start and the shell.
const BUDGET: Duration = Duration::from_millis(4500);
/// Past this the run is killed and reported as hung.
const CAP: Duration = Duration::from_secs(40);

fn temp_dir(name: &str) -> PathBuf {
    static RUNS: AtomicUsize = AtomicUsize::new(0);
    let run = RUNS.fetch_add(1, Ordering::Relaxed);
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let dir =
        Path::new("/tmp").join(format!("cmux-emit-{name}-{}-{stamp}-{run}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Runs the installed fallback (`emit ... >/dev/null 2>&1||:;echo {}`) once and returns its wall time.
fn emit(dir: &Path, socket: &Path, event: &str, bounded: bool) -> Duration {
    let start = Instant::now();
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["agent", "hook", "emit", "--source", "claude", "--event", event])
        .args(if bounded { vec!["--deadline-ms", DEADLINE_MS] } else { vec![] })
        .env("CMUX_TUI_SOCKET", socket)
        .env("CMUX_MUX_SOCKET", socket)
        .env("HOME", dir)
        .env("XDG_STATE_HOME", dir.join("state"))
        .env("XDG_RUNTIME_DIR", dir.join("run"))
        .env("XDG_CONFIG_HOME", dir.join("config"))
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(br#"{"session_id":"s1","hook_event_name":"Stop"}"#)
        .unwrap();
    loop {
        if child.try_wait().unwrap().is_some() {
            return start.elapsed();
        }
        if start.elapsed() > CAP {
            let _ = child.kill();
            let _ = child.wait();
            return start.elapsed();
        }
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// A daemon that accepts and reads, then answers each line after `delay` (never when `None`).
fn serve(socket: &Path, delay: Option<Duration>) {
    let listener = UnixListener::bind(socket).unwrap();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { return };
            std::thread::spawn(move || {
                let mut writer = stream.try_clone().unwrap();
                for line in BufReader::new(stream).lines() {
                    let Ok(line) = line else { return };
                    let Some(delay) = delay else {
                        std::thread::sleep(Duration::from_secs(3600));
                        return;
                    };
                    std::thread::sleep(delay);
                    let request: serde_json::Value =
                        serde_json::from_str(&line).unwrap_or(serde_json::Value::Null);
                    let answer = serde_json::json!({"id": request["id"], "ok": true, "result": {}});
                    if writeln!(writer, "{answer}").is_err() {
                        return;
                    }
                }
            });
        }
    });
}

fn measure(state: &str, delay: Option<Option<Duration>>, bounded: bool) -> Duration {
    let dir = temp_dir(state);
    let socket = dir.join("d.sock");
    if let Some(delay) = delay {
        serve(&socket, delay);
    }
    let mut runs: Vec<Duration> = (0..5).map(|_| emit(&dir, &socket, "Stop", bounded)).collect();
    runs.sort();
    eprintln!(
        "EMIT-MEASURE side={} state={state} n={} min_ms={} median_ms={} max_ms={}",
        if bounded { "after" } else { "before" },
        runs.len(),
        runs[0].as_millis(),
        runs[runs.len() / 2].as_millis(),
        runs[runs.len() - 1].as_millis()
    );
    let _ = std::fs::remove_dir_all(&dir);
    runs[runs.len() - 1]
}

const STATES: [(&str, Option<Option<Duration>>); 3] =
    [("dead", None), ("stalled", Some(None)), ("slow-3s", Some(Some(Duration::from_secs(3))))];

/// The command before this change, for the numbers; it is not held to the budget.
#[test]
fn emit_without_a_deadline_is_measured() {
    for (state, delay) in STATES {
        measure(state, delay, false);
    }
}

#[test]
fn emit_with_its_installed_deadline_answers_inside_the_hook_timeout() {
    for (state, delay) in STATES {
        let worst = measure(state, delay, true);
        assert!(worst <= BUDGET, "{state}: emit took {worst:?}, over {BUDGET:?}");
    }
}
