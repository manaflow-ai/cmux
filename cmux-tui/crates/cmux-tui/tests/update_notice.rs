//! Tester rollout #8 (plans/cmux-next/tui-tester-rollout.md): npm and PyPI
//! installs learn that a newer release exists.
//!
//! The owner asks the install's registry (npm `cmux/latest`, PyPI `cmux`) for
//! the latest release at most once a day and caches the answer in
//! `update-check.json` at the state root; the interactive client prints one
//! localized line with the update command when it exits. The check is off
//! with `updates.checkAutomatically: false`, under `CI`, and for the app's
//! bundled binary (Sparkle updates it). Debug builds take the registry URL
//! and the install channel from the environment.

#![cfg(all(unix, debug_assertions))]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

/// A local registry: answers every request with `body` and reports its path.
fn registry(body: &'static str) -> (String, mpsc::Receiver<String>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut request_line = String::new();
            reader.read_line(&mut request_line).unwrap_or_default();
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).unwrap_or_default() == 0 || line == "\r\n" {
                    break;
                }
            }
            let path = request_line.split_whitespace().nth(1).unwrap_or_default().to_string();
            let _ = sender.send(path);
            let _ = stream.write_all(
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .as_bytes(),
            );
        }
    });
    (format!("http://127.0.0.1:{port}/cmux/latest"), receiver)
}

fn temp_dir(tag: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!("cmux-un-{tag}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(dir.join("state").join("sessions")).unwrap();
    dir
}

fn command(dir: &Path, url: &str) -> Command {
    let mut command = Command::new(bin());
    command
        .env("CMUX_TUI_STATE_DIR", dir.join("state").join("sessions"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_NEXT_CONFIG_FILE", dir.join("cmux-next.json"))
        .env("CMUX_TUI_LOG_FILE", dir.join("client.log"))
        .env("CMUX_TUI_TEST_REGISTRY_URL", url)
        .env("CMUX_TUI_TEST_INSTALL_CHANNEL", "npm")
        .env_remove("CI");
    command
}

struct Owner {
    child: Child,
    dir: PathBuf,
    url: String,
    session: &'static str,
}

impl Owner {
    fn start(dir: &Path, url: &str, session: &'static str) -> Owner {
        let child = command(dir, url)
            .args(["--headless", "--session", session, "--socket"])
            .arg(dir.join("mux.sock"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        Owner { child, dir: dir.to_path_buf(), url: url.to_string(), session }
    }

    /// The owner's one `update-check:` outcome line for this start.
    fn outcome(&self, starts_seen: usize) -> String {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let log = fs::read_to_string(self.dir.join("client.log")).unwrap_or_default();
            let outcomes: Vec<&str> =
                log.lines().filter(|line| line.contains("update-check:")).collect();
            if outcomes.len() > starts_seen {
                return outcomes[starts_seen].to_string();
            }
            assert!(Instant::now() < deadline, "no update-check outcome in client.log:\n{log}");
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

impl Drop for Owner {
    fn drop(&mut self) {
        let _ = command(&self.dir, &self.url)
            .args(["server", "stop", "--session", self.session, "--end-terminals", "--socket"])
            .arg(self.dir.join("mux.sock"))
            .output();
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
    }
}

#[test]
fn update_notice_the_owner_caches_the_latest_release_once_a_day() {
    let (url, requests) = registry(r#"{"name":"cmux","version":"99.0.0"}"#);
    let dir = temp_dir("check");
    let owner = Owner::start(&dir, &url, "un-check");
    let outcome = owner.outcome(0);
    assert!(outcome.contains("update-check: latest=99.0.0"), "{outcome}");
    assert_eq!(requests.recv_timeout(Duration::from_secs(5)).unwrap(), "/cmux/latest");
    let cache: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(dir.join("state").join("update-check.json")).unwrap(),
    )
    .unwrap();
    assert_eq!(cache["latest"], "99.0.0", "{cache}");
    assert_eq!(cache["channel"], "npm", "{cache}");
    drop(owner);

    // Within the day the next start asks nobody.
    let owner = Owner::start(&dir, &url, "un-check");
    let outcome = owner.outcome(1);
    assert!(outcome.contains("update-check: not due"), "{outcome}");
    assert!(requests.try_recv().is_err(), "the registry was asked twice in one day");
    drop(owner);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn update_notice_is_off_when_the_setting_turns_it_off() {
    let (url, requests) = registry(r#"{"name":"cmux","version":"99.0.0"}"#);
    let dir = temp_dir("off");
    fs::write(dir.join("cmux-next.json"), r#"{ "updates": { "checkAutomatically": false } }"#)
        .unwrap();
    let owner = Owner::start(&dir, &url, "un-off");
    let outcome = owner.outcome(0);
    assert!(
        outcome.contains("update-check: off") && outcome.contains("updates.checkAutomatically"),
        "{outcome}"
    );
    assert!(requests.try_recv().is_err(), "the registry was asked with the check off");
    drop(owner);
    let _ = fs::remove_dir_all(&dir);
}
