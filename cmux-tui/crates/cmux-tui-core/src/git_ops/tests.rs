use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::parse;

#[path = "files_tests.rs"]
mod files;
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

/// Runs the setup's git without the machine's own git config.
fn git(directory: &Path, args: &[&str]) -> String {
    let mut command = Command::new("git");
    for (name, _) in std::env::vars_os() {
        if name.as_encoded_bytes().starts_with(b"GIT_") {
            command.env_remove(name);
        }
    }
    let home = std::env::temp_dir().join("cmux-git-ops-home");
    fs::create_dir_all(&home).unwrap();
    command.env("HOME", home).env("GIT_CONFIG_NOSYSTEM", "1");
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
    assert_eq!(summary(&empty), Vec::<(String, String, u64, u64)>::new());
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
fn a_repositorys_filter_driver_never_runs() {
    let mux = mux();
    let repository = repository("filter");
    let marker = repository.with_extension("filter-ran");
    write(&repository, "a.txt", b"one\n");
    commit_all(&repository, "first");
    // Diffing the working tree would run the clean filter on a.txt.
    write(&repository, ".gitattributes", b"*.txt filter=evil\n");
    let command = format!("touch '{}'; cat", marker.display());
    for key in ["filter.evil.clean", "filter.evil.smudge"] {
        git(&repository, &["config", key, command.as_str()]);
    }
    git(&repository, &["config", "filter.evil.required", "true"]);
    write(&repository, "a.txt", b"two\n");

    let result = diff(&mux, &repository, json!({"scope":"uncommitted","include_patch":true}));
    assert_eq!(file(&result, "a.txt")["patch"], "@@ -1 +1 @@\n-one\n+two\n");
    diff(&mux, &repository, json!({"scope":"unstaged"}));
    ok(call(&mux, "git.status", json!({"path":repository.to_string_lossy()})));
    assert!(!marker.exists(), "the filter ran");
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
        ("git.files.search", json!({"path":path,"query":"x"})),
        ("git.files.search", json!({"path":path,"query":""})),
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

#[test]
fn name_status_maps_codes_and_pairs_renames() {
    let output = concat!("M\0a.txt\0R087\0old name.txt\0new.txt\0", "D\0b\0A\0c\0C100\0s\0t\0");
    let parsed = parse::name_status(output.as_bytes());
    let rows = parsed
        .iter()
        .map(|entry| (entry.path.as_str(), entry.previous_path.as_deref(), entry.status))
        .collect::<Vec<_>>();
    assert_eq!(
        rows,
        vec![
            ("a.txt", None, "modified"),
            ("new.txt", Some("old name.txt"), "renamed"),
            ("b", None, "deleted"),
            ("c", None, "added"),
            ("t", None, "added"),
        ]
    );
}

#[test]
fn numstat_reads_counts_binaries_and_renames() {
    let counts = parse::numstat(b"3\t1\ta.txt\0-\t-\timage.png\x002\t0\t\0old.txt\0new.txt\0");
    assert_eq!(counts["a.txt"], Some(parse::LineCounts { additions: 3, deletions: 1 }));
    assert_eq!(counts["image.png"], None);
    assert_eq!(counts["new.txt"], Some(parse::LineCounts { additions: 2, deletions: 0 }));
    assert!(!counts.contains_key("old.txt"));
}

#[test]
fn patches_start_at_the_first_hunk_and_name_their_file() {
    let output = concat!(
        "diff --git a/a.txt b/a.txt\nindex 1..2 100644\n--- a/a.txt\n+++ b/a.txt\n",
        "@@ -1 +1 @@\n-a\n+A\n",
        "diff --git a/gone.txt b/gone.txt\ndeleted file mode 100644\n",
        "--- a/gone.txt\n+++ /dev/null\n",
        "@@ -1 +0,0 @@\n-gone\n",
        "diff --git a/img.png b/img.png\nBinary files a/img.png and b/img.png differ\n",
        "diff --git a/with space.txt b/with space.txt\n",
        "--- a/with space.txt\t\n+++ b/with space.txt\t\n",
        "@@ -1 +1 @@\n-x\n+y\n",
        "diff --git \"a/tab\\there.txt\" \"b/tab\\there.txt\"\n",
        "--- \"a/tab\\there.txt\"\n+++ \"b/tab\\there.txt\"\n",
        "@@ -1 +1 @@\n-p\n+q\n",
    );
    let patches = parse::patches(output.as_bytes());
    assert_eq!(
        patches,
        vec![
            ("a.txt".to_string(), "@@ -1 +1 @@\n-a\n+A\n".to_string()),
            ("gone.txt".to_string(), "@@ -1 +0,0 @@\n-gone\n".to_string()),
            ("with space.txt".to_string(), "@@ -1 +1 @@\n-x\n+y\n".to_string()),
            ("tab\there.txt".to_string(), "@@ -1 +1 @@\n-p\n+q\n".to_string()),
        ]
    );
}

#[test]
fn a_patch_is_cut_at_a_line_end_or_a_character_boundary() {
    let mut patch = "@@ -1 +1 @@\n-one\n+two\n".to_string();
    assert!(!parse::truncate_patch(&mut patch, 100));
    assert!(parse::truncate_patch(&mut patch, 20));
    assert_eq!(patch, "@@ -1 +1 @@\n-one\n");
    let mut single = "+ééééé".to_string();
    assert!(parse::truncate_patch(&mut single, 4));
    assert_eq!(single, "+é");
}

#[test]
fn branch_headers_read_detached_unborn_and_ahead_behind() {
    let output = concat!(
        "# branch.oid abc\0# branch.head topic\0",
        "# branch.upstream origin/topic\0# branch.ab +2 -3\0",
        "1 .M N... a\0",
    );
    let headers = parse::branch_headers(output.as_bytes());
    assert_eq!(
        headers,
        parse::BranchHeaders {
            head: Some("abc".into()),
            branch: Some("topic".into()),
            upstream: Some("origin/topic".into()),
            ahead: 2,
            behind: 3,
        }
    );
    let unborn = parse::branch_headers(b"# branch.oid (initial)\0# branch.head (detached)\0");
    assert_eq!(unborn, parse::BranchHeaders::default());
}
