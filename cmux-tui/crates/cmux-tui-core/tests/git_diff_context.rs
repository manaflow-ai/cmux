#![cfg(unix)]
//! `git.diff`'s `context_lines` over a real session socket (cx-ncc.85, Show
//! more lines): the changes view asks for one file's patch with enough
//! unchanged lines around each change to hold the whole file, and rebuilds
//! both sides of the file from it.

use base64::Engine as _;
use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::Path;
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

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
        let reply = self.request(operation, params.take());
        assert_eq!(reply["ok"], true, "{operation} failed: {reply}");
        reply["result"].clone()
    }

    fn request(&mut self, operation: &str, mut params: Value) -> Value {
        self.next += 1;
        let id = format!("r{}", self.next);
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        if operation == "git.checkpoint.create" {
            request["idempotency_key"] = json!(unique("checkpoint-create"));
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

    // A repository-root pathspec is a directory filter, not an empty
    // pathspec. Normalizing ./file must keep both . and ./ working too.
    for paths in [json!(["."]), json!(["./"])] {
        let root = client.read(
            "git.diff",
            json!({"path": path, "scope": "uncommitted", "include_patch": true, "paths": paths}),
        );
        assert_eq!(root["files"].as_array().map(Vec::len), Some(2), "{root}");
        assert!(
            root["files"]
                .as_array()
                .unwrap()
                .iter()
                .all(|file| { file["patch"].as_str().is_some_and(|patch| !patch.is_empty()) }),
            "{root}"
        );
    }
    let directory = client.read(
        "git.diff",
        json!({"path": path, "scope": "uncommitted", "include_patch": true, "paths": ["./src/"]}),
    );
    assert_eq!(directory["files"].as_array().map(Vec::len), Some(1), "{directory}");
    assert_eq!(directory["files"][0]["path"], "src/a.txt");

    mux.shutdown();
    server::cleanup(&socket);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn cmux_next_git_diff_pages_a_large_patch_without_losing_bytes() {
    let dir = std::env::temp_dir().join(unique("gdp"));
    let repo = dir.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "--quiet"]);
    write(&repo, "large.txt", "old\n");
    git(&repo, &["add", "."]);
    git(
        &repo,
        &["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "--quiet", "-m", "one"],
    );
    // Well past both the old per-file cap and a protocol frame; non-ASCII
    // text deliberately crosses a page boundary.
    let body = (0..300_000)
        .map(|line| format!("line {line:06} café changed payload\n"))
        .collect::<String>();
    write(&repo, "large.txt", &body);
    let expected = Command::new("git")
        .arg("-C")
        .arg(&repo)
        .args([
            "-c",
            "core.quotePath=false",
            "diff",
            "--no-ext-diff",
            "--no-textconv",
            "--no-color",
            "--full-index",
            "--src-prefix=a/",
            "--dst-prefix=b/",
            "--unified=3",
            "HEAD",
            "--",
            "large.txt",
        ])
        .output()
        .unwrap();
    assert!(expected.status.success());
    let mux = Mux::new(unique("git-diff-pages"), SurfaceOptions::default());
    let socket = dir.join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    let mut client = Client::connect(&socket);
    let path = repo.to_string_lossy();
    let started = Instant::now();
    let legacy = client.read("git.diff", json!({"path": path, "scope": "uncommitted", "include_patch": true, "paths": ["large.txt"]}));
    let legacy_ms = started.elapsed().as_secs_f64() * 1_000.0;
    assert_eq!(legacy["files"][0]["patch_truncated"], true);
    let legacy_bytes = legacy["files"][0]["patch"].as_str().unwrap().len();
    let started = Instant::now();
    let mut bytes = Vec::new();
    let mut revision: Option<String> = None;
    let mut offset = 0_u64;
    let mut page_count = 0;
    let mut max_page_bytes = 0;
    let mut first_page_ms = 0.0;
    loop {
        let mut params = json!({"path": path, "scope": "uncommitted", "include_patch": true,
            "paths": ["./large.txt/"], "patch_offset": offset.to_string()});
        if let Some(revision) = &revision {
            params["patch_revision"] = json!(revision);
        }
        let page = client.read("git.diff", params);
        if page_count == 0 {
            first_page_ms = started.elapsed().as_secs_f64() * 1_000.0;
        }
        let page = &page["patch_page"];
        assert_eq!(page["offset"].as_str().unwrap().parse::<u64>().unwrap(), offset);
        let next_revision = page["revision"].as_str().unwrap().to_owned();
        if let Some(revision) = &revision {
            assert_eq!(&next_revision, revision);
        }
        revision = Some(next_revision);
        let chunk = base64::engine::general_purpose::STANDARD
            .decode(page["data_base64"].as_str().unwrap())
            .unwrap();
        assert!(chunk.len() <= 512 * 1024);
        max_page_bytes = max_page_bytes.max(chunk.len());
        bytes.extend_from_slice(&chunk);
        let next = page["next_offset"].as_str().unwrap().parse::<u64>().unwrap();
        assert!(next > offset);
        offset = next;
        page_count += 1;
        assert!(page_count <= 100, "patch paging did not finish");
        if page["complete"] == true {
            break;
        }
    }
    assert_eq!(bytes, expected.stdout);
    assert_eq!(String::from_utf8(bytes.clone()).unwrap().matches("café").count(), 300_000);
    // Revision alone does not authorize replay under another scope, path,
    // context or repository. All are part of the stable server-derived key.
    for changed in
        [json!({"scope":"unstaged"}), json!({"paths":["other.txt"]}), json!({"context_lines":4})]
    {
        let mut params = json!({"path":path,"scope":"uncommitted","include_patch":true,
            "paths":["large.txt"],"patch_offset":"1","patch_revision":revision});
        params.as_object_mut().unwrap().extend(changed.as_object().unwrap().clone());
        let refused = client.request("git.diff", params);
        assert_eq!(refused["ok"], false, "{refused}");
        assert!(refused.to_string().contains("patch_expired"), "{refused}");
    }
    let other_repo = dir.join("other");
    std::fs::create_dir_all(&other_repo).unwrap();
    git(&other_repo, &["init", "--quiet"]);
    let refused = client.request(
        "git.diff",
        json!({"path":other_repo.to_string_lossy(),
        "scope":"uncommitted","include_patch":true,"paths":["large.txt"],
        "patch_offset":"1","patch_revision":revision}),
    );
    assert_eq!(refused["ok"], false, "{refused}");
    assert!(refused.to_string().contains("patch_expired"), "{refused}");

    let missing_revision = client.request(
        "git.diff",
        json!({"path": path, "scope": "uncommitted", "include_patch": true,
        "paths": ["large.txt"], "patch_offset": "1"}),
    );
    assert_eq!(missing_revision["ok"], false, "continuations require a source revision");
    assert!(missing_revision.to_string().contains("patch_revision"), "{missing_revision}");
    println!(
        "DIFF_PAGE_BENCH {{\"legacyMs\":{legacy_ms},\"firstPageMs\":{first_page_ms},\"allPagesMs\":{},\"legacyPatchBytes\":{legacy_bytes},\"completePatchBytes\":{},\"maxPageBytes\":{max_page_bytes},\"pages\":{page_count}}}",
        started.elapsed().as_secs_f64() * 1_000.0,
        bytes.len()
    );
    write(&repo, "large.txt", "changed again\n");
    let changed = client.request(
        "git.diff",
        json!({"path": path, "scope": "uncommitted", "include_patch": true,
        "paths": ["large.txt"], "patch_offset": "0", "patch_revision": revision}),
    );
    assert_eq!(changed["ok"], false, "pages from a changed file must never be joined");
    assert!(changed.to_string().contains("repository_changed"), "{changed}");
    let captured = client.read(
        "git.diff",
        json!({"path": path, "scope": "uncommitted", "include_patch": true,
        "paths": ["large.txt"], "patch_offset": "1", "patch_revision": revision}),
    );
    let captured_bytes = base64::engine::general_purpose::STANDARD
        .decode(captured["patch_page"]["data_base64"].as_str().unwrap())
        .unwrap();
    assert_eq!(
        captured_bytes,
        expected.stdout[1..1 + captured_bytes.len()],
        "continuations must read the original immutable capture without regenerating it"
    );
    write(&repo, "next.txt", "next\n");
    write(&repo, "z.txt", "last\n");
    let mut after: Option<String> = None;
    let mut names = Vec::new();
    loop {
        let mut params = json!({"path": path, "scope": "uncommitted", "max_files": 1});
        if let Some(after) = &after {
            params["after_path"] = json!(after);
        }
        let page = client.read("git.diff", params);
        assert_eq!(page["total_files"], 3);
        names.extend(
            page["files"]
                .as_array()
                .unwrap()
                .iter()
                .map(|file| file["path"].as_str().unwrap().to_owned()),
        );
        after = page["next_path"].as_str().map(str::to_owned);
        if after.is_none() {
            break;
        }
        assert!(names.len() < 4);
    }
    assert_eq!(names, ["large.txt", "next.txt", "z.txt"]);
    mux.shutdown();
    server::cleanup(&socket);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn checkpoint_pages_keep_their_original_live_tree_and_completeness() {
    let dir = std::env::temp_dir().join(unique("gcp"));
    let repo = dir.join("repo");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "--quiet"]);
    write(&repo, "a.txt", "old\n");
    write(&repo, "other.txt", "other\n");
    git(&repo, &["add", "."]);
    git(
        &repo,
        &["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "--quiet", "-m", "one"],
    );
    let mux = Mux::open_persistent(
        unique("checkpoint-pages"),
        SurfaceOptions::default(),
        &dir.join("state"),
    )
    .unwrap();
    let socket = dir.join("s.sock");
    server::serve(mux.clone(), Some(socket.clone())).unwrap();
    let mut client = Client::connect(&socket);
    let path = repo.to_string_lossy();
    let created = client.read("git.checkpoint.create", json!({"path":path}));
    let from = created["value"]["checkpoint_id"].as_str().unwrap();
    assert_eq!(created["value"]["complete"], true, "{created}");
    write(&repo, "a.txt", "new\n");
    // Default checkpoint capture excludes untracked files larger than 10MB,
    // which makes the live comparison incomplete. Preserve that flag too.
    std::fs::write(repo.join("oversized.txt"), vec![b'x'; 10_000_001]).unwrap();
    let first = client.read(
        "git.checkpoint.diff",
        json!({"path":path,"from":from,
        "include_patch":true,"paths":["a.txt"],"patch_offset":"0"}),
    );
    assert_eq!(first["complete"], false, "{first}");
    let revision = first["patch_page"]["revision"].clone();
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(first["patch_page"]["data_base64"].as_str().unwrap())
        .unwrap();
    assert!(bytes.len() > 1);
    // A later unrelated edit must not recapture/re-hash the working tree or
    // label the captured bytes with a new completeness decision.
    write(&repo, "other.txt", "changed after first page\n");
    std::fs::remove_file(repo.join("oversized.txt")).unwrap();
    let next = client.read(
        "git.checkpoint.diff",
        json!({"path":path,"from":from,
        "include_patch":true,"paths":["a.txt"],"patch_offset":"1","patch_revision":revision}),
    );
    assert_eq!(next["complete"], false, "{next}");
    assert_eq!(next["from"], from);
    let resumed = base64::engine::general_purpose::STANDARD
        .decode(next["patch_page"]["data_base64"].as_str().unwrap())
        .unwrap();
    assert_eq!(resumed, bytes[1..]);
    let missing = client.request(
        "git.checkpoint.diff",
        json!({"path":path,"from":"ckpt_missing",
        "include_patch":true,"paths":["a.txt"],"patch_offset":"1","patch_revision":revision}),
    );
    assert_eq!(missing["ok"], false, "{missing}");
    mux.shutdown();
    server::cleanup(&socket);
    let _ = std::fs::remove_dir_all(&dir);
}
