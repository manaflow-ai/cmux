#![cfg(unix)]
//! `git.files.list` over a real session socket: the children of one folder
//! of a repository, the way a file explorer tree shows them. Folders come
//! first, ignored files never show, a nested folder is a directory, and a
//! symlink is never one.

use cmux_process::Command;
use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

fn unique(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

fn git(repo: &Path, arguments: &[&str]) {
    let status = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(arguments)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .status()
        .unwrap();
    assert!(status.success(), "git {arguments:?} failed");
}

fn write(repo: &Path, path: &str, contents: &str) {
    let path = repo.join(path);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, contents).unwrap();
}

/// A repository with a tracked top-level file, a tracked nested file, an
/// untracked file, and an ignored folder.
fn repository(dir: &Path) -> PathBuf {
    let repo = dir.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "--quiet"]);
    write(&repo, "README.md", "readme\n");
    write(&repo, "src/main.rs", "fn main() {}\n");
    write(&repo, "src/deep/x.rs", "\n");
    git(&repo, &["add", "README.md", "src/main.rs", "src/deep/x.rs"]);
    write(&repo, "notes.txt", "untracked\n");
    write(&repo, ".gitignore", "target/\n");
    write(&repo, "target/debug/out.bin", "ignored\n");
    repo
}

struct Client {
    stream: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    fn connect(path: &Path) -> Self {
        let stream = UnixStream::connect(path).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(12))).unwrap();
        Self { stream: BufReader::new(stream), next: 0 }
    }

    /// One `cmux.protocol/2` read; returns its result.
    fn read(&mut self, operation: &str, mut params: Value) -> Value {
        self.next += 1;
        let id = format!("r{}", self.next);
        params["machine"] = json!("current");
        params["session"] = json!("current");
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
                assert_eq!(reply["ok"], true, "{request} failed: {reply}");
                return reply["result"].clone();
            }
        }
    }
}

fn entries(result: &Value) -> Vec<(String, String)> {
    result["entries"]
        .as_array()
        .unwrap_or_else(|| panic!("no entries: {result}"))
        .iter()
        .map(|entry| {
            (entry["name"].as_str().unwrap().to_owned(), entry["kind"].as_str().unwrap().to_owned())
        })
        .collect()
}

fn entry(name: &str, kind: &str) -> (String, String) {
    (name.to_owned(), kind.to_owned())
}

#[test]
fn cmux_next_git_files_list_lists_one_folder() {
    let dir = std::env::temp_dir().join(unique("gfl"));
    std::fs::create_dir_all(&dir).unwrap();
    let repo = repository(&dir);
    let mux = Mux::new(unique("git-files-list"), SurfaceOptions::default());
    let socket = dir.join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();

    let mut identify = BufReader::new(UnixStream::connect(&socket).unwrap());
    writeln!(identify.get_mut(), r#"{{"id":1,"cmd":"identify"}}"#).unwrap();
    let mut line = String::new();
    identify.read_line(&mut line).unwrap();
    let identified: Value = serde_json::from_str(&line).unwrap();
    let capabilities = identified["data"]["capabilities"].as_array().unwrap();
    assert!(capabilities.iter().any(|value| value == "git-files-list-v1"), "{identified}");

    let mut client = Client::connect(&socket);
    let top = client.read("git.files.list", json!({"path": repo.to_string_lossy()}));
    assert_eq!(top["folder"], top["root"], "{top}");
    assert_eq!(
        entries(&top),
        [
            entry("src", "directory"),
            entry(".gitignore", "file"),
            entry("notes.txt", "file"),
            entry("README.md", "file"),
        ],
        "folders first, then names case-insensitively; ignored target/ is absent: {top}"
    );
    assert_eq!(top["truncated"], false, "{top}");

    let src = client.read("git.files.list", json!({"path": repo.join("src").to_string_lossy()}));
    assert!(src["folder"].as_str().unwrap().ends_with("/src"), "{src}");
    assert_eq!(src["root"], top["root"], "{src}");
    assert_eq!(entries(&src), [entry("deep", "directory"), entry("main.rs", "file")], "{src}");

    let first = client.read("git.files.list", json!({"path": repo.to_string_lossy(), "limit": 1}));
    assert_eq!(entries(&first), [entry("src", "directory")], "{first}");
    assert_eq!(first["truncated"], true, "{first}");

    // A symlink to a folder outside the repository is a leaf: the tree never
    // lists through it.
    let outside = dir.join("outside");
    write(&outside, "secret.txt", "outside\n");
    std::os::unix::fs::symlink(&outside, repo.join("linked")).unwrap();
    let linked = client.read("git.files.list", json!({"path": repo.to_string_lossy()}));
    assert!(entries(&linked).contains(&entry("linked", "file")), "{linked}");

    mux.shutdown();
    server::cleanup(&socket);
    let _ = std::fs::remove_dir_all(&dir);
}
