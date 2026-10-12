//! `cmux link ensure`, `stop` and `status` at the CLI boundary (cx-rtipa
//! S1): an app starts the per-user link on demand, and links of separate
//! state directories (a tagged DEV app's and the release app's) never share
//! a socket or a registration, also with one runtime directory.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

/// One temporary home with a shared runtime base (`TMPDIR`) for every link.
struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        // Short: the runtime base holds Unix socket paths.
        let root = PathBuf::from("/tmp").join(format!("cle-{name}-{}-{}", std::process::id(), stamp % 1_000_000));
        std::fs::create_dir_all(root.join("home")).unwrap();
        std::fs::create_dir_all(root.join("run")).unwrap();
        Self { root }
    }

    /// A state root (`CMUX_TUI_STATE_DIR`) of one app, e.g. one tag.
    fn app(&self, name: &str) -> App {
        let state_root = self.root.join(name);
        std::fs::create_dir_all(&state_root).unwrap();
        App { root: self.root.clone(), state_root }
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        for name in ["a", "b", "c"] {
            let app = App { root: self.root.clone(), state_root: self.root.join(name) };
            if app.state_root.exists() {
                let _ = app.cmux(&["link", "stop", "--state-dir", app.state_dir().to_str().unwrap()]);
            }
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

struct App {
    root: PathBuf,
    state_root: PathBuf,
}

impl App {
    fn state_dir(&self) -> PathBuf {
        self.state_root.join("link")
    }

    fn cmux(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(args)
            .env("HOME", self.root.join("home"))
            .env("TMPDIR", self.root.join("run"))
            .env_remove("XDG_RUNTIME_DIR")
            .env("CMUX_TUI_STATE_DIR", &self.state_root)
            .output()
            .unwrap()
    }

    fn json(&self, args: &[&str]) -> Value {
        let out = self.cmux(args);
        assert!(
            out.status.success(),
            "{args:?} failed: {}\n{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        let text = String::from_utf8_lossy(&out.stdout);
        let line = text.lines().last().unwrap_or_default();
        serde_json::from_str(line).unwrap_or_else(|e| panic!("{args:?}: not JSON ({e}): {text}"))
    }

    fn ensure(&self, extra: &[&str]) -> Value {
        let dir = self.state_dir();
        let mut args = vec!["link", "ensure", "--state-dir", dir.to_str().unwrap()];
        args.extend_from_slice(extra);
        self.json(&args)
    }

    fn status(&self) -> Value {
        let dir = self.state_dir();
        self.json(&["link", "status", "--state-dir", dir.to_str().unwrap()])
    }

    fn stop(&self) -> Value {
        let dir = self.state_dir();
        self.json(&["link", "stop", "--state-dir", dir.to_str().unwrap()])
    }

    fn registration(&self) -> PathBuf {
        self.state_root.join("link.json")
    }
}

fn pid(value: &Value) -> u32 {
    u32::try_from(value["pid"].as_u64().unwrap_or_else(|| panic!("no pid in {value}"))).unwrap()
}

fn alive(pid: u32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid as libc::pid_t, 0) == 0 }
}

/// `cmux link dial` against `socket` gets an answer from that link: no
/// paired install has this id.
fn dial_answers(app: &App, socket: &Path) {
    let out =
        app.cmux(&["link", "dial", "--host", "inst_nobody", "--socket", socket.to_str().unwrap()]);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(2), "dial: {stderr}");
    assert!(stderr.contains("unknown_host"), "dial: {stderr}");
}

#[test]
fn link_ensure_starts_one_link_and_keeps_it() {
    let base = Scratch::new("one");
    let app = base.app("a");
    let first = app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    assert_eq!(first["status"], "started", "{first}");
    let second = app.ensure(&[]);
    assert_eq!(second["status"], "running", "{second}");
    assert_eq!(pid(&first), pid(&second));
    assert_eq!(first["socket"], second["socket"]);
    let status = app.status();
    assert_eq!(status["running"], true, "{status}");
    assert_eq!(pid(&status), pid(&first));
    assert_eq!(status["install"], "inst_app_a");
    assert!(app.registration().exists());
    dial_answers(&app, Path::new(first["socket"].as_str().unwrap()));
    // The link outlives the `ensure` that started it.
    assert!(alive(pid(&first)));
}

#[test]
fn link_ensure_refuses_another_install_or_port() {
    let base = Scratch::new("mis");
    let app = base.app("a");
    app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    let dir = app.state_dir();
    let out =
        app.cmux(&["link", "ensure", "--state-dir", dir.to_str().unwrap(), "--install", "inst_other"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("install_mismatch"));
    let out = app.cmux(&["link", "ensure", "--state-dir", dir.to_str().unwrap(), "--port", "4101"]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("port_mismatch"));
}

#[test]
fn link_ensure_needs_an_install_the_first_time() {
    let base = Scratch::new("first");
    let app = base.app("a");
    let dir = app.state_dir();
    let out = app.cmux(&["link", "ensure", "--state-dir", dir.to_str().unwrap()]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stderr).contains("--install"));
    assert!(!app.registration().exists());
}

#[test]
fn link_ensure_gives_two_state_dirs_two_links_on_one_runtime_dir() {
    let base = Scratch::new("two");
    let tag = base.app("a");
    let release = base.app("b");
    let a = tag.ensure(&["--install", "inst_tag", "--port", "0"]);
    let b = release.ensure(&["--install", "inst_release", "--port", "0"]);
    assert_eq!(a["status"], "started", "{a}");
    assert_eq!(b["status"], "started", "{b}");
    assert_ne!(pid(&a), pid(&b));
    assert_ne!(a["socket"], b["socket"], "two links share a socket");
    assert_ne!(tag.registration(), release.registration());
    assert_eq!(tag.status()["install"], "inst_tag");
    assert_eq!(release.status()["install"], "inst_release");
    dial_answers(&tag, Path::new(a["socket"].as_str().unwrap()));
    dial_answers(&release, Path::new(b["socket"].as_str().unwrap()));
    // Stopping one leaves the other running.
    assert_eq!(tag.stop()["stopped"], true);
    assert_eq!(tag.status()["running"], false);
    assert_eq!(pid(&release.status()), pid(&b));
}

#[test]
fn link_stop_ends_the_registered_link_and_its_registration() {
    let base = Scratch::new("stop");
    let app = base.app("a");
    let started = app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    let stopped = app.stop();
    assert_eq!(stopped["stopped"], true, "{stopped}");
    assert!(!app.registration().exists(), "link.json stayed after stop");
    assert!(!Path::new(started["socket"].as_str().unwrap()).exists(), "socket stayed after stop");
    assert_eq!(app.status()["running"], false);
    assert_eq!(app.stop()["stopped"], false);
}

#[test]
fn link_ensure_restarts_a_link_that_died() {
    let base = Scratch::new("dead");
    let app = base.app("a");
    let first = app.ensure(&["--install", "inst_app_a", "--port", "0"]);
    let dead = pid(&first);
    // SAFETY: the pid of the link this test started, read from its answer.
    assert_eq!(unsafe { libc::kill(dead as libc::pid_t, libc::SIGKILL) }, 0);
    // A killed link leaves its registration; `ensure` must not trust it.
    let mut reaped = false;
    for _ in 0..200 {
        if !alive(dead) {
            reaped = true;
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    assert!(reaped, "the killed link {dead} is still alive");
    assert_eq!(app.status()["running"], false);
    let again = app.ensure(&[]);
    assert_eq!(again["status"], "started", "{again}");
    assert_ne!(pid(&again), dead);
    dial_answers(&app, Path::new(again["socket"].as_str().unwrap()));
}
