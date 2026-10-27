#![cfg(unix)]
//! `git.diff`'s `context_lines` over a real session socket (cx-ncc.85, Show
//! more lines): the changes view asks for one file's patch with enough
//! unchanged lines around each change to hold the whole file, and rebuilds
//! both sides of the file from it.

use cmux_process::Command;
use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
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

fn patch(result: &Value) -> String {
    result["files"][0]["patch"].as_str().unwrap_or_else(|| panic!("no patch: {result}")).to_owned()
}

#[test]
fn cmux_next_git_diff_context_lines_give_the_whole_file() {
    let dir = std::env::temp_dir().join(unique("gdc"));
    let repo = dir.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "--quiet"]);
    let lines: Vec<String> = (1..=30).map(|n| format!("line {n}")).collect();
    write(&repo, "src/a.txt", &(lines.join("\n") + "\n"));
    write(&repo, "b.txt", "other\n");
    git(&repo, &["add", "."]);
    git(
        &repo,
        &["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "--quiet", "-m", "one"],
    );
    let mut changed = lines;
    changed[14] = "line 15 changed".into();
    write(&repo, "src/a.txt", &(changed.join("\n") + "\n"));
    write(&repo, "b.txt", "other changed\n");

    let mux = Mux::new(unique("git-diff-context"), SurfaceOptions::default());
    let socket = dir.join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    let mut client = Client::connect(&socket);
    let path = repo.to_string_lossy();

    // Git's own three lines by default.
    let usual = client.read(
        "git.diff",
        json!({"path": path, "scope": "uncommitted", "include_patch": true, "paths": ["src/a.txt"]}),
    );
    assert!(!patch(&usual).contains("\n line 1\n"), "{usual}");

    // Enough context for the whole file, for that file only.
    let whole = client.read(
        "git.diff",
        json!({"path": path, "scope": "uncommitted", "include_patch": true,
               "paths": ["src/a.txt"], "context_lines": 100000}),
    );
    assert_eq!(whole["files"].as_array().map(Vec::len), Some(1), "{whole}");
    let text = patch(&whole);
    assert!(text.contains("@@ -1,30 +1,30 @@"), "{text}");
    assert!(text.contains("\n line 1\n") && text.contains("\n line 30\n"), "{text}");
    assert!(text.contains("\n-line 15\n+line 15 changed\n"), "{text}");

    mux.shutdown();
    server::cleanup(&socket);
    let _ = std::fs::remove_dir_all(&dir);
}
