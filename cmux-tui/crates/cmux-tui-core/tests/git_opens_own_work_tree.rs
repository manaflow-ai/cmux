#![cfg(unix)]
//! The daemon's git operations open a folder as a part of its own work tree only, over a real
//! session socket and with the real git.
//!
//! - A folder that is not in the work tree that git gives for it is refused by each git
//!   operation, a read or a write, with the error `git_failed` and one problem text.
//! - A folder that the open refuses is refused by each git operation of the catalog, with the
//!   open's problem text, and no file in the folder or its git folder changes.
//! - An operation that needs the two git folders of a work tree gets them for a main checkout
//!   whose name has a line break.
//! - A file that cmux keeps in a git folder (a setup's status, the repository's ports) is read
//!   to a size limit only.

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, LazyLock};
use std::time::Duration;

/// How the problem text of each refusal of the open starts.
const REFUSED: &str = "this folder is not opened: ";

/// The catalog of the daemon's operations.
static CATALOG: LazyLock<Value> = LazyLock::new(|| {
    serde_json::from_str(include_str!("../../../spec/resource-operations-v2.json")).unwrap()
});

/// The folder of one test, by its real path. It is removed when the test ends.
struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

impl std::ops::Deref for Scratch {
    type Target = Path;

    fn deref(&self) -> &Path {
        &self.0
    }
}

/// A new folder for one test.
fn scratch(name: &str) -> Scratch {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    let unique = NEXT.fetch_add(1, Ordering::Relaxed);
    let folder = std::env::temp_dir().join(format!("gown-{}-{name}-{unique}", std::process::id()));
    let _ = std::fs::remove_dir_all(&folder);
    std::fs::create_dir_all(&folder).unwrap();
    Scratch(std::fs::canonicalize(folder).unwrap())
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

/// The session name of the daemon of the test whose folder is `folder`.
fn session_name(folder: &Path) -> String {
    format!("git-own-work-tree-{}", folder.file_name().unwrap().to_string_lossy())
}

struct Client {
    stream: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    /// A client of a new daemon on a socket of its own in `folder`.
    fn of_a_new_daemon(folder: &Path) -> Self {
        Self::of(Mux::new(session_name(folder), SurfaceOptions::default()), folder)
    }

    /// A client of a new daemon that keeps its state in `folder`, on a socket of its own
    /// there. The checkpoint operations need a daemon with a state folder.
    fn of_a_new_daemon_with_a_state_folder(folder: &Path) -> Self {
        let (name, state) = (session_name(folder), folder.join("state"));
        let mux = Mux::open_persistent(name, SurfaceOptions::default(), &state).unwrap();
        Self::of(mux, folder)
    }

    /// A client of the new daemon `mux` on a socket of its own in `folder`.
    fn of(mux: Arc<Mux>, folder: &Path) -> Self {
        let socket = folder.join("d.sock");
        server::serve(mux.clone(), Some(socket.clone())).unwrap();
        // The daemon lives as long as the test process.
        std::mem::forget(mux);
        let stream = UnixStream::connect(&socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        Self { stream: BufReader::new(stream), next: 0 }
    }

    /// The whole reply to one `operation` of `directory`, with each parameter of `more`.
    fn reply_with(&mut self, operation: &str, directory: &Path, more: &[(&str, &str)]) -> Value {
        let mut params = json!({});
        for (name, value) in more {
            params[*name] = json!(value);
        }
        self.reply(operation, directory, params)
    }

    /// The whole reply to one `operation` of `directory`, with the parameters `params`. An
    /// operation that the catalog gives a key gets a key that no other request has.
    fn reply(&mut self, operation: &str, directory: &Path, mut params: Value) -> Value {
        self.next += 1;
        let id = format!("r{}", self.next);
        params["path"] = json!(directory);
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        if CATALOG["operations"][operation]["idempotency"] == "required" {
            request["idempotency_key"] = json!(format!("gown-{}-{id}", std::process::id()));
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

/// The problem text of a reply that failed with the error `git_failed`, or no text. A read
/// gives the text as the reason. An operation with a write target gives it as the message of
/// the reason `git_failed`.
fn problem_of_git_failed(reply: &Value) -> &str {
    let details = &reply["error"]["details"];
    let as_a_read = details["extra"]["code"] == "git_failed";
    let as_a_write = details["reason"] == "git_failed";
    let text = if as_a_read { &details["reason"] } else { &details["extra"]["message"] };
    let failed = reply["ok"].as_bool() == Some(false) && (as_a_read || as_a_write);
    if failed { text.as_str().unwrap_or_default() } else { "" }
}

/// Each entry in `folder` and below it, by its path: its kind, the time of its last change,
/// and the bytes of a file or the target of a link.
fn entries(folder: &Path) -> BTreeMap<PathBuf, (String, Vec<u8>)> {
    let mut found = BTreeMap::new();
    let mut left = vec![folder.to_path_buf()];
    while let Some(path) = left.pop() {
        let metadata = std::fs::symlink_metadata(&path).unwrap();
        let (kind, bytes) = if metadata.is_dir() {
            left.extend(std::fs::read_dir(&path).unwrap().map(|entry| entry.unwrap().path()));
            ("folder", Vec::new())
        } else if metadata.is_symlink() {
            ("link", std::fs::read_link(&path).unwrap().into_os_string().into_encoded_bytes())
        } else {
            ("file", std::fs::read(&path).unwrap())
        };
        let state = format!("{kind}, last change {:?}", metadata.modified().ok());
        found.insert(path, (state, bytes));
    }
    found
}

/// Each folder with the name `name` in `folder` or below it. The daemon can change a file of
/// its state folder during the search, so an entry that is not read is not a folder.
fn folders_with_the_name(folder: &Path, name: &str) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut left = vec![folder.to_path_buf()];
    while let Some(path) = left.pop() {
        let Ok(children) = std::fs::read_dir(&path) else { continue };
        for child in children.filter_map(Result::ok).map(|child| child.path()) {
            if child.is_symlink() || !child.is_dir() {
                continue;
            }
            if child.file_name().is_some_and(|its_name| its_name == name) {
                found.push(child);
            } else {
                left.push(child);
            }
        }
    }
    found
}

#[test]
fn own_tree_each_git_operation_of_the_catalog_refuses_a_refused_folder_and_changes_no_file() {
    let top = scratch("writes");
    let mut client = Client::of_a_new_daemon_with_a_state_folder(&top);
    let trees = top.join("trees");
    // A repository whose `core.worktree` setting names another folder.
    let (outside, other) = (trees.join("outside"), trees.join("other"));
    new_repository(&outside);
    std::fs::create_dir_all(&other).unwrap();
    git(&outside, &["config", "core.worktree", other.to_str().unwrap()]);
    // A folder whose `.git` file names the git folder of another repository.
    let (named, second) = (trees.join("named"), trees.join("second"));
    new_repository(&second);
    std::fs::create_dir_all(&named).unwrap();
    let git_file = format!("gitdir: {}\n", second.join(".git").display());
    std::fs::write(named.join(".git"), git_file).unwrap();
    // Each of the two has a change that a commit of all files takes.
    std::fs::write(outside.join("a.txt"), "two\n").unwrap();
    std::fs::write(named.join("new.txt"), "new\n").unwrap();

    let pin = json!({"checkpoint_id": "none", "pin_id": "a-pin", "reason": "a test"});
    let commit = json!({"message": "a commit", "all": true, "include_untracked": true});
    let operations = [
        ("git.status", json!({})),
        ("git.branches", json!({})),
        ("git.diff", json!({"scope": "uncommitted"})),
        ("git.files.list", json!({})),
        ("git.files.search", json!({"query": "a"})),
        ("git.worktree.setup", json!({})),
        ("git.checkpoint.list", json!({})),
        ("git.checkpoint.get", json!({"checkpoint_id": "none"})),
        ("git.checkpoint.diff", json!({"from": "none"})),
        ("git.checkpoint.create", json!({})),
        ("git.checkpoint.pin", pin),
        ("git.checkpoint.unpin", json!({"checkpoint_id": "none", "pin_id": "a-pin"})),
        ("git.commit", commit),
        ("git.push", json!({})),
        ("git.worktree.create", json!({"name": "a-name"})),
        ("git.worktree.apply", json!({})),
        ("git.worktree.remove", json!({"discard": true})),
    ];
    // A new git operation of the catalog must be in the list.
    let sent: BTreeSet<&str> = operations.iter().map(|(operation, _)| *operation).collect();
    let all = CATALOG["operations"].as_object().unwrap().keys().map(String::as_str);
    let of_git: BTreeSet<&str> = all.filter(|operation| operation.starts_with("git.")).collect();
    assert_eq!(sent, of_git, "the test sends each git operation of the catalog");

    // Each layout is refused for its own cause.
    let layouts = [
        ("outside", &outside, "is not in the work tree that git gives"),
        ("named", &named, "names a git folder whose own name is `.git`"),
    ];
    let before = entries(&trees);
    for (layout, folder, cause) in layouts {
        for (operation, params) in &operations {
            let reply = client.reply(operation, folder, params.clone());

            let problem = problem_of_git_failed(&reply);
            assert!(problem.starts_with(REFUSED), "{operation} of `{layout}`: {reply}");
            assert!(problem.contains(cause), "{operation} of `{layout}`: {reply}");
            let after = entries(&trees);
            let changed: Vec<&PathBuf> =
                after.keys().filter(|path| before.get(*path) != after.get(*path)).collect();
            assert!(changed.is_empty(), "{operation} of `{layout}` changed {changed:?}");
            assert_eq!(before.len(), after.len(), "{operation} of `{layout}` removed an entry");
        }
    }
    // A checkpoint operation makes the folders of the daemon's checkpoint store, in the state
    // folder, before the open. The store gets no file for a folder that is refused.
    let stores = folders_with_the_name(&top.join("state"), "git-checkpoints");
    assert!(!stores.is_empty(), "the checkpoint store is not found below the state folder");
    for store in stores {
        let mut kept = entries(&store);
        kept.retain(|_, (state, _)| !state.starts_with("folder"));
        assert!(kept.is_empty(), "the checkpoint store has {:?}", kept.keys());
    }
}

#[test]
fn own_tree_a_test_folder_is_removed_when_its_test_ends() {
    let top = scratch("removed");
    let folder = top.to_path_buf();
    std::fs::write(folder.join("file"), "one\n").unwrap();

    drop(top);

    assert!(!folder.exists(), "the folder {folder:?} stays");
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
    // No message has the whole reply: when the status is read, the reply has its text, and a
    // failure's output is then one line above the limit.
    assert_eq!(reply["ok"], true, "{}", reply["error"]);
    assert_eq!(reply["result"]["run"]["state"], "none");
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
    // No `assert_eq`: its message has both texts, each above the limit.
    assert!(std::fs::read_to_string(&ports_file).unwrap() == ports, "the ports file changed");
}
