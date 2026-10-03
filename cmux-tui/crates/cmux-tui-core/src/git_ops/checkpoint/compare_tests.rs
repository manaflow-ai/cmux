//! `git.checkpoint.diff`: a turn's changes between two checkpoints, or from
//! one checkpoint to the working tree now.

use std::fs;
use std::path::Path;
use std::sync::Arc;

use serde_json::{Value, json};

use super::{commit_all, create, failure, observed, ok, read, repository, session, write};
use crate::Mux;

fn checkpoint(mux: &Arc<Mux>, repository: &Path, key: &str) -> String {
    let created =
        ok(create(mux, repository, json!({"include_untracked":"eligible","reason":"turn"}), key));
    created["value"]["checkpoint_id"].as_str().unwrap().to_string()
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

fn row(path: &str, status: &str, additions: u64, deletions: u64) -> (String, String, u64, u64) {
    (path.to_string(), status.to_string(), additions, deletions)
}

#[test]
fn a_turn_between_two_checkpoints_lists_only_what_the_turn_changed() {
    let (mux, _state) = session("diff-two");
    let repository = repository("diff-two");
    write(&repository, "a.txt", b"one\ntwo\n");
    write(&repository, "gone.txt", b"bye\n");
    commit_all(&repository, "first");
    // Work from before the turn: a change and an untracked file.
    write(&repository, "a.txt", b"one\nTWO\n");
    write(&repository, "notes.md", b"draft\n");
    let start = checkpoint(&mux, &repository, "turn-start");
    // The turn edits the untracked file, adds one, deletes a tracked one.
    write(&repository, "notes.md", b"draft\nmore\n");
    write(&repository, "new.rs", b"fn main() {}\n");
    fs::remove_file(repository.join("gone.txt")).unwrap();
    let end = checkpoint(&mux, &repository, "turn-end");

    let result = ok(read(
        &mux,
        "git.checkpoint.diff",
        &repository,
        json!({"from": start, "to": end, "include_patch": true}),
    ));
    assert_eq!(result["from"], start.as_str());
    assert_eq!(result["to"], end.as_str());
    assert_eq!(
        summary(&result),
        vec![
            row("gone.txt", "deleted", 0, 1),
            row("new.rs", "added", 1, 0),
            row("notes.md", "modified", 1, 0),
        ]
    );
    let notes =
        result["files"].as_array().unwrap().iter().find(|f| f["path"] == "notes.md").unwrap();
    assert_eq!(notes["patch"], "@@ -1 +1,2 @@\n draft\n+more\n");
}

#[test]
fn without_to_it_compares_with_the_working_tree_and_changes_nothing() {
    let (mux, _state) = session("diff-live");
    let repository = repository("diff-live");
    write(&repository, "a.txt", b"one\n");
    commit_all(&repository, "first");
    write(&repository, "scratch.txt", b"same\n");
    let start = checkpoint(&mux, &repository, "live-start");
    write(&repository, "a.txt", b"one\ntwo\n");
    write(&repository, "fresh.txt", b"x\ny\n");
    let before = observed(&repository);

    let result = ok(read(&mux, "git.checkpoint.diff", &repository, json!({"from": start})));
    assert!(result.get("to").is_none());
    // scratch.txt is untracked at both ends and unchanged: not listed.
    assert_eq!(
        summary(&result),
        vec![row("a.txt", "modified", 1, 0), row("fresh.txt", "added", 2, 0)]
    );
    assert_eq!(observed(&repository), before, "a diff never touches HEAD, the index or the tree");
}

#[test]
fn an_unknown_checkpoint_is_not_found() {
    let (mux, _state) = session("diff-missing");
    let repository = repository("diff-missing");
    write(&repository, "a.txt", b"one\n");
    commit_all(&repository, "first");
    checkpoint(&mux, &repository, "missing-known");
    let missing = read(
        &mux,
        "git.checkpoint.diff",
        &repository,
        json!({"from": "ckpt_00000000000000000000000000000000"}),
    );
    assert_eq!(failure(&missing).0, "resource.not_found");
}
