//! A deleted chat leaves nothing of its own on disk, through a real daemon under load: 200 chats
//! made and deleted from 8 connections at once, some deleted the moment they exist, some mid-turn,
//! some after a turn that sent an image, a PDF and a dropped file. After them no file in the
//! daemon's home, the sessions' temporary folders or the project folder names or holds a deleted
//! chat's id, and only a constant few paths are new since one chat of each kind was made and
//! deleted (the prompt images' shared folder is counted apart, see `IMAGES`).
//!
//! Before the fix, a chat deleted mid-turn could get a new agent from its own prompt after the
//! delete took the old one: that agent's host kept running, with its record, lock, socket,
//! temporary folder and caller token (29 of 50 such chats on cmux-ci); and every PDF sent to a
//! deleted chat stayed in its project's `.cmux/attachments`.
//!
//! Leo asked us to "follow along with these things to fix/improve": a desktop agent app's deleted
//! sessions left transcripts, command output and temp files behind, also when deleted right after
//! they opened, until they filled the disk.
#![cfg(unix)]

use crate::daemon_env;

use base64::Engine;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
const CHATS: usize = 200;
const CONNECTIONS: usize = 8;

struct Daemon {
    child: Option<Child>,
    /// The scratch folder: the daemon's home, its sessions' temporary folders (`session-tmp`),
    /// the agents' HOME (`home`) and the chats' project folder (`p`).
    root: PathBuf,
    socket: PathBuf,
}

impl Daemon {
    fn start() -> Self {
        // Short: host sockets sit next to their records only under the `sun_path` limit.
        let root = std::env::temp_dir().join(format!("sdd-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("p")).unwrap();
        std::fs::write(
            root.join("config.json"),
            json!({
                "harnesses": {"fake": {"argv": ["python3", FAKE], "family": "codex"}},
                "defaultHarness": "fake",
                "permissionPolicy": "approve-all",
                "titles": {"generate": false},
            })
            .to_string(),
        )
        .unwrap();
        let socket = root.join("s.sock");
        let mut child = daemon_env::command(&root, daemon_env::Agents::StandIn, &[])
            .args(["daemon", "run", "--listen", "127.0.0.1:0", "--ready-fd", "1", "--log", "warn"])
            .env("ACPMUX_HOME", &root)
            .env("ACPMUX_SOCKET", &socket)
            .env("CMUX_NEXT_CONFIG_FILE", root.join("cmux-next.json"))
            .env("ACPMUX_CATALOG_FETCH", "0")
            .env("ACPMUX_LOGIN_ENV", "0")
            .env("ACPMUX_SPARE_HARNESS", "0")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("start daemon");
        daemon_env::ready_line(child.stdout.take().unwrap());
        Self { child: Some(child), root, socket }
    }

    async fn rpc(&self) -> Rpc {
        let s = tokio::net::UnixStream::connect(&self.socket).await.expect("connect");
        let (rd, wr) = s.into_split();
        Rpc { lines: tokio::io::BufReader::new(rd).lines(), wr, next: 0 }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        // End every agent host this test's daemon started.
        let hosts = self.root.join("hosts");
        for entry in std::fs::read_dir(&hosts).into_iter().flatten().flatten() {
            let Ok(bytes) = std::fs::read(entry.path()) else { continue };
            let Ok(record) = serde_json::from_slice::<Value>(&bytes) else { continue };
            let pids = [record["harness_pid"].as_i64(), record["host_pid"].as_i64()];
            for pid in pids.into_iter().flatten() {
                // SAFETY: process groups this test's daemon created.
                unsafe { libc::killpg(pid as i32, libc::SIGKILL) };
            }
        }
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

struct Rpc {
    lines: tokio::io::Lines<tokio::io::BufReader<tokio::net::unix::OwnedReadHalf>>,
    wr: tokio::net::unix::OwnedWriteHalf,
    next: i64,
}

impl Rpc {
    async fn send(&mut self, method: &str, params: Value) -> i64 {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.wr.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        self.next
    }

    async fn answer(&mut self, id: i64) -> Value {
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.lines.next_line())
                .await
                .expect("daemon answered in time")
                .unwrap()
                .expect("daemon closed the socket");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
        let v = self.answer(id).await;
        assert!(v.get("error").is_none(), "{method} failed: {v}");
        v["result"].clone()
    }

    async fn new_chat(&mut self, cwd: &Path, name: &str) -> String {
        let made = self
            .call(
                "session/new",
                json!({"cwd": cwd, "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
            )
            .await;
        made["sessionId"].as_str().unwrap_or_else(|| panic!("{made}")).to_owned()
    }

    async fn delete(&mut self, id: &str) {
        self.call("_acpmux/kill", json!({"sessionId": id, "purge": true})).await;
    }
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// Bytes unique to chat `n` that read as a PNG (`prompt_images::sniffed_type`).
fn png(n: usize) -> Vec<u8> {
    let mut bytes = b"\x89PNG\r\n\x1a\n".to_vec();
    bytes.extend_from_slice(format!("chat {n}").as_bytes());
    bytes
}

/// One chat's life, by `n`: deleted at once, mid-turn, after a plain turn, or after a turn that
/// sent an image, a PDF and a dropped file.
async fn one_chat(rpc: &mut Rpc, cwd: &Path, n: usize) -> String {
    let id = rpc.new_chat(cwd, &format!("disk-{n}")).await;
    match n % 4 {
        0 => {}
        1 => {
            // Deleted while its turn runs (the fake waits for the cancel).
            rpc.send(
                "session/prompt",
                json!({"sessionId": id, "prompt": [{"type": "text", "text": "until-cancel"}]}),
            )
            .await;
        }
        2 => {
            rpc.call(
                "session/prompt",
                json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("hi {n}")}]}),
            )
            .await;
        }
        _ => {
            let put = rpc
                .call(
                    "_acpmux/file_put",
                    json!({"sessionId": id, "fileName": "notes.txt", "data": b64(format!("notes {n}").as_bytes())}),
                )
                .await;
            assert!(put["path"].is_string(), "{put}");
            let pdf = format!("%PDF-1.4 chat {n}");
            rpc.call(
                "session/prompt",
                json!({"sessionId": id, "prompt": [
                    {"type": "text", "text": format!("look {n}")},
                    {"type": "image", "mimeType": "image/png", "data": b64(&png(n)), "name": "shot.png"},
                    {"type": "document", "mimeType": "application/pdf", "data": b64(pdf.as_bytes()), "name": "doc.pdf"},
                ]}),
            )
            .await;
        }
    }
    rpc.delete(&id).await;
    id
}

/// Every file and folder under `root` with its size (0 for a folder), by its path below `root`.
fn tree(root: &Path) -> BTreeMap<PathBuf, u64> {
    fn walk(root: &Path, dir: &Path, out: &mut BTreeMap<PathBuf, u64>) {
        for entry in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            let path = entry.path();
            let Ok(kind) = entry.file_type() else { continue };
            let rel = path.strip_prefix(root).unwrap().to_owned();
            if kind.is_dir() {
                out.insert(rel, 0);
                walk(root, &path, out);
            } else {
                out.insert(rel, entry.metadata().map_or(0, |m| m.len()));
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(root, root, &mut out);
    out
}

/// What chat `n`'s life was (`one_chat`).
fn life(n: usize) -> &'static str {
    ["deleted at once", "deleted mid-turn", "deleted after a turn", "deleted after files"][n % 4]
}

/// Whether process `pid` still runs.
fn alive(pid: i64) -> bool {
    // SAFETY: signal 0 only checks existence.
    pid > 0 && unsafe { libc::kill(pid as i32, 0) == 0 }
}

/// What deleted chats left under `root`: `per_chat`, each path that names or holds one of them
/// (`ids`, each with its `n`); `shared`, each path that is not in `baseline` and names none.
#[derive(Default)]
struct Left {
    per_chat: Vec<String>,
    shared: Vec<String>,
}

/// The folder the daemon keeps every prompt's images in, by their hash, however many chats name
/// them (`hub/prompt_images.rs`). A deleted chat's images stay there; collecting the ones no chat
/// names is its own change (they are shared by forks and copies), so they are counted apart.
const IMAGES: &str = "attachments/";

fn leftovers(root: &Path, baseline: &BTreeMap<PathBuf, u64>, ids: &[(String, usize)]) -> Left {
    let mut left = Left::default();
    for (rel, size) in tree(root) {
        let shown = rel.to_string_lossy();
        // The daemon's own log names sessions it served; its rotation bounds it.
        if shown.ends_with(".log") || shown.contains(".log.") || shown.starts_with("logs") {
            continue;
        }
        if let Some((id, n)) = ids.iter().find(|(id, _)| shown.contains(id.as_str())) {
            let mut note = String::new();
            if shown.ends_with(".json")
                && let Ok(bytes) = std::fs::read(root.join(&rel))
                && let Ok(record) = serde_json::from_slice::<Value>(&bytes)
                && let Some(pid) = record["host_pid"].as_i64()
            {
                note = format!(", host {pid} alive: {}", alive(pid));
            }
            left.per_chat.push(format!("{shown} (names chat {id}, {}{note})", life(*n)));
            continue;
        }
        // A file that keeps a deleted chat's id: an index row or a copy of its log. The store's
        // write-ahead journal keeps every line until its next checkpoint retires the segment
        // (every 30 s while it grew, or past 64 MiB: `store/journal_store.rs`), a deleted chat's
        // too, so it is bounded and not the chat's.
        if size > 0
            && !shown.starts_with("journal/")
            && let Ok(bytes) = std::fs::read(root.join(&rel))
        {
            let text = String::from_utf8_lossy(&bytes);
            if let Some((id, n)) = ids.iter().find(|(id, _)| text.contains(id.as_str())) {
                left.per_chat.push(format!("{shown} (holds chat {id}, {})", life(*n)));
                continue;
            }
        }
        if !baseline.contains_key(&rel) && !shown.starts_with(IMAGES) {
            left.shared.push(format!("{shown} ({size} bytes, new since the baseline)"));
        }
    }
    left
}

/// The most paths that may come after the baseline without naming a chat: files and folders the
/// daemon makes once for all its chats, some of them later than the first chats (a store's
/// projection marker, an agent tool folder). They never grow with the number of chats.
const SHARED_MAX: usize = 8;

/// `leftovers`, again until nothing is left or 20 s passed: the last deletes' removals (folders
/// moved aside, hosts ending) finish on their own tasks.
async fn settled(root: &Path, baseline: &BTreeMap<PathBuf, u64>, ids: &[(String, usize)]) -> Left {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let left = leftovers(root, baseline, ids);
        if (left.per_chat.is_empty() && left.shared.len() <= SHARED_MAX)
            || Instant::now() >= deadline
        {
            return left;
        }
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

/// How many of `paths` fall under each top folder, by the life of their chat.
fn summary(paths: &[String]) -> BTreeMap<String, usize> {
    let mut out = BTreeMap::new();
    for l in paths {
        let top = l.split(['/', ' ']).next().unwrap_or_default();
        let how = (0..4).map(life).find(|how| l.contains(how)).unwrap_or("no chat named");
        *out.entry(format!("{top}: {how}")).or_default() += 1;
    }
    out
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn deleted_chats_leave_nothing_on_disk_under_load() {
    let daemon = Daemon::start();
    let root = daemon.root.clone();
    let cwd = root.join("p");
    // One chat of every life made and deleted first: the folders and shared files a daemon
    // keeps for all its chats exist from then on.
    let mut rpc = daemon.rpc().await;
    let mut warm = Vec::new();
    for n in CHATS..CHATS + 4 {
        warm.push((one_chat(&mut rpc, &cwd, n).await, n));
    }
    // Only what names a warm-up chat counts here: the baseline is taken after.
    let mut per_chat = settled(&root, &BTreeMap::new(), &warm).await.per_chat;
    let baseline = tree(&root);
    let images_before = baseline.keys().filter(|p| p.starts_with("attachments")).count();
    let started = Instant::now();
    let mut workers = Vec::new();
    for w in 0..CONNECTIONS {
        let mut rpc = daemon.rpc().await;
        let cwd = cwd.clone();
        workers.push(tokio::spawn(async move {
            let mut ids = Vec::new();
            for n in (w..CHATS).step_by(CONNECTIONS) {
                ids.push((one_chat(&mut rpc, &cwd, n).await, n));
            }
            ids
        }));
    }
    let mut ids = warm.clone();
    for worker in workers {
        ids.extend(worker.await.unwrap());
    }
    let elapsed = started.elapsed();
    let left = settled(&root, &baseline, &ids).await;
    per_chat.extend(left.per_chat);
    let after = tree(&root);
    let images_after = after.keys().filter(|p| p.starts_with("attachments")).count();
    println!(
        "session-delete-disk: {}",
        json!({"chats": CHATS, "secs": elapsed.as_secs_f64(),
               "bytes_before": baseline.values().sum::<u64>(), "bytes_after": after.values().sum::<u64>(),
               "per_chat": per_chat.len(), "by_folder": summary(&per_chat),
               "shared_new": left.shared, "images_before": images_before, "images_after": images_after})
    );
    assert!(
        per_chat.is_empty(),
        "{} paths left by deleted chats ({:?}):\n{}",
        per_chat.len(),
        summary(&per_chat),
        per_chat.join("\n")
    );
    assert!(
        left.shared.len() <= SHARED_MAX,
        "{} new paths after {CHATS} deleted chats:\n{}",
        left.shared.len(),
        left.shared.join("\n")
    );
}
