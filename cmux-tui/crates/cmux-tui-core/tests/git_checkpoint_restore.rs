#![cfg(unix)]
//! `git.checkpoint.restore` over a real session socket and the real git: a
//! chat rewound to before a turn gets its files and staged entries back,
//! loses what the turn added (never an ignored file), and Undo (a restore of
//! the safety checkpoint) brings the turn's state back.

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

fn unique(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

/// Runs git in `repo`, apart from the host's git config; its output.
fn git(repo: &Path, arguments: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(["-c", "maintenance.auto=false", "-c", "user.name=t", "-c", "user.email=t@e.test"])
        .args(arguments)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {arguments:?} failed: {output:?}");
    String::from_utf8(output.stdout).unwrap()
}

fn write(repo: &Path, path: &str, contents: &str) {
    let path = repo.join(path);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, contents).unwrap();
}

fn read(repo: &Path, path: &str) -> Option<String> {
    std::fs::read_to_string(repo.join(path)).ok()
}

/// The staged content of `path`, or `None` when it is not in the index.
fn staged(repo: &Path, path: &str) -> Option<String> {
    if git(repo, &["ls-files", "--", path]).trim().is_empty() {
        return None;
    }
    Some(git(repo, &["show", &format!(":{path}")]))
}

struct Daemon {
    stream: BufReader<UnixStream>,
    next: u64,
    mux: Arc<Mux>,
    socket: PathBuf,
    dir: PathBuf,
    repo: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        self.mux.shutdown();
        server::cleanup(&self.socket);
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl Daemon {
    /// A daemon with a state folder, and a repository on `main` with one
    /// commit of `a.txt`, `b.txt`, `c.txt` and a `.gitignore` of `*.log`.
    fn new(name: &str) -> Self {
        let dir = std::env::temp_dir().join(unique(name));
        let repo = dir.join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "--quiet", "--initial-branch=main"]);
        write(&repo, "a.txt", "one\n");
        write(&repo, "b.txt", "keep\n");
        write(&repo, "c.txt", "base\n");
        write(&repo, ".gitignore", "*.log\n");
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "--quiet", "-m", "one"]);
        let mux = Mux::open_persistent(unique(name), SurfaceOptions::default(), &dir.join("state"))
            .unwrap();
        let socket = dir.join("s.sock");
        server::serve(mux.clone(), Some(socket.clone())).unwrap();
        let stream = UnixStream::connect(&socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        Self { stream: BufReader::new(stream), next: 0, mux, socket, dir, repo }
    }

    fn request(&mut self, operation: &str, key: Option<&str>, mut params: Value) -> Value {
        self.next += 1;
        let id = format!("r{}", self.next);
        params["machine"] = json!("current");
        params["session"] = json!("current");
        params["path"] = json!(self.repo);
        let mut request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        if let Some(key) = key {
            request["idempotency_key"] = json!(key);
        }
        writeln!(self.stream.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.stream.read_line(&mut line).unwrap(), 0, "closed before {id}");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id {
                return reply;
            }
        }
    }

    /// A mutation's result (`{value, revision, replayed, ...}`).
    fn mutate(&mut self, operation: &str, key: &str, params: Value) -> Value {
        let reply = self.request(operation, Some(key), params);
        assert_eq!(reply["ok"], true, "{operation} failed: {reply}");
        reply["result"].clone()
    }

    /// A checkpoint of every eligible file, as a turn takes it.
    fn checkpoint(&mut self) -> String {
        let params = json!({"include_untracked": "eligible", "reason": "turn"});
        let created = self.mutate("git.checkpoint.create", &unique("create"), params);
        created["value"]["checkpoint_id"].as_str().unwrap().to_string()
    }

    fn restore(&mut self, key: &str, params: Value) -> Value {
        self.mutate("git.checkpoint.restore", key, params)
    }
}

/// The paths and changes a restore lists.
fn changes(value: &Value) -> Vec<(String, String)> {
    value["files"]
        .as_array()
        .unwrap()
        .iter()
        .map(|file| {
            (file["path"].as_str().unwrap().into(), file["change"].as_str().unwrap().into())
        })
        .collect()
}

fn pair(path: &str, change: &str) -> (String, String) {
    (path.into(), change.into())
}

/// The state before a turn: a staged and a further unstaged change to
/// `c.txt`, and an untracked `notes.md`.
fn before_the_turn(repo: &Path) {
    write(repo, "c.txt", "staged\n");
    git(repo, &["add", "c.txt"]);
    write(repo, "c.txt", "unstaged\n");
    write(repo, "notes.md", "notes\n");
}

/// What a turn does: edits, deletes, adds, stages and makes an ignored file.
fn the_turn(repo: &Path) {
    write(repo, "a.txt", "agent\n");
    std::fs::remove_file(repo.join("b.txt")).unwrap();
    write(repo, "new.txt", "new\n");
    write(repo, "dir/tracked.txt", "tracked\n");
    git(repo, &["add", "dir/tracked.txt"]);
    write(repo, "c.txt", "agent staged\n");
    git(repo, &["add", "c.txt"]);
    std::fs::remove_file(repo.join("notes.md")).unwrap();
    write(repo, "build.log", "log\n");
}

#[test]
fn checkpoint_restore_rewinds_a_turn_and_its_safety_checkpoint_undoes_it() {
    let mut daemon = Daemon::new("ckpt-restore");
    let repo = daemon.repo.clone();
    before_the_turn(&repo);
    let before = daemon.checkpoint();
    the_turn(&repo);
    let after_the_turn = git(&repo, &["status", "--porcelain=v1", "--untracked-files=all"]);

    // A dry run lists every change and writes nothing.
    let dry = daemon.restore(&unique("dry"), json!({"checkpoint_id": before, "dry_run": true}));
    let value = &dry["value"];
    assert_eq!(value["dry_run"], true, "{dry}");
    assert_eq!(value["base_changed"], false, "{dry}");
    assert_eq!(value["complete"], true, "{dry}");
    assert!(value.get("safety_checkpoint_id").is_none(), "{dry}");
    let expected = vec![
        pair("a.txt", "restore"),
        pair("b.txt", "restore"),
        pair("c.txt", "restore"),
        pair("dir/tracked.txt", "remove"),
        pair("new.txt", "remove"),
        pair("notes.md", "restore"),
    ];
    assert_eq!(changes(value), expected, "{dry}");
    assert_eq!(value["files_total"], 6, "{dry}");
    assert_eq!(git(&repo, &["status", "--porcelain=v1", "--untracked-files=all"]), after_the_turn);
    assert_eq!(read(&repo, "a.txt").as_deref(), Some("agent\n"));

    // Apply: the files and the staged entry come back, what the turn added
    // goes, and the ignored file stays.
    let key = unique("apply");
    let applied = daemon.restore(&key, json!({"checkpoint_id": before}));
    let value = applied["value"].clone();
    assert_eq!(applied["replayed"], false, "{applied}");
    assert_eq!(changes(&value), expected, "{applied}");
    let safety = value["safety_checkpoint_id"].as_str().unwrap().to_string();
    assert_eq!(read(&repo, "a.txt").as_deref(), Some("one\n"));
    assert_eq!(read(&repo, "b.txt").as_deref(), Some("keep\n"));
    assert_eq!(read(&repo, "c.txt").as_deref(), Some("unstaged\n"));
    assert_eq!(staged(&repo, "c.txt").as_deref(), Some("staged\n"));
    assert_eq!(read(&repo, "notes.md").as_deref(), Some("notes\n"));
    assert_eq!(read(&repo, "new.txt"), None);
    assert_eq!(read(&repo, "dir/tracked.txt"), None);
    assert_eq!(staged(&repo, "dir/tracked.txt"), None);
    assert!(!repo.join("dir").exists(), "an emptied folder goes too");
    assert_eq!(read(&repo, "build.log").as_deref(), Some("log\n"), "ignored files stay");
    assert!(!repo.join(".git/index.lock").exists());
    // The safety checkpoint is pinned by the restore owner.
    let record = daemon.request("git.checkpoint.get", None, json!({"checkpoint_id": safety}));
    let pins = &record["result"]["pins"];
    assert_eq!(pins[0]["pin_id"], format!("restore:{before}:{key}"), "{record}");

    // A replay returns the first reply and never writes again.
    write(&repo, "a.txt", "edited after the restore\n");
    let replayed = daemon.restore(&key, json!({"checkpoint_id": before}));
    assert_eq!(replayed["replayed"], true, "{replayed}");
    assert_eq!(replayed["value"], value);
    assert_eq!(read(&repo, "a.txt").as_deref(), Some("edited after the restore\n"));
    write(&repo, "a.txt", "one\n");

    // Undo: the safety checkpoint brings the turn's state back.
    let undone = daemon.restore(&unique("undo"), json!({"checkpoint_id": safety}));
    assert!(undone["value"]["safety_checkpoint_id"].is_string(), "{undone}");
    assert_eq!(read(&repo, "a.txt").as_deref(), Some("agent\n"));
    assert_eq!(read(&repo, "b.txt"), None);
    assert_eq!(read(&repo, "new.txt").as_deref(), Some("new\n"));
    assert_eq!(read(&repo, "notes.md"), None);
    assert_eq!(staged(&repo, "c.txt").as_deref(), Some("agent staged\n"));
    assert_eq!(staged(&repo, "dir/tracked.txt").as_deref(), Some("tracked\n"));
    assert_eq!(read(&repo, "build.log").as_deref(), Some("log\n"));
    assert_eq!(git(&repo, &["status", "--porcelain=v1", "--untracked-files=all"]), after_the_turn);
}

#[test]
fn checkpoint_restore_refuses_a_moved_head_unless_allowed() {
    let mut daemon = Daemon::new("ckpt-restore-base");
    let repo = daemon.repo.clone();
    let before = daemon.checkpoint();
    write(&repo, "a.txt", "committed\n");
    git(&repo, &["commit", "--quiet", "-am", "two"]);
    write(&repo, "a.txt", "agent\n");

    let refused = daemon.request(
        "git.checkpoint.restore",
        Some(&unique("base")),
        json!({"checkpoint_id": before}),
    );
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error"]["code"], "operation.failed", "{refused}");
    assert_eq!(refused["error"]["details"]["reason"], "base_changed", "{refused}");
    assert_eq!(read(&repo, "a.txt").as_deref(), Some("agent\n"), "a refusal writes nothing");

    // A dry run reports the moved base without refusing.
    let dry = daemon.restore(&unique("dry"), json!({"checkpoint_id": before, "dry_run": true}));
    assert_eq!(dry["value"]["base_changed"], true, "{dry}");

    let head = git(&repo, &["rev-parse", "HEAD"]);
    let allowed = daemon
        .restore(&unique("allowed"), json!({"checkpoint_id": before, "allow_base_change": true}));
    assert_eq!(allowed["value"]["base_changed"], true, "{allowed}");
    assert_eq!(read(&repo, "a.txt").as_deref(), Some("one\n"));
    assert_eq!(staged(&repo, "a.txt").as_deref(), Some("one\n"));
    assert_eq!(git(&repo, &["rev-parse", "HEAD"]), head, "HEAD never moves");
}

#[test]
fn checkpoint_restore_refuses_a_checkout_of_another_branch_at_the_same_commit() {
    let mut daemon = Daemon::new("ckpt-restore-branch");
    let repo = daemon.repo.clone();
    let before = daemon.checkpoint();
    git(&repo, &["checkout", "--quiet", "-b", "other"]);
    write(&repo, "a.txt", "agent\n");

    let refused = daemon.request(
        "git.checkpoint.restore",
        Some(&unique("branch")),
        json!({"checkpoint_id": before}),
    );
    assert_eq!(refused["ok"], false, "{refused}");
    assert_eq!(refused["error"]["details"]["reason"], "base_changed", "{refused}");
    assert_eq!(read(&repo, "a.txt").as_deref(), Some("agent\n"), "a refusal writes nothing");
}

#[test]
fn checkpoint_restore_of_an_unknown_checkpoint_is_not_found() {
    let mut daemon = Daemon::new("ckpt-restore-missing");
    daemon.checkpoint();
    let reply = daemon.request(
        "git.checkpoint.restore",
        Some(&unique("missing")),
        json!({"checkpoint_id": "ckpt_00000000000000000000000000000000"}),
    );
    assert_eq!(reply["error"]["code"], "resource.not_found", "{reply}");
}
