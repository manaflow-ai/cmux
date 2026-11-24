//! Crash test of the shared remote browser host (cmuxterm-hq
//! docs/design/process-sharing.md, "Remote and phone browser tabs"): one host
//! process serves every remote tab, and SIGKILLing it loses no tab.
//!
//! This runs the real `--supervise` binary over a stand-in host (a short
//! Python script that speaks the CEF host's stdin and stdout lines and reports
//! the listener it inherited), so it runs on Linux. The same check against the
//! real CEF host, with cookies, is scripts/cmux-next/rb-shared-host-crash.py
//! on a fleet Mac.

use std::io::{BufRead, BufReader, Write};
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

const FAKE_HOST: &str = r##"
import json, os, socket, sys
log = os.environ["FAKE_HOST_LOG"]
lsock = socket.socket(fileno=3)
port = lsock.getsockname()[1]
lsock.detach()
def say(v):
    print(json.dumps(v), flush=True)
for line in sys.stdin:
    v = json.loads(line)
    with open(log, "a") as f:
        f.write(json.dumps({"pid": os.getpid(), "port": port, "line": v}) + "\n")
    if "open" in v:
        o = v["open"]
        if not o["url"].endswith("#moved"):
            say({"tab": o["tab"], "url": o["url"] + "#moved"})
        say({"tab": o["tab"], "ready": True})
    elif "close" in v:
        say({"tab": v["close"]["tab"], "closed": True})
    elif "serve" in v:
        say({"listening": "127.0.0.1:%d" % port})
"##;

struct Sup {
    child: Child,
    lines: mpsc::Receiver<Value>,
    /// Lines no `next` took yet.
    seen: std::cell::RefCell<Vec<Value>>,
}

impl Sup {
    /// The first line, seen or still to come, that `pred` accepts. Lines it
    /// skips stay for a later call: the supervisor's lines for different
    /// tabs arrive in any order.
    fn next(&self, what: &str, pred: impl Fn(&Value) -> bool) -> Value {
        let mut seen = self.seen.borrow_mut();
        if let Some(i) = seen.iter().position(&pred) {
            return seen.remove(i);
        }
        let until = Instant::now() + Duration::from_secs(20);
        loop {
            let left = until.saturating_duration_since(Instant::now());
            match self.lines.recv_timeout(left) {
                Ok(v) if pred(&v) => return v,
                Ok(v) => seen.push(v),
                Err(_) => panic!("the supervisor never said {what}"),
            }
        }
    }
}

impl Drop for Sup {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(unix)]
#[test]
fn sigkilled_shared_host_comes_back_with_every_tab_on_the_same_port() {
    let dir = std::env::temp_dir().join(format!("rb-supervise-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let script = dir.join("fake_host.py");
    std::fs::write(&script, FAKE_HOST).unwrap();
    let launcher = dir.join("fake_host.sh");
    std::fs::write(&launcher, format!("#!/bin/sh\nexec python3 -I {} \"$@\"\n", script.display()))
        .unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o755)).unwrap();
    let log = dir.join("host.log");
    let root = dir.join("cache");
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-remote-browser-host"))
        .args(["--supervise", "--host"])
        .arg(&launcher)
        .env("CMUX_RB_CACHE_DIR", &root)
        .env("FAKE_HOST_LOG", &log)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .expect("supervisor");
    let out = child.stdout.take().unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let (tx, lines) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(out).lines().map_while(Result::ok) {
            if let Ok(v) = serde_json::from_str::<Value>(&line) {
                let _ = tx.send(v);
            }
        }
    });
    let sup = Sup { child, lines, seen: Default::default() };
    let listening = sup.next("listening", |v| v.get("listening").is_some());
    let port: u16 =
        listening["listening"].as_str().unwrap().rsplit(':').next().unwrap().parse().unwrap();
    for id in ["a", "b", "c"] {
        writeln!(stdin, "{}", json!({"open": {"tab": id, "url": format!("https://{id}.test/")}}))
            .unwrap();
    }
    stdin.flush().unwrap();
    let mut hosts = Vec::new();
    for id in ["a", "b", "c"] {
        let reply = sup.next("a tab's token", |v| v["tab"] == id && v.get("token").is_some());
        assert_eq!(reply["token"].as_str().unwrap().len(), 64);
    }
    let first = read_log(&log);
    for entry in &first {
        hosts.push(entry["pid"].as_u64().unwrap());
    }
    hosts.sort_unstable();
    hosts.dedup();
    assert_eq!(hosts.len(), 1, "two tabs, one host pid: three tabs ran on {hosts:?}");
    let pid = hosts[0];
    // The URLs the pages moved to reach the supervisor.
    for id in ["a", "b", "c"] {
        sup.next("a moved URL", |v| {
            v["tab"] == id && v["url"].as_str().is_some_and(|u| u.ends_with("#moved"))
        });
    }
    // SIGKILL the host by pid.
    let killed = Instant::now();
    assert!(Command::new("kill").args(["-KILL", &pid.to_string()]).status().unwrap().success());
    let next = sup.next("the next host", |v| {
        v.get("host").is_some() && v["host"]["pid"].as_u64() != Some(pid)
    });
    let new_pid = next["host"]["pid"].as_u64().unwrap();
    // Every tab is open in the new host, at its last URL, on the same port.
    for id in ["a", "b", "c"] {
        let again = sup.next("a tab reopened", |v| v["tab"] == id && v.get("reopened").is_some());
        assert!(again["url"].as_str().unwrap().ends_with("#moved"));
    }
    let back = killed.elapsed();
    let reopened: Vec<Value> = read_log(&log)
        .into_iter()
        .filter(|e| e["pid"].as_u64() == Some(new_pid) && e["line"].get("open").is_some())
        .collect();
    assert_eq!(reopened.len(), 3, "tabs lost: {} of 3", 3 - reopened.len().min(3));
    for e in &reopened {
        assert_eq!(e["port"].as_u64(), Some(u64::from(port)), "the listener survives the host");
        assert!(e["line"]["open"]["url"].as_str().unwrap().ends_with("#moved"));
    }
    assert!(back < Duration::from_secs(5), "tabs back in {back:?}");
    eprintln!("tabs lost 0 of 3; back on host {new_pid} in {} ms", back.as_millis());
    drop(stdin);
    drop(sup);
    let _ = std::fs::remove_dir_all(&dir);
}

fn read_log(log: &Path) -> Vec<Value> {
    std::fs::read_to_string(log)
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect()
}
