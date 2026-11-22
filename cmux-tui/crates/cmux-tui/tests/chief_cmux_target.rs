//! Where a Chief's `cmux` call goes, with and without the cmux app
//! (schemas/chief-cmux-target/vectors.json, shared with the brain host).
//!
//! E17 (2026-10-09): a Chief that `cmux chief` started without the app ran
//! `cmux workspace list` in its turn and got only a socket error: its env
//! named the app's control and daemon links, which no app had made. With the
//! app, the Chief works in the app's daemon; without it, in its own owner
//! daemon. A command only the app can serve says that it needs the app.
#![cfg(unix)]

use std::io::{BufRead, BufReader};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::Value;

static NEXT_DIR: AtomicU64 = AtomicU64::new(0);

/// The sockets that exist: each records the first line of every connection
/// and closes it, so the CLI ends at once.
struct Sockets {
    dir: PathBuf,
    seen: Arc<Mutex<Vec<(String, String)>>>,
}

impl Sockets {
    fn new(names: &[&str]) -> Sockets {
        let n = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
        let dir = PathBuf::from(format!("/tmp/cct-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let seen = Arc::new(Mutex::new(Vec::new()));
        for name in names {
            let listener = UnixListener::bind(dir.join(name)).unwrap();
            let (seen, name) = (seen.clone(), (*name).to_owned());
            std::thread::spawn(move || {
                for stream in listener.incoming() {
                    let Ok(stream) = stream else { return };
                    let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
                    let mut line = String::new();
                    let _ = BufReader::new(&stream).read_line(&mut line);
                    seen.lock().unwrap().push((name.clone(), line));
                }
            });
        }
        Sockets { dir, seen }
    }

    fn reached(&self) -> Vec<String> {
        self.seen.lock().unwrap().iter().map(|(name, _)| name.clone()).collect()
    }
}

impl Drop for Sockets {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

struct Ran {
    code: Option<i32>,
    stderr: String,
}

fn run(dir: &Path, env: &serde_json::Map<String, Value>, args: &[&str]) -> Ran {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .args(args)
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", dir)
        .env("LANG", "en_US.UTF-8")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped());
    for (key, value) in env {
        command.env(key, dir.join(value.as_str().unwrap()));
    }
    let mut child = command.spawn().unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        if child.try_wait().unwrap().is_some() {
            break;
        }
        assert!(Instant::now() < deadline, "cmux {args:?} did not end");
        std::thread::sleep(Duration::from_millis(20));
    }
    let output = child.wait_with_output().unwrap();
    Ran { code: output.status.code(), stderr: String::from_utf8_lossy(&output.stderr).into_owned() }
}

fn vectors() -> Value {
    serde_json::from_str(include_str!("../../../../schemas/chief-cmux-target/vectors.json"))
        .unwrap()
}

#[test]
fn every_vector_sends_daemon_commands_where_the_rule_says() {
    let vectors = vectors();
    let env = vectors["case_environment"].as_object().unwrap();
    for case in vectors["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let names: Vec<&str> =
            case["sockets"].as_array().unwrap().iter().map(|s| s.as_str().unwrap()).collect();
        let sockets = Sockets::new(&names);
        let ran = run(&sockets.dir, env, &["workspace", "list"]);
        let want = case["expect"]["daemon"].as_str().unwrap();
        // The fake socket closes the connection: give its thread a moment.
        let deadline = Instant::now() + Duration::from_secs(2);
        while sockets.reached().is_empty() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }
        let reached = sockets.reached();
        assert!(
            !reached.is_empty() && reached.iter().all(|s| s == want),
            "{name}: `cmux workspace list` reached {reached:?}, want only {want}; stderr: {}",
            ran.stderr
        );
    }
}

#[test]
fn every_vector_sends_app_commands_to_the_app_or_says_it_needs_the_app() {
    let vectors = vectors();
    let env = vectors["case_environment"].as_object().unwrap();
    for case in vectors["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let names: Vec<&str> =
            case["sockets"].as_array().unwrap().iter().map(|s| s.as_str().unwrap()).collect();
        let sockets = Sockets::new(&names);
        let ran = run(&sockets.dir, env, &["window", "list"]);
        match case["expect"]["app"].as_str() {
            Some(want) => {
                let deadline = Instant::now() + Duration::from_secs(2);
                while sockets.reached().is_empty() && Instant::now() < deadline {
                    std::thread::sleep(Duration::from_millis(10));
                }
                let reached = sockets.reached();
                assert_eq!(reached, vec![want.to_owned()], "{name}: stderr {}", ran.stderr);
            }
            None => {
                assert!(sockets.reached().is_empty(), "{name}: reached {:?}", sockets.reached());
                assert_eq!(ran.code, Some(3), "{name}: {}", ran.stderr);
                assert!(
                    ran.stderr.contains("needs the cmux app"),
                    "{name}: no clear needs-the-app error: {}",
                    ran.stderr
                );
                assert!(!ran.stderr.contains("not running at"), "{name}: {}", ran.stderr);
            }
        }
    }
}
