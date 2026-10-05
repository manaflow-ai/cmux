//! An `ssh://` peer URL can come from any WebSocket token holder
//! (`_acpmux/peer_add`), and before the token fix the token reached remote
//! clients. No peer URL may become an ssh option: `ssh://-oProxyCommand=...`
//! would make the daemon run a local command. Such a URL is refused when it
//! is added, and a saved one is never used at start (logged by peer name
//! only).
#![cfg(unix)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

struct Daemon {
    child: Option<Child>,
    home: PathBuf,
    /// Everything the daemon wrote to stdout (its log goes there too).
    out: std::sync::Arc<std::sync::Mutex<String>>,
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

fn start(tag: &str, peers: Value) -> Daemon {
    let home = std::env::temp_dir().join(format!("asi-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    std::fs::write(home.join("config.json"), json!({"peers": peers}).to_string()).unwrap();
    let mut child = Command::new(env!("CARGO_BIN_EXE_acpmux"))
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
        .env_remove("ACPMUX_LOGIN_ENV")
        .env_remove("XPC_SERVICE_NAME")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    let stdout = child.stdout.take().unwrap();
    let out = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
    let d = Daemon { child: Some(child), home, out: out.clone() };
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        // Log lines may come before the ready line (JSON); keep them all.
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if line.starts_with('{') {
                let _ = tx.send(line.clone());
            }
            let mut o = out.lock().unwrap();
            o.push_str(&line);
            o.push('\n');
        }
    });
    rx.recv_timeout(Duration::from_secs(20)).expect("daemon ready");
    d
}

fn unix(home: &Path, method: &str, params: Value) -> Value {
    let mut s = std::os::unix::net::UnixStream::connect(home.join("s.sock")).unwrap();
    s.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
    writeln!(s, "{}", json!({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}))
        .unwrap();
    let mut reader = BufReader::new(s);
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let v: Value = serde_json::from_str(&line).unwrap();
        if v.get("id") == Some(&json!(1)) {
            return v;
        }
    }
}

/// `ssh://` URLs that would run `touch MARKER` if ssh took them as options.
fn attacks(marker: &Path) -> Vec<String> {
    let m = marker.display();
    vec![
        format!("ssh://-oProxyCommand=touch {m}"),
        format!("ssh://-oProxyCommand=touch {m}@box"),
        format!("ssh://box@-oProxyCommand=touch {m}"),
        "ssh://-F/dev/null".to_owned(),
        "ssh://bo x".to_owned(),
        "ssh://box\u{7}".to_owned(),
        "ssh://box:22x".to_owned(),
    ]
}

#[test]
fn a_saved_option_shaped_peer_is_never_used_at_start() {
    let marker_dir = std::env::temp_dir().join(format!("asi-mark-{}", std::process::id()));
    std::fs::create_dir_all(&marker_dir).unwrap();
    let marker = marker_dir.join("pwned");
    let _ = std::fs::remove_file(&marker);
    let peers: serde_json::Map<String, Value> = attacks(&marker)
        .into_iter()
        .enumerate()
        .map(|(i, url)| (format!("bad{i}"), json!({"url": url})))
        .collect();
    let d = start("saved", Value::Object(peers));
    // Give a started peer time to spawn ssh (a reconnect loop starts at once).
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline && !marker.exists() {
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(!marker.exists(), "ssh ran a ProxyCommand from a saved peer URL");
    let listed = unix(&d.home, "_acpmux/peers", json!({}));
    assert_eq!(listed["result"]["peers"], json!([]), "refused peers do not run: {listed}");
    let log = d.out.lock().unwrap().clone();
    assert!(log.contains("peer refused"), "the refusal is logged: {log}");
    assert!(!log.contains("ProxyCommand"), "the log never quotes the URL: {log}");
    let _ = std::fs::remove_dir_all(&marker_dir);
}

#[test]
fn peer_add_refuses_an_option_shaped_ssh_url() {
    let marker_dir = std::env::temp_dir().join(format!("asi-add-{}", std::process::id()));
    std::fs::create_dir_all(&marker_dir).unwrap();
    let marker = marker_dir.join("pwned");
    let d = start("add", json!({}));
    for (i, url) in attacks(&marker).into_iter().enumerate() {
        let reply = unix(
            &d.home,
            "_acpmux/peer_add",
            json!({"name": format!("p{i}"), "url": url, "wait": true}),
        );
        assert!(reply.get("error").is_some(), "{url:?} was accepted: {reply}");
    }
    std::thread::sleep(Duration::from_millis(500));
    assert!(!marker.exists(), "ssh ran a ProxyCommand from peer_add");
    let saved = std::fs::read_to_string(d.home.join("config.json")).unwrap();
    assert!(!saved.contains("ProxyCommand"), "a refused URL is not saved");
    let _ = std::fs::remove_dir_all(&marker_dir);
}
