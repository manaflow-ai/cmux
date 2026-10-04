//! `git.branches`: the branch listing and base suggestions over the wire.

use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::json;

use super::{call, commit_all, failure, git, mux, ok, repository, write};

#[test]
fn branches_lists_local_then_remote_with_the_suggested_bases() {
    let mux = mux();
    let origin = repository("branches-origin");
    write(&origin, "a.txt", b"one\n");
    let root = commit_all(&origin, "first");
    git(&origin, &["branch", "release"]);
    let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let clone = std::env::temp_dir().join(format!("cmux-git-ops-branches-{nanos}"));
    let (from, to) = (origin.to_string_lossy().into_owned(), clone.to_string_lossy().into_owned());
    git(&origin, &["clone", "-q", from.as_str(), to.as_str()]);
    let clone = fs::canonicalize(clone).unwrap();
    git(&clone, &["checkout", "-q", "-b", "feat", "--track", "origin/release"]);
    write(&clone, "b.txt", b"two\n");
    let head = commit_all(&clone, "ahead");

    let result = ok(call(&mux, "git.branches", json!({"path":clone.to_string_lossy()})));
    assert_eq!(result["root"], json!(clone.to_string_lossy()));
    assert_eq!(result["current"], "feat");
    assert_eq!(result["detached"], false);
    assert_eq!(result["truncated"], false);
    let names: Vec<&str> = result["branches"]
        .as_array()
        .unwrap()
        .iter()
        .map(|b| b["name"].as_str().unwrap())
        .collect();
    assert_eq!(names[0], "feat");
    assert_eq!(&names[1..], ["main", "origin/main", "origin/release"]);
    assert_eq!(
        result["branches"][0],
        json!({
            "name":"feat",
            "ref":"refs/heads/feat",
            "kind":"local",
            "commit":head,
            "current":true,
            "upstream":"origin/release",
            "ahead":1,
            "behind":0,
            "committed_at":result["branches"][0]["committed_at"],
        })
    );
    assert!(result["branches"][0]["committed_at"].is_u64());
    assert_eq!(result["branches"][2]["kind"], "remote");
    assert_eq!(result["branches"][2]["commit"], root);
    assert!(result["branches"][2].get("upstream").is_none());
    assert_eq!(
        result["suggested_bases"],
        json!([
            {"name":"origin/main","ref":"refs/remotes/origin/main","reason":"default_branch"},
            {"name":"origin/release","ref":"refs/remotes/origin/release","reason":"upstream"},
        ])
    );

    let limited = ok(call(&mux, "git.branches", json!({"path":clone.to_string_lossy(),"limit":1})));
    assert_eq!(limited["branches"].as_array().unwrap().len(), 1);
    assert_eq!(limited["truncated"], true);

    git(&clone, &["checkout", "-q", "--detach"]);
    let detached = ok(call(&mux, "git.branches", json!({"path":clone.to_string_lossy()})));
    assert_eq!(detached["detached"], true);
    assert!(detached.get("current").is_none());
}

#[test]
fn branches_rejects_a_limit_out_of_range() {
    let mux = mux();
    let repository = repository("branches-limit");
    let path = repository.to_string_lossy();
    for limit in [0, 1001] {
        let envelope = call(&mux, "git.branches", json!({"path":path,"limit":limit}));
        assert_eq!(failure(&envelope).0, "validation.invalid", "limit {limit}");
    }
}
