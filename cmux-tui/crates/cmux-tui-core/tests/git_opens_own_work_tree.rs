#![cfg(unix)]
//! The daemon's git operations open a folder as a part of its own work tree only, over a real
//! session socket and with the real git.
//!
//! - A folder that is not in the work tree that git gives for it is refused by each git
//!   operation, a read or a write, with the error `git_failed` and one problem text.
//! - An operation that needs the two git folders of a work tree gets them for a main checkout
//!   whose name has a line break.
//! - A file that cmux keeps in a git folder (a setup's status, the repository's ports) is read
//!   to a size limit only.

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

/// How the problem text of each refusal of the open starts.
const REFUSED: &str = "this folder is not opened: ";

/// A new folder for one test, by its real path.
fn scratch(name: &str) -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let unique = NEXT.fetch_add(1, Ordering::Relaxed);
    let folder = std::env::temp_dir().join(format!("gown-{}-{name}-{unique}", std::process::id()));
    let _ = std::fs::remove_dir_all(&folder);
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::canonicalize(folder).unwrap()
}

/// Runs git in `directory`, apart from the host's git config.
fn git(directory: &Path, arguments: &[&str]) {
    let ended = Command::new("git")
        .arg("-C")
        .arg(directory)
        .args(["-c", "maintenance.auto=false", "-c", "user.name=t", "-c", "user.email=t@e.test"])
        .args(arguments)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success();
    assert!(ended, "git {arguments:?} failed in {directory:?}");
}

/// A new repository at `repo` on `main` with one commit of `a.txt`.
fn new_repository(repo: &Path) {
    std::fs::create_dir_all(repo).unwrap();
    git(repo, &["init", "--quiet", "--initial-branch=main"]);
    std::fs::write(repo.join("a.txt"), "one\n").unwrap();
    git(repo, &["add", "a.txt"]);
    git(repo, &["commit", "--quiet", "-m", "a.txt"]);
}

/// A new repository `main` in `top` and a linked work tree `linked` of it.
fn main_and_linked(top: &Path) -> (PathBuf, PathBuf) {
    let (main, linked) = (top.join("main"), top.join("linked"));
    new_repository(&main);
    git(&main, &["worktree", "add", "--quiet", "-b", "linked", linked.to_str().unwrap()]);
    (main, linked)
}

/// A text that is one byte longer than the size limit of a file that cmux keeps in a git
/// folder.
fn above_the_limit() -> String {
    "x".repeat(1024 * 1024 + 1)
}

struct Client {
    stream: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    /// A client of a new daemon on a socket of its own in `folder`.
    fn of_a_new_daemon(folder: &Path) -> Self {
        let socket = folder.join("d.sock");
        let name = folder.file_name().unwrap().to_string_lossy().into_owned();
        let mux = Mux::new(format!("git-own-work-tree-{name}"), SurfaceOptions::default());
        server::serve(mux.clone(), Some(socket.clone())).unwrap();
        // The daemon lives as long as the test process.
        std::mem::forget(mux);
        let stream = UnixStream::connect(&socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        Self { stream: BufReader::new(stream), next: 0 }
    }

    /// The whole reply to one `operation` of `directory`, with each parameter of `more`.
    fn reply_with(&mut self, operation: &str, directory: &Path, more: &[(&str, &str)]) -> Value {
        self.next += 1;
        let id = format!("r{}", self.next);
        let mut params = json!({"path": directory, "machine": "current", "session": "current"});
        for (name, value) in more {
            params[*name] = json!(value);
        }
        let request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
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
}

#[test]
fn own_tree_each_git_operation_refuses_a_folder_that_is_not_in_the_work_tree_that_git_gives() {
    let top = scratch("outside");
    let mut client = Client::of_a_new_daemon(&top);
    let (folder, other) = (top.join("folder"), top.join("other"));
    new_repository(&folder);
    std::fs::create_dir_all(&other).unwrap();
    git(&folder, &["config", "core.worktree", other.to_str().unwrap()]);

    // The reads give the problem text as the reason.
    let reads: [(&str, &[(&str, &str)]); 5] = [
        ("git.status", &[]),
        ("git.branches", &[]),
        ("git.diff", &[("scope", "uncommitted")]),
        ("git.files.list", &[]),
        ("git.files.search", &[("query", "a")]),
    ];
    for (operation, more) in reads {
        let reply = client.reply_with(operation, &folder, more);
        assert_eq!(reply["ok"], false, "{operation}: {reply}");
        let details = &reply["error"]["details"];
        assert_eq!(details["extra"]["code"], "git_failed", "{operation}: {reply}");
        let reason = details["reason"].as_str().unwrap_or_default();
        assert!(reason.starts_with(REFUSED), "{operation}: {reply}");
    }
    // An operation with a write target gives it as the message of the reason `git_failed`.
    let reply = client.reply_with("git.worktree.setup", &folder, &[]);
    assert_eq!(reply["ok"], false, "{reply}");
    let details = &reply["error"]["details"];
    assert_eq!(details["reason"], "git_failed", "{reply}");
    let message = details["extra"]["message"].as_str().unwrap_or_default();
    assert!(message.starts_with(REFUSED), "{reply}");
}

#[test]
fn own_tree_git_worktree_setup_reads_a_work_tree_whose_main_checkout_name_has_a_line_break() {
    let top = scratch("line-break");
    let mut client = Client::of_a_new_daemon(&top);
    let main = top.join("main\ncheckout");
    new_repository(&main);
    let linked = top.join("linked");
    git(&main, &["worktree", "add", "--quiet", "-b", "linked", linked.to_str().unwrap()]);

    // The status file of a setup that ended, in the work tree's own git folder.
    let status = r#"{"state":"succeeded","started_ms":1,"finished_ms":2}"#;
    std::fs::write(main.join(".git/worktrees/linked/cmux-setup.json"), status).unwrap();

    let reply = client.reply_with("git.worktree.setup", &linked, &[]);

    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["result"]["main_root"], json!(main), "{reply}");
    assert_eq!(reply["result"]["run"]["state"], "succeeded", "{reply}");
}

#[test]
fn own_tree_git_worktree_setup_takes_a_status_file_above_the_size_limit_as_no_status() {
    let top = scratch("large-status");
    let mut client = Client::of_a_new_daemon(&top);
    let (main, linked) = main_and_linked(&top);
    let status_file = main.join(".git/worktrees/linked/cmux-setup.json");

    // A status of a setup that ended is read.
    let status = json!({"state": "succeeded", "started_ms": 1, "finished_ms": 2});
    std::fs::write(&status_file, status.to_string()).unwrap();
    let reply = client.reply_with("git.worktree.setup", &linked, &[]);
    assert_eq!(reply["result"]["run"]["state"], "succeeded", "{reply}");

    // The same status in a file above the limit is no status.
    let status = json!({
        "state": "succeeded", "started_ms": 1, "finished_ms": 2, "setup": above_the_limit(),
    });
    std::fs::write(&status_file, status.to_string()).unwrap();
    let reply = client.reply_with("git.worktree.setup", &linked, &[]);
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["result"]["run"]["state"], "none", "{reply}");
}

#[test]
fn own_tree_git_worktree_setup_reads_no_port_from_a_ports_file_above_the_size_limit() {
    let top = scratch("large-ports");
    let mut client = Client::of_a_new_daemon(&top);
    let (main, linked) = main_and_linked(&top);
    let ports_file = main.join(".git/cmux-worktree-ports.json");

    // The work tree's port is read.
    let (own, more) = (linked.to_str().unwrap(), above_the_limit());
    let ports = json!({own: 40_000});
    std::fs::write(&ports_file, ports.to_string()).unwrap();
    let reply = client.reply_with("git.worktree.setup", &linked, &[]);
    assert_eq!(reply["result"]["run"]["port"], 40_000, "{reply}");

    // The same port in a file above the limit is not read, and the file stays.
    let ports = json!({own: 40_000, more: 1}).to_string();
    std::fs::write(&ports_file, &ports).unwrap();
    let reply = client.reply_with("git.worktree.setup", &linked, &[]);
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["result"]["run"]["port"], Value::Null, "{reply}");
    assert_eq!(std::fs::read_to_string(&ports_file).unwrap(), ports);
}
