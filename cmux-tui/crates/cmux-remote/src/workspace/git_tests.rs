use std::path::Path;
use std::process::Command;
use std::sync::Arc;

use cmux_remote_protocol::WorkspaceId;
use tempfile::tempdir;

use super::super::{ClientScope, query::WorkspaceQueryService};
use super::*;

fn git(root: &Path, arguments: &[&str]) {
    let status = Command::new("git").arg("-C").arg(root).args(arguments).status().unwrap();
    assert!(status.success(), "git {arguments:?} failed with {status}");
}

fn write_test_file(root: &Path, path: &str, contents: &[u8]) {
    let path = root.join(path);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).unwrap();
    }
    std::fs::write(path, contents).unwrap();
}

async fn structured_diff(root: &WorkspaceRoot, staged: bool) -> StructuredDiffV1 {
    let queries = WorkspaceQueryService::default();
    let owner = ClientScope::new("test", cmux_remote_protocol::SessionId([1; 16]));
    let context = WorkspaceQueryContext::new(&queries, &owner, root);
    let response = diff(&context, &[], staged, 3, DiffFormat::StructuredV1, None, None)
        .await
        .unwrap()
        .commit();
    let WorkspaceResponse::StructuredDiff { diff, .. } = response else { panic!() };
    diff
}

async fn git_root() -> (tempfile::TempDir, Arc<WorkspaceRoot>) {
    let directory = tempdir().unwrap();
    git(directory.path(), &["init", "-q"]);
    git(directory.path(), &["config", "user.email", "test@example.com"]);
    git(directory.path(), &["config", "user.name", "Test"]);
    git(directory.path(), &["config", "core.quotePath", "true"]);
    std::fs::write(directory.path().join("tracked.txt"), "before\n").unwrap();
    git(directory.path(), &["add", "tracked.txt"]);
    git(directory.path(), &["commit", "-qm", "initial"]);
    let root = WorkspaceRoot::open(WorkspaceId("git".into()), directory.path().to_str().unwrap())
        .await
        .unwrap();
    (directory, root)
}

/// A workspace opened at a subdirectory of a repository never diffs files
/// outside that directory: Git pathspec magic such as `:(top)` would name
/// paths from the repository top, and a diff without paths would cover
/// the whole repository.
#[tokio::test]
async fn sec_audit_diff_stays_inside_a_subdirectory_workspace() {
    let directory = tempdir().unwrap();
    git(directory.path(), &["init", "-q"]);
    git(directory.path(), &["config", "user.email", "test@example.com"]);
    git(directory.path(), &["config", "user.name", "Test"]);
    write_test_file(directory.path(), "outside.txt", b"secret before\n");
    write_test_file(directory.path(), "sub/inside.txt", b"before\n");
    git(directory.path(), &["add", "."]);
    git(directory.path(), &["commit", "-qm", "initial"]);
    write_test_file(directory.path(), "outside.txt", b"secret after\n");
    write_test_file(directory.path(), "sub/inside.txt", b"after\n");
    let sub = directory.path().join("sub");
    let root = WorkspaceRoot::open(WorkspaceId("sub".into()), sub.to_str().unwrap()).await.unwrap();
    let queries = WorkspaceQueryService::default();
    let owner = ClientScope::new("test", cmux_remote_protocol::SessionId([1; 16]));
    let context = WorkspaceQueryContext::new(&queries, &owner, &root);
    for paths in [vec![":(top)outside.txt".to_string()], vec![]] {
        let text = match diff(&context, &paths, false, 3, DiffFormat::Unified, None, None).await {
            Ok(prepared) => match prepared.commit() {
                WorkspaceResponse::Diff { data, .. } => {
                    String::from_utf8_lossy(&data.decode().unwrap()).into_owned()
                }
                other => format!("{other:?}"),
            },
            Err(error) => format!("{error:?}"),
        };
        assert!(!text.contains("secret"), "{paths:?} leaked the parent repository: {text}");
    }
}

#[tokio::test]
async fn status_and_structured_diff_are_bounded_and_typed() {
    let (_directory, root) = git_root().await;
    let queries = WorkspaceQueryService::default();
    let owner = ClientScope::new("test", cmux_remote_protocol::SessionId([1; 16]));
    let context = WorkspaceQueryContext::new(&queries, &owner, &root);
    tokio::fs::write(root.canonical_root().join("tracked.txt"), b"after\n").await.unwrap();
    let response = status(&root).await.unwrap();
    let WorkspaceResponse::GitStatus { status } = response else { panic!() };
    assert_eq!(status.changes[0].path, "tracked.txt");
    assert_eq!(status.changes[0].worktree_status, 'M');

    let response =
        diff(&context, &[], false, 3, DiffFormat::Structured, None, None).await.unwrap().commit();
    let WorkspaceResponse::Diff { data, .. } = response else { panic!() };
    let decoded = data.decode().unwrap();
    let json: serde_json::Value = serde_json::from_slice(&decoded).unwrap();
    assert_eq!(json["files"][0]["new_path"], "tracked.txt");
    assert!(json["files"][0]["hunks"][0]["lines"].is_array());
    assert!(json["files"][0].get("metadata").is_none());

    let typed =
        diff(&context, &[], false, 3, DiffFormat::StructuredV1, None, None).await.unwrap().commit();
    let WorkspaceResponse::StructuredDiff { diff, .. } = typed else { panic!() };
    assert_eq!(diff.version, 1);
    assert_eq!(diff.files[0].new_path.as_deref(), Some("tracked.txt"));
    assert!(!diff.files[0].metadata.is_empty());
}

#[cfg(unix)]
#[tokio::test]
async fn status_uses_the_pinned_root_after_its_path_is_replaced() {
    let parent = tempdir().unwrap();
    let root_path = parent.path().join("workspace");
    let pinned_path = parent.path().join("pinned-workspace");
    std::fs::create_dir(&root_path).unwrap();
    git(&root_path, &["init", "-q"]);
    git(&root_path, &["config", "user.email", "test@example.com"]);
    git(&root_path, &["config", "user.name", "Test"]);
    std::fs::write(root_path.join("tracked.txt"), "before\n").unwrap();
    git(&root_path, &["add", "tracked.txt"]);
    git(&root_path, &["commit", "-qm", "initial"]);
    let root = WorkspaceRoot::open(WorkspaceId("pinned-git".into()), root_path.to_str().unwrap())
        .await
        .unwrap();

    std::fs::rename(&root_path, &pinned_path).unwrap();
    std::fs::create_dir(&root_path).unwrap();
    git(&root_path, &["init", "-q"]);
    std::fs::write(root_path.join("replacement.txt"), "replacement\n").unwrap();
    std::fs::write(pinned_path.join("tracked.txt"), "after\n").unwrap();

    let response = status(&root).await.unwrap();
    let WorkspaceResponse::GitStatus { status } = response else { panic!() };
    let paths = status.changes.iter().map(|change| change.path.as_str()).collect::<Vec<_>>();
    assert_eq!(paths, vec!["tracked.txt"]);
}

#[tokio::test]
async fn status_ignores_repository_selecting_environment() {
    const CHILD: &str = "CMUX_GIT_ENVIRONMENT_TEST_CHILD";
    const ROOT: &str = "CMUX_GIT_ENVIRONMENT_TEST_ROOT";
    if std::env::var_os(CHILD).is_some() {
        let root_path = std::env::var_os(ROOT).expect("isolated Git test root is present");
        let root = WorkspaceRoot::open(
            WorkspaceId("git-environment".into()),
            Path::new(&root_path).to_str().unwrap(),
        )
        .await
        .unwrap();
        let response = status(&root).await.unwrap();
        let WorkspaceResponse::GitStatus { status } = response else { panic!() };
        let paths = status.changes.iter().map(|change| change.path.as_str()).collect::<Vec<_>>();
        assert!(paths.contains(&"target-only.txt"), "target status missing: {paths:?}");
        assert!(!paths.contains(&"decoy-only.txt"), "decoy status escaped its workspace");
        return;
    }

    let (target, _target_root) = git_root().await;
    let (decoy, _decoy_root) = git_root().await;
    std::fs::write(target.path().join("target-only.txt"), "target\n").unwrap();
    std::fs::write(decoy.path().join("decoy-only.txt"), "decoy\n").unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .arg("--exact")
        .arg("workspace::git::tests::status_ignores_repository_selecting_environment")
        .arg("--nocapture")
        .env(CHILD, "1")
        .env(ROOT, target.path())
        .env("GIT_DIR", decoy.path().join(".git"))
        .env("GIT_WORK_TREE", decoy.path())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "isolated Git environment test failed:\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[tokio::test]
async fn structured_diff_decodes_modified_git_paths() {
    let (_directory, root) = git_root().await;
    let paths =
        ["quote\"name.bin", "tab\tname.bin", "\u{65e5}\u{672c}\u{8a9e}.bin", "folder b/name.bin"];
    for (index, path) in paths.iter().enumerate() {
        write_test_file(root.canonical_root(), path, format!("before {index}\0").as_bytes());
    }
    git(root.canonical_root(), &["add", "."]);
    git(root.canonical_root(), &["commit", "-qm", "special paths"]);
    for (index, path) in paths.iter().enumerate() {
        write_test_file(root.canonical_root(), path, format!("after {index}\0").as_bytes());
    }

    let parsed = structured_diff(&root, false).await;
    assert_eq!(parsed.files.len(), paths.len());
    for path in paths {
        let file = parsed
            .files
            .iter()
            .find(|file| file.new_path.as_deref() == Some(path))
            .unwrap_or_else(|| panic!("missing modified path {path:?}"));
        assert_eq!(file.old_path.as_deref(), Some(path));
        assert!(file.hunks.is_empty());
    }
}

#[tokio::test]
async fn structured_diff_decodes_renamed_git_paths() {
    let (_directory, root) = git_root().await;
    let paths = [
        ("old\"quote.txt", "new\"quote.txt"),
        ("old\ttab.txt", "new\ttab.txt"),
        ("\u{53e4}\u{3044}.txt", "\u{65b0}\u{3057}\u{3044}.txt"),
        ("old b/path.txt", "new b/path.txt"),
    ];
    for (index, (old, _new)) in paths.iter().enumerate() {
        write_test_file(
            root.canonical_root(),
            old,
            format!("unique contents {index}\n").as_bytes(),
        );
    }
    git(root.canonical_root(), &["add", "."]);
    git(root.canonical_root(), &["commit", "-qm", "rename sources"]);
    for (old, new) in paths {
        let new_path = root.canonical_root().join(new);
        if let Some(parent) = new_path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::rename(root.canonical_root().join(old), new_path).unwrap();
    }
    git(root.canonical_root(), &["add", "-A"]);

    let parsed = structured_diff(&root, true).await;
    assert_eq!(parsed.files.len(), paths.len());
    for (old, new) in paths {
        let file = parsed
            .files
            .iter()
            .find(|file| {
                file.old_path.as_deref() == Some(old) && file.new_path.as_deref() == Some(new)
            })
            .unwrap_or_else(|| panic!("missing rename {old:?} -> {new:?}"));
        assert!(file.hunks.is_empty());
    }
}
