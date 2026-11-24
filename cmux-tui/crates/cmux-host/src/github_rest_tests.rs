use super::*;

fn ok(params: Value) -> Plan {
    plan(&params).unwrap_or_else(|e| panic!("{params}: {e}"))
}

#[test]
fn a_read_query_is_one_graphql_post_with_its_variables() {
    let p =
        ok(json!({"op": "graphql", "repo": "o/r", "query": "query($n: Int!) { viewer { login } }",
        "variables": {"n": 1}, "scope": "checks"}));
    assert_eq!((p.method, p.path.as_str(), p.scope), ("POST", "graphql", Scope::Checks));
    assert_eq!(p.body.unwrap()["variables"]["n"], 1);
    assert_eq!(
        ok(json!({"op": "graphql", "repo": "o/r", "query": "{ viewer { login } }"})).scope,
        Scope::Pulls
    );
}

#[test]
fn graphql_never_carries_a_write() {
    for query in [
        "mutation { mergePullRequest(input: {}) { clientMutationId } }",
        "query { viewer { login } } mutation M { x }",
        "subscription { x }",
        "fragment F on User { login }",
    ] {
        assert!(plan(&json!({"op": "graphql", "repo": "o/r", "query": query})).is_err(), "{query}");
    }
}

#[test]
fn every_path_stays_under_the_ops_repository() {
    let job = ok(json!({"op": "get", "repo": "o/r", "path": "actions/jobs/12/logs", "tail": 512}));
    assert_eq!(
        (job.path.as_str(), job.scope, job.tail),
        ("repos/o/r/actions/jobs/12/logs", Scope::Checks, Some(512))
    );
    assert_eq!(ok(json!({"op": "get", "repo": "o/r", "path": ""})).path, "repos/o/r");
    let pulls =
        ok(json!({"op": "get", "repo": "o/r", "path": "pulls?head=me:my-branch&state=all"}));
    assert_eq!(pulls.path, "repos/o/r/pulls?head=me:my-branch&state=all");
    for path in [
        "../../user",
        "actions/jobs/1/../../secrets",
        "actions/secrets",
        "hooks",
        "collaborators",
        "contents/x",
        "actions/jobs/x",
        "pulls?q=a b",
        "pulls#x",
    ] {
        assert!(plan(&json!({"op": "get", "repo": "o/r", "path": path})).is_err(), "{path}");
    }
    for repo in ["o", "-o/r", "o/-r", "o/..", "o/r/x", "o r/x", ""] {
        assert!(plan(&json!({"op": "get", "repo": repo, "path": ""})).is_err(), "{repo}");
    }
}

#[test]
fn a_merge_is_pinned_to_the_head_and_a_known_method() {
    let head = "a".repeat(40);
    let p =
        ok(json!({"op": "pr.merge", "repo": "o/r", "number": 7, "head": head, "method": "squash"}));
    assert_eq!(
        (p.method, p.path.as_str(), p.scope),
        ("PUT", "repos/o/r/pulls/7/merge", Scope::Merge)
    );
    assert_eq!(p.body.unwrap(), json!({"sha": head, "merge_method": "squash"}));
    for bad in [
        json!({"op": "pr.merge", "repo": "o/r", "number": 7, "head": "abc", "method": "squash"}),
        json!({"op": "pr.merge", "repo": "o/r", "number": 0, "head": head}),
        json!({"op": "pr.merge", "repo": "o/r", "number": 7, "head": head, "method": "admin"}),
    ] {
        assert!(plan(&bad).is_err(), "{bad}");
    }
}

#[test]
fn a_rerun_asks_actions_write_and_nothing_else_writes_beyond_its_op() {
    let p = ok(json!({"op": "run.rerunFailed", "repo": "o/r", "run": 9}));
    assert_eq!(p.path, "repos/o/r/actions/runs/9/rerun-failed-jobs");
    assert_eq!(p.scope.permissions()["actions"], "write");
    for scope in [Scope::Pulls, Scope::Checks] {
        let perms = scope.permissions();
        assert!(perms.as_object().unwrap().values().all(|v| v == "read"), "{perms}");
        assert!(!scope.writes());
    }
    for scope in [Scope::Pulls, Scope::Checks, Scope::Merge, Scope::Rerun] {
        let perms = scope.permissions();
        assert!(
            perms.get("workflows").is_none() && perms.get("administration").is_none(),
            "{perms}"
        );
    }
    assert!(plan(&json!({"op": "repo.delete", "repo": "o/r"})).is_err());
}

#[test]
fn the_gh_fallback_is_the_same_call() {
    let p = ok(json!({"op": "get", "repo": "o/r", "path": "actions/jobs/3/logs", "tail": 10}));
    assert_eq!(
        gh_args(&p),
        [
            "api",
            "--hostname",
            "github.com",
            "--method",
            "GET",
            "-H",
            "Accept: application/vnd.github+json",
            "-H",
            "Range: bytes=-10",
            "repos/o/r/actions/jobs/3/logs"
        ]
    );
    let m = ok(json!({"op": "pr.merge", "repo": "o/r", "number": 1, "head": "b".repeat(40)}));
    assert_eq!(gh_args(&m).last().map(String::as_str), Some("-"));
    assert_eq!(gh_status("gh: Not Found (HTTP 404)\n"), Some(404));
    assert_eq!(gh_status("no status"), None);
}

#[test]
fn a_tail_keeps_the_end_and_a_refusal_keeps_githubs_words() {
    assert_eq!(keep_tail(b"abcdef".to_vec(), Some(2)), b"ef");
    assert_eq!(keep_tail(b"ab".to_vec(), Some(5)), b"ab");
    assert_eq!(
        refusal_message(r#"{"message":"Head branch was modified"}"#).as_deref(),
        Some("Head branch was modified")
    );
    assert_eq!(refusal_message(r#"{"errors":[{"message":"nope"}]}"#).as_deref(), Some("nope"));
    assert_eq!(refusal_message("not json"), None);
}
