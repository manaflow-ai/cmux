//! Every owner start writes how long each startup step took, so a slow first
//! answer after a relaunch names its step (a nightly relaunch on 2026-10-28
//! took 10-17 s to its first `workspace list` and no log said where).
//!
//! The owner appends one JSON line per start to `startup-timings.jsonl` in
//! its session directory once it can answer: the process id, the total from
//! the start of startup to the first possible answer, and each named step
//! with its milliseconds, in order. The file keeps the latest starts only.
#![cfg(all(unix, debug_assertions))]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const TIMINGS_FILE: &str = "startup-timings.jsonl";

struct StateDir(PathBuf);

impl Drop for StateDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn state_dir(label: &str) -> StateDir {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir =
        PathBuf::from("/tmp").join(format!("cmux-stt-{label}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(dir.join("state").join("sessions")).unwrap();
    StateDir(dir)
}

fn command(dir: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .env("CMUX_TUI_STATE_DIR", dir.join("state").join("sessions"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_TUI_LOG_FILE", dir.join("client.log"));
    command
}

struct Owner {
    child: Child,
    dir: PathBuf,
    session: String,
}

impl Owner {
    fn start(dir: &Path, session: &str) -> Self {
        let socket = dir.join("mux.sock");
        let _ = fs::remove_file(&socket);
        let child = command(dir)
            .args(["--headless", "--session", session, "--socket"])
            .arg(&socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let owner = Self { child, dir: dir.to_path_buf(), session: session.to_string() };
        let deadline = Instant::now() + Duration::from_secs(60);
        while !owner.answers() {
            assert!(Instant::now() < deadline, "the owner of {session} never answered");
            std::thread::sleep(Duration::from_millis(50));
        }
        owner
    }

    fn answers(&self) -> bool {
        command(&self.dir)
            .args(["--json", "server", "status", "--session", &self.session, "--socket"])
            .arg(self.dir.join("mux.sock"))
            .output()
            .is_ok_and(|output| {
                output.status.success()
                    && String::from_utf8_lossy(&output.stdout).contains("\"running\"")
            })
    }

    fn pid(&self) -> u32 {
        self.child.id()
    }

    fn stop(mut self) {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let _ = command(&self.dir)
                .args(["server", "stop", "--session", &self.session, "--socket"])
                .arg(self.dir.join("mux.sock"))
                .output();
            let retry = Instant::now() + Duration::from_secs(1);
            while Instant::now() < retry {
                if self.child.try_wait().unwrap().is_some() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            if Instant::now() >= deadline {
                let _ = self.child.kill();
                let _ = self.child.wait();
                panic!("the owner of {} did not stop", self.session);
            }
        }
    }
}

/// The session's timing file (`<session>-<hash>/startup-timings.jsonl`), once it exists.
fn timings_file(dir: &Path, session: &str) -> Option<PathBuf> {
    fs::read_dir(dir.join("state").join("sessions"))
        .ok()?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with(&format!("{session}-")))
        })
        .map(|path| path.join(TIMINGS_FILE))
        .find(|file| file.is_file())
}

/// The timing lines of the session, oldest first, waiting a little for the
/// newest one (it is written right after the owner can answer).
fn timing_lines(dir: &Path, session: &str, at_least: usize) -> Vec<serde_json::Value> {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let lines = timings_file(dir, session)
            .and_then(|file| fs::read_to_string(file).ok())
            .map(|text| {
                text.lines()
                    .map(|line| serde_json::from_str::<serde_json::Value>(line).unwrap())
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        if lines.len() >= at_least {
            return lines;
        }
        assert!(
            Instant::now() < deadline,
            "{TIMINGS_FILE} of {session} has {} line(s), wanted {at_least}",
            lines.len()
        );
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn step_names(line: &serde_json::Value) -> Vec<String> {
    line["steps"]
        .as_array()
        .expect("steps is an array")
        .iter()
        .map(|step| step["step"].as_str().expect("each step has a name").to_string())
        .collect()
}

#[test]
fn each_owner_start_records_its_named_startup_steps() {
    let dir = state_dir("record");
    let session = "startup-timings";

    let first = Owner::start(&dir.0, session);
    let first_pid = first.pid();
    let lines = timing_lines(&dir.0, session, 1);
    first.stop();
    let line = lines.last().unwrap();
    assert_eq!(line["pid"].as_u64(), Some(u64::from(first_pid)), "{line}");
    let names = step_names(line);
    for expected in [
        "socket.bind",
        "registry.schema",
        "registry.integrity_check",
        "restore.snapshot",
        "terminal.adopt_hosts",
        "terminal.respawn_lost",
        "server.attach",
    ] {
        assert!(names.iter().any(|name| name == expected), "no {expected} step in {names:?}");
    }
    // Startup order: the socket first, the attach (the first answer) last.
    assert_eq!(names.first().map(String::as_str), Some("socket.bind"), "{names:?}");
    assert_eq!(names.last().map(String::as_str), Some("server.attach"), "{names:?}");
    let total = line["total_ms"].as_f64().expect("total_ms is a number");
    let sum: f64 = line["steps"]
        .as_array()
        .unwrap()
        .iter()
        .map(|step| step["ms"].as_f64().expect("each step has ms"))
        .sum();
    assert!(sum <= total + 1.0, "steps sum {sum} ms past the total {total} ms: {line}");
    assert!(line["at_ms"].as_u64().is_some(), "{line}");

    // A second start appends its own line after the first.
    let second = Owner::start(&dir.0, session);
    let second_pid = second.pid();
    let lines = timing_lines(&dir.0, session, 2);
    second.stop();
    assert_eq!(lines.len(), 2, "{lines:?}");
    assert_eq!(lines[1]["pid"].as_u64(), Some(u64::from(second_pid)));
}
