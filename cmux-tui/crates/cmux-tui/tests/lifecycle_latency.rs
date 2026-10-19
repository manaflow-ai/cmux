//! Tab, pane and workspace create/close over a real daemon socket in a
//! session that already holds other workspaces (perf-10x lifecycle). Each
//! create shows up in `list-workspaces` and each close removes it again; the
//! send-to-reply time of every command is written to
//! `<repo>/.build/perf-lifecycle/latency.txt` (one LIFECYCLE line per
//! command: p50/p95/max ms), so a fleet step can return it
//! (`cmux-ci run ... --script scripts/ci/cmux-tui-rust-check.sh --arg test
//! --arg lifecycle_latency --artifact .build/perf-lifecycle/latency.txt`).
//! The numbers are a debug daemon's; compare runs of one build profile only.

#![cfg(unix)]

use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

/// Idle one-terminal workspaces made before timing, so a close or create
/// cost that grows with the session shows.
const BACKGROUND: usize = 24;
const ROUNDS: usize = 8;

struct Daemon {
    child: Child,
    dir: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

struct Conn {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Conn {
    fn call(&mut self, request: Value) -> Value {
        let (request, reply) = self.reply(request);
        assert_eq!(reply["ok"], true, "{request} failed: {reply}");
        reply["data"].clone()
    }

    /// The request as sent and the daemon's reply to it, ok or not.
    fn reply(&mut self, request: Value) -> (Value, Value) {
        let id = self.next;
        self.next += 1;
        let mut request = request;
        request["id"] = json!(id);
        writeln!(self.writer, "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert!(self.reader.read_line(&mut line).unwrap() > 0, "daemon closed the socket");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id && reply.get("ok").is_some() {
                return (request, reply);
            }
        }
    }

    fn timed(
        &mut self,
        samples: &mut BTreeMap<&'static str, Vec<f64>>,
        name: &'static str,
        request: Value,
    ) -> Value {
        let started = Instant::now();
        let data = self.call(request);
        samples.entry(name).or_default().push(started.elapsed().as_secs_f64() * 1000.0);
        data
    }

    /// The pane and workspace that show `surface`, or None.
    fn placement(&mut self, surface: &Value) -> Option<(Value, Value)> {
        let tree = self.call(json!({"cmd": "list-workspaces"}));
        for workspace in tree["workspaces"].as_array()? {
            for screen in workspace["screens"].as_array()? {
                for pane in screen["panes"].as_array()? {
                    let shows = pane["tabs"].as_array()?.iter().any(|tab| {
                        tab == surface || tab["id"] == *surface || tab["surface"] == *surface
                    });
                    if shows {
                        return Some((pane["id"].clone(), workspace["id"].clone()));
                    }
                }
            }
        }
        None
    }
}

fn start() -> (Daemon, Conn) {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!("cmux-lc-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s.sock");
    let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--headless", "--socket"])
        .arg(&socket)
        .arg("--state")
        .arg(dir.join("state"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("SHELL", "/bin/sh")
        .env_remove("SSH_CONNECTION")
        .env_remove("SSH_CLIENT")
        .env_remove("SSH_TTY")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let daemon = Daemon { child, dir };
    let deadline = Instant::now() + Duration::from_secs(15);
    let stream = loop {
        if let Ok(stream) = UnixStream::connect(&socket) {
            break stream;
        }
        assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
        std::thread::sleep(Duration::from_millis(25));
    };
    stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
    let writer = stream.try_clone().unwrap();
    (daemon, Conn { reader: BufReader::new(stream), writer, next: 1 })
}

fn report(samples: &BTreeMap<&'static str, Vec<f64>>) -> String {
    let mut out = format!("LIFECYCLE-SESSION background={BACKGROUND} rounds={ROUNDS}\n");
    for (name, values) in samples {
        let mut sorted = values.clone();
        sorted.sort_by(f64::total_cmp);
        let q = |p: f64| sorted[((p * sorted.len() as f64) as usize).min(sorted.len() - 1)];
        out += &format!(
            "LIFECYCLE op=\"{name}\" n={} p50={:.2} p95={:.2} max={:.2}\n",
            sorted.len(),
            q(0.5),
            q(0.95),
            sorted[sorted.len() - 1]
        );
    }
    out
}

#[test]
fn lifecycle_latency_creates_and_closes_in_a_populated_session() {
    let (_daemon, mut conn) = start();
    for k in 0..BACKGROUND {
        conn.call(
            json!({"cmd": "new-workspace", "name": format!("bg{k}"), "cols": 80, "rows": 24}),
        );
    }
    let base = conn.call(json!({"cmd": "new-workspace", "name": "base", "cols": 120, "rows": 40}));
    let (pane, _) =
        conn.placement(&base["surface"]).expect("the base workspace shows its terminal");
    let mut samples = BTreeMap::new();
    for round in 0..ROUNDS {
        let tab = conn.timed(
            &mut samples,
            "new-tab terminal",
            json!({"cmd": "new-tab", "pane": pane, "cols": 80, "rows": 24}),
        );
        assert!(conn.placement(&tab["surface"]).is_some(), "the new tab is placed");
        conn.timed(
            &mut samples,
            "close-surface terminal",
            json!({"cmd": "close-surface", "surface": tab["surface"]}),
        );
        assert!(conn.placement(&tab["surface"]).is_none(), "the closed tab is gone");

        let browser = conn.timed(&mut samples, "new-tab browser",
            json!({"cmd": "new-browser-tab", "url": "about:blank", "pane": pane, "cols": 80, "rows": 24}));
        conn.timed(
            &mut samples,
            "close-surface browser",
            json!({"cmd": "close-surface", "surface": browser["surface"]}),
        );

        for (name, close, dir) in [
            ("split right", "close-pane (split right)", "right"),
            ("split down", "close-pane (split down)", "down"),
        ] {
            let split = conn.timed(
                &mut samples,
                name,
                json!({"cmd": "split", "pane": pane, "dir": dir, "cols": 80, "rows": 24}),
            );
            let (new_pane, _) =
                conn.placement(&split["surface"]).expect("the split pane shows its terminal");
            assert_ne!(new_pane, pane, "a split makes a new pane");
            conn.timed(
                &mut samples,
                close,
                json!({"cmd": "close-pane", "pane": new_pane, "end_terminals": true}),
            );
            assert!(conn.placement(&split["surface"]).is_none(), "the closed pane is gone");
        }

        let created = conn.timed(
            &mut samples,
            "new-workspace",
            json!({"cmd": "new-workspace", "name": format!("w{round}"), "cols": 80, "rows": 24}),
        );
        let (_, workspace) =
            conn.placement(&created["surface"]).expect("the new workspace shows its terminal");
        conn.timed(
            &mut samples,
            "close-workspace",
            json!({"cmd": "close-workspace", "workspace": workspace, "end_terminals": true}),
        );
        assert!(conn.placement(&created["surface"]).is_none(), "the closed workspace is gone");
    }
    // End every terminal this test made: a durable host outlives a killed
    // daemon. The last workspace may refuse to close; its terminal still ends
    // with the daemon's reap below.
    let tree = conn.call(json!({"cmd": "list-workspaces"}));
    for workspace in tree["workspaces"].as_array().into_iter().flatten() {
        conn.reply(
            json!({"cmd": "close-workspace", "workspace": workspace["id"], "end_terminals": true}),
        );
    }
    let text = report(&samples);
    eprint!("{text}");
    let out = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../.build/perf-lifecycle");
    fs::create_dir_all(&out).unwrap();
    fs::write(out.join("latency.txt"), text).unwrap();
}
