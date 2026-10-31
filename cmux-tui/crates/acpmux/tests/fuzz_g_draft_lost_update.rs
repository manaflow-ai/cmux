//! Fuzz row g finding g2: an acknowledged `_acpmux/draft_set` is lost after `kill -9` of the
//! daemon, because another save of the same chat's metadata wrote an older copy over it.
//!
//! The schema calls `_acpmux/draft_set` "the one durable shared draft" (`_acpmux/composer_set`
//! note). `Hub::set_composer_draft` (`hub/mod.rs`) sets the draft under the meta lock and calls
//! `Hub::save_meta`, which takes a copy of the meta (`session.meta()`), lets the lock go, and
//! writes the copy to `session.json` (`LocalStore::save`, `write_atomic`). Nothing orders two
//! saves of one chat: `LocalStore::writable` is a shared read lock. So a save that took its copy
//! before the draft changed (here `_acpmux/rename`; in the fuzz, any save of the chat) can write
//! after the draft's own save, and `session.json` keeps the older draft. The draft lives only in
//! `session.json`, so a restart after `kill -9` reads the older draft back, although the newer
//! one was acknowledged. The fuzz saw it twice with seed 26369 (job 74fc575c39c118270101ec7a).
//!
//! The test: one client sets a chat's draft again and again while four clients rename the same
//! chat. When the draft writer stops and the renames end, `session.json` must hold the last
//! acknowledged draft; when it does not, the test kills its own daemon with SIGKILL, starts it
//! again on the same home and asks `_acpmux/draft_get`, which must give that draft.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// Stand-in agents (tests/fake_agent.py).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// Rounds (one new chat each) and drafts set per round.
const ROUNDS: usize = 40;
const DRAFTS: usize = 60;
/// Clients that rename the chat at the same time.
const RENAMERS: usize = 4;

struct Daemon {
    home: PathBuf,
    socket: PathBuf,
    child: Option<Child>,
}

impl Daemon {
    fn new(tag: &str) -> Self {
        use std::os::unix::fs::PermissionsExt;
        // Short, under /tmp: the socket path must stay under the macOS limit.
        let home = PathBuf::from("/tmp").join(format!("amx-g2-{tag}-{}", std::process::id()));
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
        let mut daemon = Self { home, socket, child: None };
        daemon.start();
        daemon
    }

    fn start(&mut self) {
        let child = daemon_env::command(&self.home, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", &self.home)
            .env("ACPMUX_SOCKET", &self.socket)
            // No agent hosts: a host outlives its daemon.
            .env("ACPMUX_AGENT_HOSTS", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .current_dir(self.home.join("p"))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        self.child = Some(child);
        let deadline = Instant::now() + Duration::from_secs(30);
        while UnixStream::connect(&self.socket).is_err() {
            assert!(Instant::now() < deadline, "the daemon did not listen");
            std::thread::sleep(Duration::from_millis(25));
        }
    }

    /// SIGKILL of the daemon child this test started.
    fn kill9(&mut self) {
        if let Some(mut child) = self.child.take() {
            // SAFETY: the unreaped daemon child this test started.
            unsafe { libc::kill(child.id() as i32, libc::SIGKILL) };
            let _ = child.wait();
        }
    }

    /// The draft `session.json` holds for chat `id` now.
    fn draft_on_disk(&self, id: &str) -> Option<String> {
        let path = self.home.join("sessions").join(id).join("session.json");
        let meta: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        meta["composerDraft"].as_str().map(str::to_owned)
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        self.kill9();
        let _ = std::fs::remove_dir_all(&self.home);
    }
}

struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next: u64,
}

impl Client {
    fn connect(socket: &Path) -> Self {
        let stream = UnixStream::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(30))).unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        let mut c = Self { reader, writer: stream, next: 0 };
        c.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "fuzz-g2"}}));
        c
    }

    fn call(&mut self, method: &str, params: Value) -> Value {
        self.next += 1;
        let id = self.next;
        let line = json!({"jsonrpc": "2.0", "id": id, "method": method, "params": params});
        self.writer.write_all(format!("{line}\n").as_bytes()).unwrap();
        loop {
            let mut text = String::new();
            assert!(self.reader.read_line(&mut text).unwrap() > 0, "the daemon closed the socket");
            let v: Value = serde_json::from_str(&text).unwrap();
            if v.get("method").is_none() && v["id"] == id {
                assert!(v.get("error").is_none(), "{method}: {v}");
                return v["result"].clone();
            }
        }
    }
}

#[test]
fn fuzz_g2_an_acknowledged_draft_survives_a_concurrent_save_and_kill_9() {
    let mut daemon = Daemon::new("lu");
    let mut lost = Vec::new();
    let mut stale_on_disk = 0;
    for round in 0..ROUNDS {
        let mut writer = Client::connect(&daemon.socket);
        let made =
            writer.call("session/new", json!({"cwd": daemon.home.join("p"), "mcpServers": []}));
        let id = made["sessionId"].as_str().unwrap().to_owned();
        let stop = Arc::new(AtomicBool::new(false));
        let renamers: Vec<_> = (0..RENAMERS)
            .map(|r| {
                let (socket, id, stop) = (daemon.socket.clone(), id.clone(), stop.clone());
                std::thread::spawn(move || {
                    let mut client = Client::connect(&socket);
                    let mut n = 0u64;
                    while !stop.load(Ordering::SeqCst) {
                        n += 1;
                        let name = format!("g2-{round}-{r}-{n}");
                        client.call("_acpmux/rename", json!({"sessionId": id, "newName": name}));
                    }
                })
            })
            .collect();
        let mut last = String::new();
        for d in 0..DRAFTS {
            last = format!("draft {round}-{d}");
            let acked = writer.call("_acpmux/draft_set", json!({"sessionId": id, "text": last}));
            assert_eq!(acked["draft"], last.as_str(), "draft_set answered another draft");
        }
        // Every draft is acknowledged; the renames end (each answers after its own save).
        stop.store(true, Ordering::SeqCst);
        for r in renamers {
            r.join().unwrap();
        }
        let on_disk = daemon.draft_on_disk(&id);
        if on_disk.as_deref() == Some(last.as_str()) {
            continue;
        }
        stale_on_disk += 1;
        // The file holds an older draft: a crash now loses the acknowledged one.
        daemon.kill9();
        daemon.start();
        let mut reader = Client::connect(&daemon.socket);
        let after = reader.call("_acpmux/draft_get", json!({"sessionId": id}));
        if after["draft"] != last.as_str() {
            lost.push(format!(
                "round {round}: last acknowledged draft {last:?}, session.json held {on_disk:?}, after kill -9 and restart draft_get gives {}",
                after["draft"]
            ));
        }
    }
    println!("FUZZ-G2 rounds={ROUNDS} stale_on_disk={stale_on_disk} lost={}", lost.len());
    assert!(
        lost.is_empty(),
        "{} of {ROUNDS} acknowledged drafts were lost after kill -9:\n{}",
        lost.len(),
        lost.join("\n")
    );
}
