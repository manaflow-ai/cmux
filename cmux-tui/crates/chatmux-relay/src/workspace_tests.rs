use super::*;

#[cfg(unix)]
use super::git::{GitProcessGuard, GitStderrDrain, abort_git_operation, wait_git_until};

fn scratch(name: &str) -> PathBuf {
    let mut path = std::env::temp_dir();
    path.push(format!("chatmux-ws-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&path);
    std::fs::create_dir_all(&path).expect("scratch dir");
    std::fs::canonicalize(&path).expect("canonical scratch")
}

fn write(root: &Path, rel: &str, content: &str) {
    let path = root.join(rel);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).expect("parent");
    }
    std::fs::write(path, content).expect("write");
}

fn scope_for(root: &Path) -> Scope {
    let roots = vec![root.to_string_lossy().into_owned()];
    Scope::build(Some(&roots), Some(&roots)).expect("scope")
}

fn git(root: &Path, args: &[&str]) {
    let status = std::process::Command::new("git")
        .arg("-C")
        .arg(root)
        .args(args)
        .env("GIT_AUTHOR_NAME", "t")
        .env("GIT_AUTHOR_EMAIL", "t@t")
        .env("GIT_COMMITTER_NAME", "t")
        .env("GIT_COMMITTER_EMAIL", "t@t")
        .output()
        .expect("git runs");
    assert!(status.status.success(), "git {args:?} failed");
}

// --- scoping ---------------------------------------------------------

// --- fs ops ----------------------------------------------------------

fn body_tree(body: wire::WorkspaceResultBody) -> wire::FsTreeResult {
    match body {
        wire::WorkspaceResultBody::FsTree(result) => result,
        other => panic!("wrong body: {other:?}"),
    }
}

#[test]
fn tree_is_gitignore_aware_and_never_leaks_dot_git() {
    let root = scratch("tree");
    write(&root, "src/app.ts", "export {}\n");
    write(&root, ".gitignore", "ignored.txt\n");
    write(&root, "ignored.txt", "no\n");
    git(&root, &["init", "-q", "-b", "main"]);
    let scope = scope_for(&root);
    let result = body_tree(
        run_tree(
            &scope,
            &wire::FsTreeOp {
                op: wire::TagFsTree::FsTree,
                root: None,
                max_entries: TREE_MAX_ENTRIES,
                include_ignored: None,
            },
        )
        .expect("tree"),
    );
    let paths: Vec<&str> = result.entries.iter().map(|entry| entry.path.as_str()).collect();
    assert!(paths.contains(&"src"), "dirs render: {paths:?}");
    assert!(paths.contains(&"src/app.ts"));
    assert!(paths.contains(&".gitignore"), "hidden files list");
    assert!(!paths.iter().any(|path| path.contains(".git/") || *path == ".git"));
    assert!(!paths.contains(&"ignored.txt"), "gitignore respected");
    assert!(!result.truncated);

    let with_ignored = body_tree(
        run_tree(
            &scope,
            &wire::FsTreeOp {
                op: wire::TagFsTree::FsTree,
                root: None,
                max_entries: TREE_MAX_ENTRIES,
                include_ignored: Some(true),
            },
        )
        .expect("tree"),
    );
    let paths: Vec<&str> =
        with_ignored.entries.iter().map(|entry| entry.path.as_str()).collect();
    assert!(paths.contains(&"ignored.txt"));
    assert!(!paths.iter().any(|path| *path == ".git" || path.starts_with(".git/")));

    let capped = body_tree(
        run_tree(
            &scope,
            &wire::FsTreeOp {
                op: wire::TagFsTree::FsTree,
                root: None,
                max_entries: 1,
                include_ignored: None,
            },
        )
        .expect("tree"),
    );
    assert_eq!(capped.entries.len(), 1);
    assert!(capped.truncated);
}

#[test]
fn search_finds_spans_in_utf16_units_and_caps() {
    let root = scratch("search");
    write(&root, "src/app.ts", "const NEEDLE = 1\n\u{1F600} NEEDLE again NEEDLE\n");
    write(&root, ".gitignore", "skip.txt\n");
    write(&root, "skip.txt", "NEEDLE\n");
    git(&root, &["init", "-q", "-b", "main"]);
    let scope = scope_for(&root);
    let search = |max_results: i64| match run_search(
        &scope,
        &wire::FsSearchOp {
            op: wire::TagFsSearch::FsSearch,
            query: "NEEDLE".to_owned(),
            root: None,
            max_results,
        },
    )
    .expect("search")
    {
        wire::WorkspaceResultBody::FsSearch(result) => result,
        other => panic!("wrong body: {other:?}"),
    };
    let result = search(SEARCH_MAX_RESULTS);
    assert!(!result.truncated);
    assert_eq!(result.matches.len(), 2, "{:?}", result.matches);
    assert!(result.matches.iter().all(|found| found.path == "src/app.ts"));
    let first = &result.matches[0];
    assert_eq!(first.line, 1);
    assert_eq!(first.spans, vec![wire::FsSearchSpan { start: 6, end: 12 }]);
    let second = &result.matches[1];
    // The emoji is two UTF-16 units: JS-visible offsets, not bytes.
    assert_eq!(second.spans[0], wire::FsSearchSpan { start: 3, end: 9 });
    assert_eq!(second.spans.len(), 2);
    let capped = search(1);
    assert_eq!(capped.matches.len(), 1);
    assert!(capped.truncated);
}

// --- git ops ---------------------------------------------------------

#[cfg(unix)]
#[tokio::test]
async fn git_stdout_cleanup_handles_a_descendant_holding_the_pipe_open() {
    let mut child = tokio::process::Command::new("sh")
        .arg("-c")
        .arg("sleep 30 & printf ready; exec 1>&-; wait")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .process_group(0)
        .spawn()
        .expect("shell child");
    let mut guard = GitProcessGuard::new(&child);
    let mut stdout = child.stdout.take().expect("stdout pipe");
    let mut bytes = Vec::new();
    let read =
        tokio::time::timeout(Duration::from_millis(100), stdout.read_to_end(&mut bytes)).await;
    assert!(read.is_err(), "a descendant-owned stdout pipe must hit the bound");

    abort_git_operation(None, &mut child, &mut guard).await;
    assert!(child.id().is_none(), "cleanup must reap the direct child");
}

#[cfg(unix)]
#[tokio::test]
async fn git_abort_reaps_child_when_stderr_reader_fails() {
    use std::task::{Context, Poll};
    use tokio::io::{AsyncRead, ReadBuf};

    struct FailingReader;
    impl AsyncRead for FailingReader {
        fn poll_read(
            self: std::pin::Pin<&mut Self>,
            _cx: &mut Context<'_>,
            _buffer: &mut ReadBuf<'_>,
        ) -> Poll<std::io::Result<()>> {
            Poll::Ready(Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "synthetic stderr failure",
            )))
        }
    }

    let mut child = tokio::process::Command::new("sh")
        .arg("-c")
        .arg("sleep 30")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .process_group(0)
        .spawn()
        .expect("shell child");
    let mut guard = GitProcessGuard::new(&child);
    let drain = GitStderrDrain::start(FailingReader);

    abort_git_operation(Some(drain), &mut child, &mut guard).await;
    assert!(child.id().is_none(), "stderr failure must still reap the child");
}

#[cfg(unix)]
#[tokio::test]
async fn wait_git_deadline_reaps_a_child_after_pipes_close() {
    let mut child = tokio::process::Command::new("sh")
        .arg("-c")
        .arg("exec 1>&- 2>&-; sleep 30")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .process_group(0)
        .spawn()
        .expect("shell child");
    let result =
        wait_git_until(&mut child, std::time::Instant::now() + Duration::from_millis(50)).await;

    assert!(result.is_err(), "closed pipes must not imply child completion");
    assert!(child.id().is_none(), "wait deadline must reap the child");
}

#[tokio::test]
async fn expired_git_diff_deadline_runs_bounded_cleanup() {
    let (root, scope) = seeded_repo("git-diff-expired");
    let cancellation = CancellationToken::new();
    let refusal = run_git_diff_with_cancel_until(
        &scope,
        &wire::GitDiffOp {
            op: wire::TagGitDiff::GitDiff,
            base: None,
            paths: None,
            context_lines: None,
        },
        &cancellation,
        std::time::Instant::now() - Duration::from_millis(1),
    )
    .await
    .expect_err("expired git diff deadline");

    assert!(refusal.message.contains("deadline"));
    let _ = root;
}

fn seeded_repo(name: &str) -> (PathBuf, Scope) {
    let root = scratch(name);
    write(&root, "README.md", "# seed\n");
    write(&root, "src/app.ts", "export const NEEDLE = 42\n");
    git(&root, &["init", "-q", "-b", "main"]);
    git(&root, &["add", "."]);
    git(&root, &["commit", "-q", "-m", "seed"]);
    let scope = scope_for(&root);
    (root, scope)
}

// --- dispatch --------------------------------------------------------

fn request_json(op: Value, trust: &str) -> Value {
    serde_json::json!({
        "version": 6,
        "type": "workspace_request",
        "requestId": "req_1",
        "op": op,
        "timeoutMs": 30_000,
        "allowedRoots": Value::Null,
        "trust": trust,
        "actorId": "user_1",
        "threadId": Value::Null,
    })
}
async fn dispatch(root: &Path, request: Value) -> Value {
    let roots = vec![root.to_string_lossy().into_owned()];
    let runtime = Arc::new(SharedRuntime::new(Some(roots.clone())));
    let mut patched = request;
    patched["allowedRoots"] = serde_json::json!(roots);
    let (sink, mut critical, _watch) = OutboundSink::channels();
    let connection = Connection::new(runtime, sink);
    connection.handle_frame(patched);
    let frame = tokio::time::timeout(Duration::from_secs(15), critical.recv())
        .await
        .expect("no answer within 15s")
        .expect("channel open");
    serde_json::from_str(&frame.text).expect("valid json frame")
}
#[tokio::test]
async fn dispatch_answers_the_wire_shape_and_gates_trust() {
    let root = scratch("dispatch");
    write(&root, "file.txt", "content\n");
    let read_op = serde_json::json!({"op": "fs_read", "path": "file.txt", "maxBytes": 1000});
    let answer = dispatch(&root, request_json(read_op.clone(), "supervised")).await;
    assert_eq!(answer["type"], "workspace_result");
    assert_eq!(answer["requestId"], "req_1");
    assert_eq!(answer["ok"], true);
    assert_eq!(answer["result"]["op"], "fs_read");
    assert_eq!(answer["result"]["content"], "content\n");
    // observe trust still reads...
    let observed = dispatch(&root, request_json(read_op, "observe")).await;
    assert_eq!(observed["ok"], true);
    // ...but refuses every mutating op with the typed code.
    let write_op = serde_json::json!({
        "op": "fs_write", "path": "file.txt", "content": "no"
    });
    let refused = dispatch(&root, request_json(write_op, "observe")).await;
    assert_eq!(refused["ok"], false);
    assert_eq!(refused["code"], "trust_refused");
    let preview_op = serde_json::json!({"op": "preview_open", "targetPort": 5173});
    let refused = dispatch(&root, request_json(preview_op, "observe")).await;
    assert_eq!(refused["code"], "trust_refused");
    let delete_op = serde_json::json!({"op": "fs_delete", "path": "file.txt"});
    let refused = dispatch(&root, request_json(delete_op, "observe")).await;
    assert_eq!(refused["code"], "trust_refused");
    assert!(root.join("file.txt").exists());
}
