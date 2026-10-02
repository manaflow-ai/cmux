use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use crate::resource::TerminalPublicId;
use crate::resource_router::handle_resource_message;
use crate::{Mux, SurfaceOptions};

/// A fresh repository on `main` in its own temporary folder.
fn repository(name: &str) -> PathBuf {
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let folder =
        std::env::temp_dir().join(format!("cmux-git-ops-{name}-{}-{nanos}", std::process::id()));
    fs::create_dir_all(&folder).unwrap();
    let folder = fs::canonicalize(folder).unwrap();
    git(&folder, &["init", "-q", "-b", "main"]);
    folder
}

fn git(directory: &Path, args: &[&str]) -> String {
    let mut command = Command::new("git");
    for (name, _) in std::env::vars_os() {
        if name.as_encoded_bytes().starts_with(b"GIT_") {
            command.env_remove(name);
        }
    }
    let output = command
        .args([
            "-c",
            "user.name=cmux test",
            "-c",
            "user.email=test@example.invalid",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .current_dir(directory)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap().trim().to_string()
}

fn write(directory: &Path, path: &str, contents: &[u8]) {
    let path = directory.join(path);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, contents).unwrap();
}

fn commit_all(directory: &Path, message: &str) -> String {
    git(directory, &["add", "-A"]);
    git(directory, &["commit", "-q", "-m", message]);
    git(directory, &["rev-parse", "HEAD"])
}

fn mux() -> Arc<Mux> {
    Mux::new_for_test("git-ops", SurfaceOptions::default())
}

/// The response envelope for one request in this session.
fn call(mux: &Arc<Mux>, operation: &str, params: Value) -> Value {
    keyed_call(mux, operation, params, None)
}

fn keyed_call(mux: &Arc<Mux>, operation: &str, params: Value, key: Option<&str>) -> Value {
    let mut params = params;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let mut message = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("test-{operation}"),
        "operation":operation,
        "params":params,
    });
    if let Some(key) = key {
        message["idempotency_key"] = json!(key);
    }
    handle_resource_message(mux, &message.to_string()).unwrap()
}

fn ok(envelope: Value) -> Value {
    assert_eq!(envelope["ok"], true, "{envelope}");
    envelope["result"].clone()
}

fn failure(envelope: &Value) -> (String, Value) {
    assert_eq!(envelope["ok"], false, "{envelope}");
    (envelope["error"]["code"].as_str().unwrap().to_string(), envelope["error"]["details"].clone())
}

fn diff(mux: &Arc<Mux>, repository: &Path, fields: Value) -> Value {
    let mut params = fields;
    params["path"] = json!(repository.to_string_lossy());
    ok(call(mux, "git.diff", params))
}

fn summary(result: &Value) -> Vec<(String, String, u64, u64)> {
    result["files"]
        .as_array()
        .unwrap()
        .iter()
        .map(|file| {
            (
                file["path"].as_str().unwrap().to_string(),
                file["status"].as_str().unwrap().to_string(),
                file["additions"].as_u64().unwrap(),
                file["deletions"].as_u64().unwrap(),
            )
        })
        .collect()
}

fn file<'a>(result: &'a Value, path: &str) -> &'a Value {
    result["files"].as_array().unwrap().iter().find(|file| file["path"] == path).unwrap()
}

fn row(path: &str, status: &str, additions: u64, deletions: u64) -> (String, String, u64, u64) {
    (path.to_string(), status.to_string(), additions, deletions)
}

/// a.txt modified in the tree, b.txt deleted in the tree, c.txt added to the
/// index, d.txt untracked.
fn worked_repository(name: &str) -> (PathBuf, String) {
    let repository = repository(name);
    write(&repository, "a.txt", b"one\ntwo\nthree\n");
    write(&repository, "b.txt", b"gone\n");
    let head = commit_all(&repository, "first");
    write(&repository, "a.txt", b"one\nTWO\nthree\nfour\n");
    fs::remove_file(repository.join("b.txt")).unwrap();
    write(&repository, "c.txt", b"new\n");
    git(&repository, &["add", "c.txt"]);
    write(&repository, "d.txt", b"x\ny\nz");
    (repository, head)
}

#[test]
fn uncommitted_lists_tracked_and_untracked_files_with_counts_and_patches() {
    let mux = mux();
    let (repository, head) = worked_repository("uncommitted");
    let result = diff(&mux, &repository, json!({"scope":"uncommitted","include_patch":true}));
    assert_eq!(result["scope"], "uncommitted");
    assert_eq!(result["root"], repository.to_string_lossy().as_ref());
    assert_eq!(result["head"], head);
    assert!(result.get("base").is_none());
    assert_eq!(
        summary(&result),
        vec![
            row("a.txt", "modified", 2, 1),
            row("b.txt", "deleted", 0, 1),
            row("c.txt", "added", 1, 0),
            row("d.txt", "untracked", 3, 0),
        ]
    );
    assert_eq!((result["additions"].as_u64(), result["deletions"].as_u64()), (Some(6), Some(2)));
    assert_eq!(result["total_files"], 4);
    assert_eq!(result["files_omitted"], 0);
    assert_eq!(
        file(&result, "a.txt")["patch"],
        "@@ -1,3 +1,4 @@\n one\n-two\n+TWO\n three\n+four\n"
    );
    assert_eq!(file(&result, "b.txt")["patch"], "@@ -1 +0,0 @@\n-gone\n");
    // An untracked file has no patch.
    assert!(file(&result, "d.txt").get("patch").is_none());

    // Without include_patch there are no patches at all.
    let counts = diff(&mux, &repository, json!({"scope":"uncommitted"}));
    assert!(counts["files"].as_array().unwrap().iter().all(|file| file.get("patch").is_none()));
}

#[test]
fn staged_and_unstaged_split_the_index() {
    let mux = mux();
    let (repository, _) = worked_repository("index");
    let staged = diff(&mux, &repository, json!({"scope":"staged"}));
    assert_eq!(summary(&staged), vec![row("c.txt", "added", 1, 0)]);
    let unstaged = diff(&mux, &repository, json!({"scope":"unstaged"}));
    assert_eq!(
        summary(&unstaged),
        vec![
            row("a.txt", "modified", 2, 1),
            row("b.txt", "deleted", 0, 1),
            row("d.txt", "untracked", 3, 0),
        ]
    );
}

#[test]
fn committed_compares_head_with_its_parent() {
    let mux = mux();
    let repository = repository("committed");
    // Before the first commit there is nothing committed.
    write(&repository, "a.txt", b"one\n");
    let empty = diff(&mux, &repository, json!({"scope":"committed"}));
    assert_eq!(summary(&empty), vec![]);
    assert!(empty.get("head").is_none());

    let first = commit_all(&repository, "first");
    let root_commit = diff(&mux, &repository, json!({"scope":"committed"}));
    assert_eq!(summary(&root_commit), vec![row("a.txt", "added", 1, 0)]);
    assert!(root_commit.get("base").is_none());

    write(&repository, "a.txt", b"one\ntwo\n");
    write(&repository, "z.txt", b"not committed\n");
    let second = commit_all(&repository, "second");
    write(&repository, "a.txt", b"changed after\n");
    let result = diff(&mux, &repository, json!({"scope":"committed"}));
    assert_eq!(result["head"], second);
    assert_eq!(result["base"], first);
    assert_eq!(summary(&result), vec![row("a.txt", "modified", 1, 0), row("z.txt", "added", 1, 0)]);
}

#[test]
fn branch_compares_the_tree_with_the_merge_base_of_main() {
    let mux = mux();
    let repository = repository("branch");
    write(&repository, "a.txt", b"one\n");
    let fork = commit_all(&repository, "first");
    git(&repository, &["checkout", "-q", "-b", "feature"]);
    write(&repository, "b.txt", b"feature\n");
    commit_all(&repository, "feature");
    git(&repository, &["checkout", "-q", "main"]);
    write(&repository, "main-only.txt", b"main\n");
    commit_all(&repository, "main moves on");
    git(&repository, &["checkout", "-q", "feature"]);
    write(&repository, "a.txt", b"one\nmore\n");
    write(&repository, "new.txt", b"untracked\n");

    let result = diff(&mux, &repository, json!({"scope":"branch"}));
    assert_eq!(result["base"], fork);
    assert_eq!(
        summary(&result),
        vec![
            row("a.txt", "modified", 1, 0),
            row("b.txt", "added", 1, 0),
            row("new.txt", "untracked", 1, 0),
        ]
    );
}

#[test]
fn branch_without_a_base_branch_says_so() {
    let mux = mux();
    let repository = repository("no-base");
    git(&repository, &["checkout", "-q", "-b", "topic"]);
    write(&repository, "a.txt", b"one\n");
    commit_all(&repository, "first");
    let envelope =
        call(&mux, "git.diff", json!({"path":repository.to_string_lossy(),"scope":"branch"}));
    let (code, details) = failure(&envelope);
    assert_eq!(code, "operation.failed");
    assert_eq!(details["extra"]["code"], "no_base_branch");
}

#[test]
fn renames_and_binary_files_are_reported_as_such() {
    let mux = mux();
    let repository = repository("rename");
    write(&repository, "old.txt", b"one\ntwo\nthree\nfour\nfive\n");
    write(&repository, "image.bin", &[0, 1, 2, 3]);
    commit_all(&repository, "first");
    git(&repository, &["mv", "old.txt", "new.txt"]);
    write(&repository, "image.bin", &[0, 9, 9, 9]);
    write(&repository, "fresh.bin", &[0, 0, 7]);

    let result = diff(&mux, &repository, json!({"scope":"uncommitted","include_patch":true}));
    let renamed = file(&result, "new.txt");
    assert_eq!(renamed["status"], "renamed");
    assert_eq!(renamed["previous_path"], "old.txt");
    // An exact rename has no hunks, so no patch.
    assert!(renamed.get("patch").is_none());
    for path in ["image.bin", "fresh.bin"] {
        assert_eq!(file(&result, path)["binary"], true, "{path}");
        assert!(file(&result, path).get("patch").is_none(), "{path}");
    }
}

#[test]
fn bounds_cut_the_file_list_and_each_patch() {
    let mux = mux();
    let repository = repository("bounds");
    let long = (0..200).map(|line| format!("line {line}\n")).collect::<String>();
    write(&repository, "a.txt", b"a\n");
    write(&repository, "b.txt", b"b\n");
    write(&repository, "dir/c.txt", b"c\n");
    commit_all(&repository, "first");
    write(&repository, "a.txt", long.as_bytes());
    write(&repository, "b.txt", b"B\n");
    write(&repository, "dir/c.txt", b"C\n");

    let cut = diff(&mux, &repository, json!({"scope":"uncommitted","max_files":2}));
    assert_eq!(summary(&cut).len(), 2);
    assert_eq!((cut["total_files"].as_u64(), cut["files_omitted"].as_u64()), (Some(3), Some(1)));
    // Totals still count the omitted file.
    assert_eq!(cut["additions"], 202);

    let patched = diff(
        &mux,
        &repository,
        json!({"scope":"uncommitted","include_patch":true,"max_patch_bytes":64,"max_files":1}),
    );
    let a = file(&patched, "a.txt");
    assert_eq!(a["patch_truncated"], true);
    let patch = a["patch"].as_str().unwrap();
    assert!(patch.len() <= 64 && patch.starts_with("@@") && patch.ends_with('\n'), "{patch:?}");

    let only = diff(&mux, &repository, json!({"scope":"uncommitted","paths":["dir"]}));
    assert_eq!(summary(&only), vec![row("dir/c.txt", "modified", 1, 1)]);

    for outside in ["../a.txt", "/etc/passwd"] {
        let envelope = call(
            &mux,
            "git.diff",
            json!({"path":repository.to_string_lossy(),"scope":"uncommitted","paths":[outside]}),
        );
        assert_eq!(failure(&envelope).0, "validation.invalid", "{outside}");
    }
}

#[test]
fn many_untracked_files_are_counted_and_the_rest_skipped() {
    let mux = mux();
    let repository = repository("untracked");
    for index in 0..205 {
        write(&repository, &format!("u{index:03}.txt"), b"x\n");
    }
    let result = diff(&mux, &repository, json!({"scope":"uncommitted","max_files":5000}));
    assert_eq!(summary(&result).len(), 200);
    assert_eq!(result["untracked_skipped"], 5);
}

#[test]
fn a_folder_outside_a_repository_is_not_a_repository() {
    let mux = mux();
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let folder = std::env::temp_dir().join(format!("cmux-git-ops-plain-{nanos}"));
    fs::create_dir_all(&folder).unwrap();
    let path = folder.to_string_lossy();
    for (operation, params) in [
        ("git.status", json!({"path":path})),
        ("git.diff", json!({"path":path,"scope":"uncommitted"})),
    ] {
        let envelope = call(&mux, operation, params);
        let (code, details) = failure(&envelope);
        assert_eq!(code, "operation.failed", "{operation}");
        assert_eq!(details["extra"]["code"], "not_a_repository", "{operation}");
    }
    let missing_path = folder.join("missing");
    let missing = call(&mux, "git.status", json!({"path":missing_path.to_string_lossy()}));
    assert_eq!(failure(&missing).1["extra"]["code"], "target_not_found");
    let relative = call(&mux, "git.status", json!({"path":"relative/folder"}));
    assert_eq!(failure(&relative).0, "validation.invalid");
    let nothing = call(&mux, "git.status", json!({}));
    assert_eq!(failure(&nothing).0, "validation.invalid");
}

#[test]
fn status_reads_the_branch_upstream_and_base() {
    let mux = mux();
    let origin = repository("origin");
    write(&origin, "a.txt", b"one\n");
    commit_all(&origin, "first");
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let clone = std::env::temp_dir().join(format!("cmux-git-ops-clone-{nanos}"));
    let (from, to) = (origin.to_string_lossy().into_owned(), clone.to_string_lossy().into_owned());
    git(&origin, &["clone", "-q", from.as_str(), to.as_str()]);
    let clone = fs::canonicalize(clone).unwrap();
    write(&clone, "b.txt", b"two\n");
    let head = commit_all(&clone, "ahead");

    let file_path = clone.join("b.txt");
    let status = ok(call(&mux, "git.status", json!({"path":file_path.to_string_lossy()})));
    assert_eq!(
        status,
        json!({
            "root":clone.to_string_lossy(),
            "branch":"main",
            "detached":false,
            "head":head,
            "upstream":"origin/main",
            "base":"origin/main",
            "ahead":1,
            "behind":0,
        })
    );

    git(&clone, &["checkout", "-q", "--detach"]);
    let detached = ok(call(&mux, "git.status", json!({"path":clone.to_string_lossy()})));
    assert_eq!(detached["detached"], true);
    assert!(detached.get("branch").is_none());

    // Before the first commit there is a branch but no head.
    let fresh = repository("fresh");
    let unborn = ok(call(&mux, "git.status", json!({"path":fresh.to_string_lossy()})));
    assert_eq!(unborn["branch"], "main");
    assert!(unborn.get("head").is_none());
}

#[test]
fn a_selector_reads_its_terminals_working_directory() {
    let mux = mux();
    let repository = repository("selector");
    write(&repository, "src/main.rs", b"fn main() {}\n");
    commit_all(&repository, "first");
    let created = ok(keyed_call(
        &mux,
        "workspace.create",
        json!({"name":"git","initial_content":"terminal"}),
        Some("git-ops-selector"),
    ));
    let terminal = created["value"]["terminal_id"].as_str().unwrap().to_string();
    let workspace = created["value"]["workspace_id"].as_str().unwrap().to_string();
    let surface = mux
        .resource_surface_for_terminal(&TerminalPublicId::parse(&terminal).unwrap())
        .and_then(|surface| mux.surface(surface))
        .unwrap();
    surface.set_test_pwd(Some(format!("file://{}", repository.join("src").display())));

    for selector in [json!({"terminal":terminal}), json!({"workspace":workspace})] {
        let status = ok(call(&mux, "git.status", selector.clone()));
        assert_eq!(status["root"], repository.to_string_lossy().as_ref(), "{selector}");
    }
    let both =
        call(&mux, "git.status", json!({"terminal":terminal,"path":repository.to_string_lossy()}));
    assert_eq!(failure(&both).0, "validation.invalid");
}
