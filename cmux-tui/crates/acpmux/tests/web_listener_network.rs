//! The daemon binds its plain ws:// listener on a network (non-loopback)
//! address only when the person opts in, with `--insecure-network-listen` or
//! `websocket.allowInsecureNetwork`. Without it, an explicit `--listen` and a
//! configured `websocket.listen` both stop the daemon with an error that
//! names the opt-in: the listener token would cross the network in clear.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Read};
use std::path::PathBuf;
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};

fn home(tag: &str, websocket: Option<Value>) -> PathBuf {
    let home = std::env::temp_dir().join(format!("wln-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let mut config = json!({});
    if let Some(w) = websocket {
        config["websocket"] = w;
    }
    std::fs::write(home.join("config.json"), config.to_string()).unwrap();
    home
}

fn spawn(home: &PathBuf, args: &[&str]) -> Child {
    daemon_env::acpmux(home)
        .args(["daemon", "run", "--ready-fd", "1", "--log", "error"])
        .args(args)
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", home.join("s.sock"))
        .env("ACPMUX_LOGIN_ENV", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap()
}

/// The daemon exits on its own with an error; its stderr. Panics when it is
/// still running after 20 s (it bound the address).
fn refused(home: &PathBuf, args: &[&str]) -> String {
    let mut child = spawn(home, args);
    let deadline = Instant::now() + Duration::from_secs(20);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() > deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("the daemon kept running with {args:?}: it bound a network address");
        }
        std::thread::sleep(Duration::from_millis(50));
    };
    let mut stderr = String::new();
    child.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();
    assert!(!status.success(), "{stderr}");
    stderr
}

/// The daemon starts; its readiness line.
fn started(home: &PathBuf, args: &[&str]) -> Value {
    let mut child = spawn(home, args);
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut ready = String::new();
        let _ = BufReader::new(stdout).read_line(&mut ready);
        let _ = tx.send(ready);
    });
    let line = rx.recv_timeout(Duration::from_secs(20));
    let _ = child.kill();
    let _ = child.wait();
    let line = line.unwrap_or_else(|_| panic!("no readiness line with {args:?}"));
    serde_json::from_str(&line).unwrap_or_else(|e| panic!("{e}: {line:?}"))
}

#[test]
fn a_network_listen_without_the_opt_in_stops_the_daemon() {
    // An explicit --listen.
    let h = home("flag", None);
    let err = refused(&h, &["--listen", "0.0.0.0:0"]);
    assert!(err.contains("--insecure-network-listen"), "{err}");
    let _ = std::fs::remove_dir_all(&h);
    // A configured websocket.listen.
    let h = home("config", Some(json!({"listen": "0.0.0.0:0", "token": "t".repeat(32)})));
    let err = refused(&h, &[]);
    assert!(err.contains("websocket.allowInsecureNetwork"), "{err}");
    let _ = std::fs::remove_dir_all(&h);
}

#[test]
fn a_network_listen_with_the_opt_in_is_bound() {
    let h = home("flag-ok", None);
    let ready = started(&h, &["--listen", "0.0.0.0:0", "--insecure-network-listen"]);
    assert!(ready["listen"].as_str().is_some_and(|l| l.starts_with("0.0.0.0:")), "{ready}");
    let _ = std::fs::remove_dir_all(&h);
    let h = home(
        "config-ok",
        Some(json!({"listen": "0.0.0.0:0", "token": "t".repeat(32), "allowInsecureNetwork": true})),
    );
    let ready = started(&h, &[]);
    assert!(ready["listen"].as_str().is_some_and(|l| l.starts_with("0.0.0.0:")), "{ready}");
    let _ = std::fs::remove_dir_all(&h);
}
