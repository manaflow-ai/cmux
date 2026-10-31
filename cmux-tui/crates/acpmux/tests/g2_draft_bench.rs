//! Scratch bench for fuzz row g finding g2 (not for the PR): `_acpmux/draft_set` latency on one
//! chat, alone and while four clients rename the same chat (their saves compete with the draft's).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

struct Daemon {
    home: PathBuf,
    socket: PathBuf,
    child: Child,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        // SAFETY: the unreaped daemon child this test started.
        unsafe { libc::kill(self.child.id() as i32, libc::SIGKILL) };
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

fn start() -> Daemon {
    use std::os::unix::fs::PermissionsExt;
    let home = PathBuf::from("/tmp").join(format!("amx-g2b-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(home.join("p")).unwrap();
    std::fs::set_permissions(&home, std::fs::Permissions::from_mode(0o700)).unwrap();
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let config = json!({"harnesses": {"fake": {"argv": ["python3", fake]}},
                        "defaultHarness": "fake", "permissionPolicy": "approve-all",
                        "agentInbox": false, "autoResumeDelaysMs": []});
    std::fs::write(home.join("config.json"), config.to_string()).unwrap();
    std::fs::set_permissions(home.join("config.json"), std::fs::Permissions::from_mode(0o600))
        .unwrap();
    let socket = home.join("s.sock");
    let child = daemon_env::command(&home, daemon_env::Agents::StandIn, &[])
        .args(["daemon", "run", "--log", "warn"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", &socket)
        .env("ACPMUX_AGENT_HOSTS", "0")
        .env("ACPMUX_LOGIN_ENV", "0")
        .current_dir(home.join("p"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(30);
    while UnixStream::connect(&socket).is_err() {
        assert!(Instant::now() < deadline, "the daemon did not listen");
        std::thread::sleep(Duration::from_millis(25));
    }
    Daemon { home, socket, child }
}

struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Client {
    fn connect(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        let mut c = Self { reader, writer: stream, next: 0 };
        c.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "g2b"}}));
        c
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        loop {
            let mut text = String::new();
            assert!(self.reader.read_line(&mut text).unwrap() > 0);
            let v: Value = serde_json::from_str(&text).unwrap();
            if v.get("method").is_none() && v["id"] == id {
                assert!(v.get("error").is_none(), "{method}: {v}");
                return v["result"].clone();
            }
        }
    }
}

fn pct(sorted: &[f64], p: f64) -> f64 {
    sorted[(((sorted.len() - 1) as f64) * p).round() as usize]
}

fn measure(client: &mut Client, id: &str, n: usize, tag: &str) -> Vec<f64> {
    let mut out = Vec::with_capacity(n);
    for i in 0..n {
        let began = Instant::now();
        client.call("_acpmux/draft_set", json!({"sessionId": id, "text": format!("{tag} {i}")}));
        out.push(began.elapsed().as_secs_f64() * 1000.0);
    }
    out.sort_by(|a, b| a.partial_cmp(b).unwrap());
    out
}

#[test]
fn g2_bench_draft_set_latency() {
    let _ = HERMETIC;
    let daemon = start();
    let mut client = Client::connect(&daemon.socket);
    let made = client.call("session/new", json!({"cwd": daemon.home.join("p"), "mcpServers": []}));
    let id = made["sessionId"].as_str().unwrap().to_owned();
    measure(&mut client, &id, 50, "warm");
    let alone = measure(&mut client, &id, 500, "alone");
    let stop = Arc::new(AtomicBool::new(false));
    let renamers: Vec<_> = (0..4)
        .map(|r| {
            let (socket, id, stop) = (daemon.socket.clone(), id.clone(), stop.clone());
            std::thread::spawn(move || {
                let mut c = Client::connect(&socket);
                let mut n = 0u64;
                while !stop.load(Ordering::SeqCst) {
                    n += 1;
                    c.call(
                        "_acpmux/rename",
                        json!({"sessionId": id, "newName": format!("b-{r}-{n}")}),
                    );
                }
                n
            })
        })
        .collect();
    let contended = measure(&mut client, &id, 500, "contended");
    stop.store(true, Ordering::SeqCst);
    let renames: u64 = renamers.into_iter().map(|t| t.join().unwrap()).sum();
    for (name, v) in [("alone", &alone), ("with_4_renamers", &contended)] {
        println!(
            "G2-BENCH draft_set {name} n={} p50_ms={:.2} p99_ms={:.2} max_ms={:.2}",
            v.len(),
            pct(v, 0.5),
            pct(v, 0.99),
            v[v.len() - 1]
        );
    }
    println!("G2-BENCH renames_during_contended={renames}");
}
