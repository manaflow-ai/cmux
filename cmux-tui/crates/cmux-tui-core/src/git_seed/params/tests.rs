use super::*;

#[test]
fn urls_are_exactly_github_https_matching_repo() {
    assert!(check_url("https://github.com/o/n.git", "o/n").is_ok());
    assert!(check_url("https://github.com/manaflow-ai/cmux.git", "manaflow-ai/cmux").is_ok());
    for (url, repo) in [
        ("https://github.com/o/n.git", "o/m"),
        ("https://github.com/o/n", "o/n"),
        ("http://github.com/o/n.git", "o/n"),
        ("https://x@github.com/o/n.git", "o/n"),
        ("https://github.com.evil.com/o/n.git", "o/n"),
        ("https://github.com/o/n/x.git", "o/n/x"),
        ("https://github.com/-o/n.git", "-o/n"),
        ("https://github.com/./n.git", "./n"),
        ("https://github.com/o/n?.git", "o/n?"),
        ("git@github.com:o/n.git", "o/n"),
        ("file:///tmp/o/n.git", "o/n"),
    ] {
        assert!(check_url(url, repo).is_err(), "{url} {repo}");
    }
}

#[test]
fn shas_are_full_lowercase_hex() {
    assert!(check_sha("x", &"a".repeat(40)).is_ok());
    assert!(check_sha("x", &"0".repeat(64)).is_ok());
    for sha in ["", "abc", &"A".repeat(40), &"g".repeat(40), &"a".repeat(41), "HEAD"] {
        assert!(check_sha("x", sha).is_err(), "{sha}");
    }
}

#[test]
fn clone_refs_are_a_safe_subset() {
    for git_ref in ["main", "feature/x", "v1.2.3", &"a".repeat(40)] {
        assert!(check_clone_ref(git_ref).is_ok(), "{git_ref}");
    }
    for git_ref in ["", "HEAD", "-x", "a..b", "a b", "x.lock", "a~1", "/a", "a/", ".a", "a//b"] {
        assert!(check_clone_ref(git_ref).is_err(), "{git_ref}");
    }
}

#[test]
fn a_start_is_a_seed_or_a_clone_never_half_of_each() {
    let clone = StartParams::parse(&serde_json::json!({
        "folder": "/h/p", "url": "https://github.com/o/n.git", "repo": "o/n", "ref": "v1",
    }))
    .unwrap();
    assert_eq!(clone.clone_only, Some(Some("v1".into())));
    let default = StartParams::parse(&serde_json::json!({
            "folder": "/h/p", "url": "https://github.com/o/n.git", "repo": "o/n",
            "bundle": null, "head": null, "index": null, "work": null, "stash": null, "since": null, "base": null,
        }))
        .unwrap();
    assert_eq!(default.clone_only, Some(None));
    let half = StartParams::parse(&serde_json::json!({
        "folder": "/h/p", "url": "https://github.com/o/n.git", "repo": "o/n", "bundle": "/h/b",
    }));
    assert_eq!(half.unwrap_err().code, "seed.bad_request");
}

#[test]
fn a_head_first_start_is_only_a_whole_seed_with_a_literal_subpath() {
    let sha = "a".repeat(40);
    let parse = |extra: Value| {
        let mut params = serde_json::json!({
            "folder": "/h/p", "url": "https://github.com/o/n.git", "repo": "o/n",
            "base": sha, "bundle": "/h/b", "head": sha, "index": sha, "work": sha,
            "head_first": true,
        });
        params.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        StartParams::parse(&params).unwrap().head_first
    };
    assert_eq!(parse(serde_json::json!({})), Some(HeadFirst { subpath: vec![] }));
    let nested = parse(serde_json::json!({"subpath": "/app/web/"})).unwrap();
    assert_eq!(nested.folders(), ["app", "app/web"]);
    assert_eq!(parse(serde_json::json!({"since": sha})), None, "a delta");
    assert_eq!(parse(serde_json::json!({"sparse": "/a\n"})), None, "the Mac's patterns");
    assert_eq!(parse(serde_json::json!({"head_first": false})), None);
    for subpath in ["a/../b", "a//b", "a/*", "!a", "#a", "a/[x]", "a\\b", " a", "./a"] {
        assert_eq!(parse(serde_json::json!({ "subpath": subpath })), None, "{subpath}");
    }
}

#[test]
fn head_refs_are_checked_by_git() {
    assert_eq!(check_head_ref("refs/heads/feature/x").unwrap(), "feature/x");
    for head_ref in [
        "refs/heads/",
        "refs/tags/v1",
        "main",
        "refs/heads/-x",
        "refs/heads/a..b",
        "refs/heads/a b",
        "refs/heads/x.lock",
        "refs/heads/a~1",
    ] {
        assert!(check_head_ref(head_ref).is_err(), "{head_ref}");
    }
}
