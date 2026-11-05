use super::*;

fn file(repo: &str, path: &str, edited: bool, at: u64) -> TouchedFile {
    TouchedFile { repo: repo.to_owned(), path: path.to_owned(), edited, at }
}

fn candidate(id: &str, files: Vec<TouchedFile>) -> Candidate {
    Candidate {
        session_id: id.to_owned(),
        root: id.to_owned(),
        name: id.to_owned(),
        harness: "codex".to_owned(),
        status: "running".to_owned(),
        updated_at: 1_000,
        files,
        ..Candidate::default()
    }
}

const REPO: &str = "github.com/manaflow-ai/cmux";

#[test]
fn a_remote_url_is_the_same_id_however_it_is_spelled() {
    for url in [
        "https://github.com/Manaflow-AI/cmux.git",
        "git@github.com:manaflow-ai/cmux.git",
        "ssh://git@github.com/manaflow-ai/cmux",
        "https://x-access-token:abc@github.com/manaflow-ai/cmux/",
    ] {
        assert_eq!(remote_id(url).as_deref(), Some(REPO), "{url}");
    }
    assert_eq!(remote_id("/srv/git/cmux.git").as_deref(), Some("/srv/git/cmux.git"));
}

#[test]
fn origin_url_reads_only_the_origin_remote() {
    let config = "[core]\n\tbare = false\n[remote \"upstream\"]\n\turl = https://x/y\n[remote \"origin\"]\n\turl = git@github.com:o/r.git\n\tfetch = +refs/heads/*\n";
    assert_eq!(origin_url(config).as_deref(), Some("git@github.com:o/r.git"));
    assert_eq!(origin_url("[remote \"upstream\"]\n url = a\n"), None);
}

#[test]
fn an_edit_names_its_locations_and_diffs_and_a_read_its_path() {
    let edit = json!({
        "kind": "edit",
        "locations": [{"path": "/r/a.rs", "_meta": {"acpmux": {"canonicalPath": "/real/r/a.rs"}}}],
        "content": [{"type": "diff", "path": "/r/b.rs", "oldText": "", "newText": "x"}],
    });
    assert_eq!(
        paths_of(&edit),
        (vec!["/real/r/a.rs".to_owned(), "/r/b.rs".to_owned()], Some(true))
    );
    let read = json!({"kind": "read", "rawInput": {"file_path": "/r/c.rs"}});
    assert_eq!(paths_of(&read), (vec!["/r/c.rs".to_owned()], Some(false)));
    // A diff makes an edit whatever the kind says (Codex's apply_patch as `other`).
    let patch = json!({"kind": "other", "content": [{"type": "diff", "path": "/r/d.rs"}]});
    assert_eq!(paths_of(&patch).1, Some(true));
    // A shell call names no file; an update with nothing says nothing.
    assert_eq!(paths_of(&json!({"kind": "execute", "rawInput": {"command": "ls"}})).0.len(), 0);
    assert_eq!(paths_of(&json!({"status": "completed"})), (vec![], None));
}

#[test]
fn merge_keeps_one_row_per_file_an_edit_stays_one_and_the_oldest_go_past_the_bound() {
    let mut files = vec![];
    merge(&mut files, file(REPO, "a", true, 5));
    merge(&mut files, file(REPO, "a", false, 9));
    assert_eq!(files, vec![file(REPO, "a", true, 9)]);
    for i in 0..MAX_FILES as u64 {
        merge(&mut files, file(REPO, &format!("f{i}"), false, 100 + i));
    }
    assert_eq!(files.len(), MAX_FILES);
    assert!(!files.iter().any(|f| f.path == "a"), "the least recent went first");
}

#[test]
fn a_session_that_edited_the_same_file_in_another_worktree_matches_first() {
    let q = Query { files: vec![file(REPO, "src/hub.rs", false, 0)], ..Query::default() };
    let editor = candidate("editor", vec![file(REPO, "src/hub.rs", true, 900)]);
    let reader = candidate("reader", vec![file(REPO, "src/hub.rs", false, 950)]);
    let elsewhere =
        candidate("elsewhere", vec![file("github.com/o/other", "src/hub.rs", true, 990)]);
    let mut rows: Vec<Value> =
        [&reader, &editor, &elsewhere].iter().filter_map(|c| row(&q, c, 1_000)).collect();
    rank(&mut rows);
    let names: Vec<&str> = rows.iter().map(|r| r["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["editor", "reader"], "another repository's same path is not the same file");
    assert_eq!(rows[0]["editedInCommon"], 1);
}

#[test]
fn the_asker_and_its_own_sub_sessions_are_not_someone_else() {
    let q = Query {
        files: vec![file(REPO, "a", false, 0)],
        exclude_root: Some("me".to_owned()),
        ..Query::default()
    };
    let mut child = candidate("child", vec![file(REPO, "a", true, 1)]);
    child.root = "me".to_owned();
    assert!(row(&q, &child, 2).is_none());
    assert!(row(&q, &candidate("me", vec![file(REPO, "a", true, 1)]), 2).is_none());
}

#[test]
fn old_touches_and_idle_old_sessions_do_not_count() {
    let q = Query { files: vec![file(REPO, "a", false, 0)], since: 500, ..Query::default() };
    let mut old = candidate("old", vec![file(REPO, "a", true, 100)]);
    old.updated_at = 100;
    old.status = "idle".to_owned();
    assert!(row(&q, &old, 1_000).is_none());
    // Its file is old but it is running now: it is listed only if something else matches.
    old.status = "running".to_owned();
    assert!(row(&q, &old, 1_000).is_none());
}

#[test]
fn the_same_feature_branch_in_another_clone_matches_but_main_does_not() {
    let mut c = candidate("other-clone", vec![]);
    c.repo = Some(REPO.to_owned());
    c.worktree = Some("/b/cmux".to_owned());
    c.default_branch = Some("main".to_owned());
    let q = |branch: &str| Query {
        repo: Some(REPO.to_owned()),
        branch: Some(branch.to_owned()),
        worktree: Some("/a/cmux".to_owned()),
        ..Query::default()
    };
    c.branch = Some("lane/who-else".to_owned());
    assert_eq!(row(&q("lane/who-else"), &c, 1_000).unwrap()["sameBranch"], true);
    c.branch = Some("main".to_owned());
    assert!(row(&q("main"), &c, 1_000).is_none());
    // The same worktree is "also working here", whatever the branch.
    c.worktree = Some("/a/cmux".to_owned());
    assert_eq!(row(&q("main"), &c, 1_000).unwrap()["sameWorktree"], true);
}

#[test]
fn a_topic_matches_most_of_its_significant_words() {
    let mut c = candidate("lane", vec![]);
    c.title = Some("acpmux: who else edits these crates".to_owned());
    let q = |t: &str| Query { topic: Some(t.to_owned()), ..Query::default() };
    let hit = row(&q("acpmux who else is working on these files"), &c, 1_000);
    assert_eq!(hit.unwrap()["topicWords"], json!(["acpmux"]), "one of one significant word");
    assert!(row(&q("composer markdown paste acpmux"), &c, 1_000).is_none(), "one of four");
}

#[test]
fn a_row_reads_as_one_line() {
    let r = json!({
        "name": "crate-split", "harness": "codex", "host": "big-red", "branch": "lane/crate-split",
        "pullRequests": ["https://github.com/o/r/pull/123"], "filesInCommon": 5,
        "files": [{"path": "a.rs", "edited": true}, {"path": "b.rs", "edited": false}],
        "agoMs": 12 * 60_000,
    });
    assert_eq!(
        row_line(&r),
        "crate-split (codex on big-red, lane/crate-split, #123): edited a.rs; read b.rs; +3 more; 12m ago"
    );
}

#[test]
fn a_worktree_and_its_clone_key_a_file_by_repository_and_path() {
    let dir = tempfile::tempdir().unwrap();
    let main = dir.path().join("main");
    let common = main.join(".git");
    std::fs::create_dir_all(common.join("worktrees/wt")).unwrap();
    std::fs::create_dir_all(common.join("refs/remotes/origin")).unwrap();
    std::fs::write(common.join("config"), "[remote \"origin\"]\n\turl = git@github.com:o/r.git\n")
        .unwrap();
    std::fs::write(common.join("refs/remotes/origin/HEAD"), "ref: refs/remotes/origin/trunk\n")
        .unwrap();
    std::fs::write(common.join("worktrees/wt/commondir"), "../..\n").unwrap();
    let wt = dir.path().join("wt");
    std::fs::create_dir_all(wt.join("src")).unwrap();
    std::fs::write(wt.join(".git"), format!("gitdir: {}\n", common.join("worktrees/wt").display()))
        .unwrap();
    let a = key_of(&main.join("src/a.rs").to_string_lossy());
    let b = key_of(&wt.join("src/a.rs").to_string_lossy());
    assert_eq!(a, ("github.com/o/r".to_owned(), "src/a.rs".to_owned()));
    assert_eq!(a, b);
    assert_eq!(repo_of(&wt).unwrap().default_branch.as_deref(), Some("trunk"));
    let outside = key_of("/nowhere/x.rs");
    assert_eq!(outside, (String::new(), "/nowhere/x.rs".to_owned()));
}
