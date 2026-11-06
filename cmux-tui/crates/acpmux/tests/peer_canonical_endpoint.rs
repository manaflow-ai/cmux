//! One acpmux per machine (hq plans/cmux-next/acpmux-one-daemon.md): a peer is
//! reached at its canonical endpoint, `ssh://HOST`: the ssh config's user and
//! the machine's one daemon on the default port. `acpmux host add NAME` with no
//! URL adds exactly that, and `acpmux host ls` names an entry that points
//! somewhere else (a user, another port: a second daemon on that machine), so
//! it can be moved. Nothing re-points an entry by itself.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::PathBuf;
use std::process::{Child, Output, Stdio};
use std::time::{Duration, Instant};
use wait_timeout::ChildExt;

struct Daemon {
    child: Option<Child>,
    home: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut c) = self.child.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

fn start(tag: &str) -> Daemon {
    let home = std::env::temp_dir().join(format!("pce-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let mut child = daemon_env::acpmux(&home)
        .args([
            "daemon",
            "run",
            "--memory",
            "--listen",
            "127.0.0.1:0",
            "--ready-fd",
            "1",
            "--log",
            "warn",
        ])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", home.join("s.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if line.starts_with('{') {
                let _ = tx.send(());
            }
        }
    });
    let d = Daemon { child: Some(child), home };
    rx.recv_timeout(Duration::from_secs(20)).expect("daemon ready");
    d
}

fn cli(d: &Daemon, args: &[&str]) -> Output {
    let out = daemon_env::acpmux(&d.home)
        .args(args)
        .env("ACPMUX_HOME", &d.home)
        .env("ACPMUX_SOCKET", d.home.join("s.sock"))
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "acpmux {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out
}

fn cli_bounded(d: &Daemon, args: &[&str], limit: Duration) -> Output {
    let mut child = daemon_env::acpmux(&d.home)
        .args(args)
        .env("ACPMUX_HOME", &d.home)
        .env("ACPMUX_SOCKET", d.home.join("s.sock"))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    if child.wait_timeout(limit).unwrap().is_none() {
        let _ = child.kill();
        let _ = child.wait();
        panic!("acpmux {args:?} exceeded {limit:?}");
    }
    let out = child.wait_with_output().unwrap();
    assert!(
        out.status.success(),
        "acpmux {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    out
}

fn saved_url(d: &Daemon, name: &str) -> Option<String> {
    let config: Value =
        serde_json::from_str(&std::fs::read_to_string(d.home.join("config.json")).ok()?).ok()?;
    config["peers"][name]["url"].as_str().map(str::to_owned)
}

#[test]
fn host_add_with_no_url_adds_the_canonical_endpoint() {
    let d = start("add");
    let out = cli(&d, &["host", "add", "box.invalid"]);
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("was saved and is probing in the background"),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(String::from_utf8_lossy(&out.stderr).contains("ssh -o BatchMode=yes box.invalid true"));
    assert_eq!(saved_url(&d, "box.invalid").as_deref(), Some("ssh://box.invalid"));
}

#[test]
fn offline_host_add_exits_zero_with_a_warning() {
    let d = start("warning");
    let out = cli(&d, &["--json", "host", "add", "box.invalid"]);
    let value: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert!(out.stderr.is_empty(), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(value["warning"]["reason"], "peer_probing");
    assert_eq!(value["warning"]["try"], "ssh -o BatchMode=yes box.invalid true");
    assert_eq!(value["warning"]["detail"], "the peer was saved and is probing in the background");
    assert_eq!(saved_url(&d, "box.invalid").as_deref(), Some("ssh://box.invalid"));
}

#[test]
fn blackholed_host_add_returns_without_waiting_for_ssh() {
    let d = start("blackhole");
    let started = Instant::now();
    let out =
        cli_bounded(&d, &["host", "add", "blackhole", "ssh://192.0.2.10"], Duration::from_secs(1));
    let elapsed = started.elapsed();
    eprintln!("blackholed host add elapsed: {elapsed:?}");
    assert!(elapsed < Duration::from_secs(1), "host add took {elapsed:?}");
    assert!(String::from_utf8_lossy(&out.stderr).contains("probing in the background"));
    assert_eq!(saved_url(&d, "blackhole").as_deref(), Some("ssh://192.0.2.10"));
}

#[test]
fn host_ls_names_an_entry_that_is_not_the_canonical_endpoint() {
    let d = start("ls");
    cli(&d, &["host", "add", "plain.invalid", "ssh://plain.invalid"]);
    cli(&d, &["host", "add", "user.invalid", "ssh://leo@user.invalid"]);
    cli(&d, &["host", "add", "port.invalid", "ssh://port.invalid:47822"]);
    let listed = String::from_utf8(cli(&d, &["host", "ls"]).stdout).unwrap();
    let line = |name: &str| {
        listed
            .lines()
            .find(|l| l.starts_with(name))
            .unwrap_or_else(|| panic!("{name} is not listed: {listed}"))
            .to_owned()
    };
    assert!(!line("plain.invalid").contains("canonical"), "{listed}");
    assert!(
        line("user.invalid").contains("not the canonical endpoint ssh://user.invalid"),
        "{listed}"
    );
    assert!(
        line("port.invalid").contains("not the canonical endpoint ssh://port.invalid"),
        "{listed}"
    );
    // The JSON listing says the same, for the app's Machines view and `doctor`.
    let v: Value = serde_json::from_slice(&cli(&d, &["host", "ls", "--json"]).stdout).unwrap();
    let canonical = |name: &str| {
        v["peers"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["name"] == json!(name))
            .map(|p| p["canonicalEndpoint"].clone())
    };
    assert_eq!(canonical("plain.invalid"), Some(Value::Null));
    assert_eq!(canonical("user.invalid"), Some(json!("ssh://user.invalid")));
    assert_eq!(canonical("port.invalid"), Some(json!("ssh://port.invalid")));
}
