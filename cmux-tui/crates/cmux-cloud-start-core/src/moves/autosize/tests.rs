//! The chat's machine pick (moved from the app's `CloudWorkPickTests`; the git runs stay there).

use super::*;

#[test]
fn the_task_kind_rule_is_whole_words_and_testing_wins() {
    assert_eq!(task_kind(None), TaskKind::Chat);
    assert_eq!(task_kind(Some("")), TaskKind::Chat);
    assert_eq!(task_kind(Some("Explain the latest changes")), TaskKind::Chat);
    assert_eq!(task_kind(Some("Compile the app")), TaskKind::Build);
    assert_eq!(task_kind(Some("build it, then run the e2e suite")), TaskKind::Test);
    assert_eq!(task_kind(Some("Fix failing tests in Sources/")), TaskKind::Test);
    assert_eq!(task_kind(Some("contest rebuilt")), TaskKind::Chat);
    assert_eq!(task_kind(Some("run the tests and fix what fails")), TaskKind::Test);
}

#[test]
fn a_remote_key_never_keeps_a_login_and_a_local_remote_has_none() {
    assert_eq!(
        repo_key("https://x-token:ghp_secret@github.com/o/r.git").as_deref(),
        Some("github.com/o/r")
    );
    assert_eq!(repo_key("ghp_secret@github.com:o/r").as_deref(), Some("github.com/o/r"));
    assert_eq!(
        repo_key("https://github.com/Manaflow-AI/cmux.git").as_deref(),
        Some("github.com/manaflow-ai/cmux")
    );
    assert_eq!(repo_key("git@github.com:o/tool.git").as_deref(), Some("github.com/o/tool"));
    assert_eq!(
        repo_key("ssh://git@gitlab.example.com:2222/group/sub/web.git").as_deref(),
        Some("gitlab.example.com/group/sub/web")
    );
    assert_eq!(repo_key("/srv/git/r.git"), None);
    assert_eq!(repo_key("file:///srv/git/r.git"), None);
    assert_eq!(repo_key("https://github.com/only"), None);
    assert_eq!(repo_key("https://github.com/o/r with space"), None);
    assert_eq!(repo_key("octo/paint"), None, "a relative path remote has no key");
    assert_eq!(repo_key("../paint"), None);
}

#[test]
fn pushed_reads_the_upstream_track() {
    assert!(is_pushed("main\0"));
    assert!(is_pushed("origin/main\0[behind 2]"));
    assert!(!is_pushed("origin/main\0[ahead 1]"));
    assert!(!is_pushed("origin/main\0[ahead 1, behind 2]"));
    assert!(!is_pushed("origin/main\0[gone]"));
    assert!(!is_pushed("\0"));
    assert_eq!(objects_mb("count: 3\nsize: 12\nin-pack: 9\nsize-pack: 2048\n"), Some(3));
    assert_eq!(objects_mb("size: 0\n"), Some(1), "at least 1");
    assert_eq!(objects_mb("garbage"), None);
}

#[test]
fn the_repo_is_the_tracked_remotes_and_the_clone_ref_the_branch_the_remote_has() {
    assert_eq!(remote_name("refs/heads/x\0\0upstream").as_deref(), Some("upstream"));
    assert_eq!(remote_name("refs/heads/x\0"), None);
    assert_eq!(remote_name("refs/heads/x\0\0-c"), None);
    assert_eq!(
        remote_branch("refs/heads/topic/elsewhere\0\0origin").as_deref(),
        Some("topic/elsewhere")
    );
    assert_eq!(remote_branch("refs/remotes/team/origin/feature\0"), None);
}

fn facts() -> Facts {
    Facts {
        folder: "/w/work/Sources".into(),
        top: Some("/w/work".into()),
        branch: Some("feature/pick".into()),
        upstream: Some("refs/heads/feature/pick\0\0origin".into()),
        remote: Some("https://github.com/Manaflow-AI/cmux.git".into()),
        objects: Some("size: 4\nsize-pack: 100\n".into()),
        names: vec![".git".into(), "Package.swift".into(), "Sources".into(), ".cmux".into()],
        machine_config: true,
        harness: Some("codex".into()),
        text: None,
    }
}

#[test]
fn a_swift_packages_pick_names_its_repo_branch_and_root_files() {
    let pick = work_pick(&facts());
    assert_eq!(pick.root, "/w/work");
    assert_eq!(pick.repo_key.as_deref(), Some("github.com/manaflow-ai/cmux"));
    assert_eq!(pick.clone_ref.as_deref(), Some("feature/pick"));
    let repo = pick.repo.clone().expect("a GitHub remote names its repo");
    assert_eq!((repo.owner.as_str(), repo.name.as_str()), ("Manaflow-AI", "cmux"));
    assert_eq!(repo.r#ref.as_deref(), Some("feature/pick"));
    assert!(repo.is_github());
    assert!(pick.pushed && pick.has_machine_config && pick.needs_codex_broker);
    assert_eq!(pick.root_files, [".cmux", "Package.swift", "Sources"]);
    assert_eq!(pick.size_mb, Some(1));
    assert_eq!(pick.task_kind, TaskKind::Chat);
    let body = Autosize {
        task_kind: pick.task_kind,
        repo_key: pick.repo_key,
        repo_size_mb: pick.size_mb,
        root_files: pick.root_files,
    }
    .body();
    assert_eq!(
        body,
        json!({"taskKind": "chat", "repo": {"key": "github.com/manaflow-ai/cmux", "sizeMb": 1,
        "rootFiles": [".cmux", "Package.swift", "Sources"]}})
    );
}

#[test]
fn an_unpushed_branch_is_picked_without_its_ref() {
    let pick = work_pick(&Facts {
        upstream: Some("refs/heads/feature/pick\0[ahead 1]\0origin".into()),
        ..facts()
    });
    assert!(!pick.pushed);
    assert_eq!(pick.clone_ref, None, "the machine clones the default branch");
    assert_eq!(pick.repo.and_then(|repo| repo.r#ref), None);
    let none = work_pick(&Facts { upstream: None, ..facts() });
    assert!(!none.pushed && none.clone_ref.is_none());
}

#[test]
fn a_folder_outside_git_is_picked_as_itself_with_no_repo() {
    let pick = work_pick(&Facts {
        folder: "/plain".into(),
        names: vec!["package.json".into()],
        ..Facts::default()
    });
    assert_eq!(pick.root, "/plain");
    assert_eq!((pick.repo_key, pick.branch, pick.size_mb), (None, None, None));
    assert!(!pick.pushed);
    let body = Autosize { root_files: pick.root_files, ..Autosize::default() }.body();
    assert_eq!(
        body,
        json!({"taskKind": "chat", "repo": {"rootFiles": ["package.json"]}}),
        "root files alone still name the toolchain"
    );
    assert_eq!(Autosize::default().body(), json!({"taskKind": "chat"}));
}

#[test]
fn the_root_files_fit_the_servers_limits() {
    let mut names: Vec<String> = (0..600).map(|index| format!("f{index:03}")).collect();
    names.push("x".repeat(256));
    let files = root_files(&names);
    assert_eq!(files.len(), MAX_ROOT_FILES);
    assert_eq!(files[0], "f000");
    assert!(files.iter().all(|name| name.len() <= MAX_NAME_LENGTH));
}

#[test]
fn a_branch_name_the_repo_step_cant_quote_clones_the_default_branch() {
    for branch in ["it's", "x$(touch pwned)", "two words", "-rf", "a..b", "a;b", "a`b`"] {
        let pick = work_pick(&Facts {
            branch: Some(branch.into()),
            upstream: Some(format!("refs/heads/{branch}\0\0origin")),
            ..facts()
        });
        assert!(pick.pushed, "{branch}");
        assert_eq!(pick.clone_ref, None, "{branch}");
        let repo = pick.repo.expect("the repo is still GitHub's");
        assert_eq!(repo.r#ref, None, "{branch}");
    }
}

#[test]
fn only_a_github_remote_names_a_repo_and_a_clone_ref() {
    // A local path, a remote on another host, and a remote git could not read.
    for remote in
        [Some("../paint"), Some("octo/paint"), Some("https://gitlab.com/octo/paint.git"), None]
    {
        let pick = work_pick(&Facts { remote: remote.map(str::to_owned), ..facts() });
        assert_eq!(pick.repo, None, "{remote:?}");
        assert_eq!(pick.clone_ref, None, "{remote:?}");
        assert!(pick.pushed, "{remote:?}: pushed reads the upstream alone");
    }
    let gitlab =
        work_pick(&Facts { remote: Some("https://gitlab.com/octo/paint.git".into()), ..facts() });
    assert_eq!(gitlab.repo_key.as_deref(), Some("gitlab.com/octo/paint"), "it still keys the size");
    let ssh = work_pick(&Facts { remote: Some("git@github.com:octo/paint.git".into()), ..facts() });
    assert_eq!(ssh.repo.map(|repo| (repo.owner, repo.name)), Some(("octo".into(), "paint".into())));
}
