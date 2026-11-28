//! `cmux.git.status` and `cmux.git.diff` over the provider path, on a real
//! repository.

use std::path::Path;
use std::process::Command;
use std::sync::Arc;

use cmux_pane_protocol::git::{
    self, CommandGit, GitDiff, GitDiffOp, GitDiffParams, GitStatus, GitStatusOp, GitStatusParams,
};
use cmux_pane_protocol::op::Op;
use cmux_pane_protocol::provider::Provider;
use cmux_pane_protocol::token::{Claims, now};

fn git(directory: &Path, arguments: &[&str]) {
    let status = Command::new("git")
        .args([
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@example.com",
            "-c",
            "init.defaultBranch=main",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(arguments)
        .current_dir(directory)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .status()
        .unwrap();
    assert!(status.success(), "git {arguments:?}");
}

fn git_provider(roots: &[&str]) -> (Provider, Arc<Claims>) {
    let mut provider = Provider::new("cmux.git");
    git::register(&mut provider, Arc::new(CommandGit));
    let claims = Claims {
        sub: "s".into(),
        page: None,
        app: "cmux.agent".into(),
        ns: vec!["cmux.git".into()],
        scopes: vec!["git:read".into()],
        roots: roots.iter().map(|root| (*root).to_owned()).collect(),
        origin: None,
        aud: "cmux.git".into(),
        exp: now() + 60,
        iat: now(),
    };
    (provider, Arc::new(claims))
}

async fn call<O: Op>(
    provider: &Provider,
    claims: &Arc<Claims>,
    params: &O::Params,
) -> Result<O::Result, String> {
    let value = provider
        .dispatch(claims, O::NAME, serde_json::to_value(params).unwrap())
        .await
        .map_err(|error| error.code)?;
    Ok(serde_json::from_value(value).unwrap())
}

#[tokio::test]
async fn status_and_diff_of_a_real_repository() {
    let directory = tempfile::tempdir().unwrap();
    let root = directory.path().canonicalize().unwrap();
    let cwd = root.to_string_lossy().into_owned();
    let (provider, claims) = git_provider(&[&cwd]);

    let before = call::<GitDiffOp>(
        &provider,
        &claims,
        &GitDiffParams { cwd: cwd.clone(), base: None, include_patch: false },
    )
    .await;
    assert_eq!(before, Err(git::NOT_A_REPO.to_owned()));

    git(&root, &["init", "-q"]);
    std::fs::write(root.join("a.txt"), "one\n").unwrap();
    // Before the first commit, diff compares with the empty tree.
    git(&root, &["add", "a.txt"]);
    let unborn: GitDiff = call::<GitDiffOp>(
        &provider,
        &claims,
        &GitDiffParams { cwd: cwd.clone(), base: None, include_patch: false },
    )
    .await
    .unwrap();
    assert_eq!(unborn.files.len(), 1);
    git(&root, &["commit", "-q", "-m", "one"]);

    std::fs::write(root.join("a.txt"), "one\ntwo\n").unwrap();
    std::fs::write(root.join("new file.txt"), "x\n").unwrap();
    let status: GitStatus =
        call::<GitStatusOp>(&provider, &claims, &GitStatusParams { cwd: cwd.clone() })
            .await
            .unwrap();
    assert_eq!(status.branch.as_deref(), Some("main"));
    let files: Vec<_> = status
        .files
        .iter()
        .map(|f| (f.path.as_str(), f.index.as_str(), f.worktree.as_str()))
        .collect();
    assert_eq!(files, [("a.txt", " ", "M"), ("new file.txt", "?", "?")]);

    let diff: GitDiff = call::<GitDiffOp>(
        &provider,
        &claims,
        &GitDiffParams { cwd: cwd.clone(), base: None, include_patch: true },
    )
    .await
    .unwrap();
    assert_eq!(diff.files.len(), 1);
    assert_eq!(
        (diff.files[0].path.as_str(), diff.files[0].additions, diff.files[0].deletions),
        ("a.txt", 1, 0)
    );
    assert!(diff.files[0].patch.as_deref().unwrap().contains("+two"));

    let bad = call::<GitDiffOp>(
        &provider,
        &claims,
        &GitDiffParams {
            cwd: cwd.clone(),
            base: Some("--output=/tmp/x".into()),
            include_patch: false,
        },
    )
    .await;
    assert_eq!(bad, Err(git::BAD_REF.to_owned()));
    let missing = call::<GitDiffOp>(
        &provider,
        &claims,
        &GitDiffParams { cwd, base: Some("nope".into()), include_patch: false },
    )
    .await;
    assert_eq!(missing, Err(git::BAD_REF.to_owned()));
}
