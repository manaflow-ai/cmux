//! The Swift decoder's behaviour, pinned (AgentPaneRequest+Decoding.swift and
//! the Cloud and GitHub family envelopes it called).

use serde_json::{Value, json};

use super::*;

fn op(method: &str, params: Value) -> HostOp {
    decode(&json!({ "method": method, "params": params }))
}

fn refused(method: &str) -> HostOp {
    HostOp::Unsupported { method: method.to_owned() }
}

#[test]
fn a_body_without_a_method_is_refused_with_no_name() {
    assert_eq!(decode(&json!("text")), refused(""));
    assert_eq!(decode(&json!({ "params": {} })), refused(""));
    assert_eq!(decode(&json!({ "method": 7 })), refused(""));
}

#[test]
fn a_method_outside_the_table_stays_the_hosts() {
    assert_eq!(op("tab.open", json!({})), HostOp::Swift);
    assert_eq!(op("cloud.environment", json!({})), HostOp::Swift);
    assert_eq!(op("imessage.send", json!({})), HostOp::Swift);
}

#[test]
fn the_method_list_holds_every_family_once() {
    let all = methods();
    assert_eq!(all.len(), 18 + 35 + 42);
    let mut unique = all.clone();
    unique.dedup();
    assert_eq!(unique, all);
}

#[test]
fn the_environment_envelope_passes_params_as_they_are() {
    assert_eq!(
        op("cloud.environment.update", json!({ "id": "env_1", "x": [1] })),
        HostOp::CloudEnvironment {
            action: "update".into(),
            params: json!({ "id": "env_1", "x": [1] })
        }
    );
    // No params, or params that are no object, are an empty object.
    for params in [Value::Null, json!([1]), json!("x")] {
        assert_eq!(
            op("cloud.environment.list", params),
            HostOp::CloudEnvironment { action: "list".into(), params: json!({}) }
        );
    }
    assert_eq!(
        decode(&json!({ "method": "cloud.environment.create" })),
        HostOp::CloudEnvironment { action: "create".into(), params: json!({}) }
    );
}

#[test]
fn a_reservation_keeps_the_hosts_three_keys_out_of_the_params() {
    assert_eq!(
        op(
            "cloud.reserve",
            json!({ "composeKey": "k1", "replacesChat": "chat-1", "atOpen": true, "auto": false, "machine": "m" })
        ),
        HostOp::CloudReservation {
            release: false,
            params: json!({ "composeKey": "k1", "machine": "m" }),
            compose_key: Some("k1".into()),
            replaces_chat: Some("chat-1".into()),
            at_open: true,
            auto: false,
        }
    );
    assert_eq!(
        op("cloud.releaseReservation", Value::Null),
        HostOp::CloudReservation {
            release: true,
            params: json!({}),
            compose_key: None,
            replaces_chat: None,
            at_open: false,
            auto: false,
        }
    );
    // A non-string composeKey is no key, and stays in the params.
    let HostOp::CloudReservation { compose_key, params, .. } =
        op("cloud.reserve", json!({ "composeKey": 4 }))
    else {
        panic!("a reservation");
    };
    assert_eq!((compose_key, params), (None, json!({ "composeKey": 4 })));
}

#[test]
fn a_reservation_refuses_a_bad_host_key() {
    for params in [
        json!({ "atOpen": "yes" }),
        json!({ "atOpen": null }),
        json!({ "auto": 1 }),
        json!({ "replacesChat": "" }),
        json!({ "replacesChat": null }),
        json!({ "replacesChat": 5 }),
        json!({ "replacesChat": "x".repeat(129) }),
    ] {
        assert_eq!(op("cloud.reserve", params.clone()), refused("cloud.reserve"), "{params}");
    }
    assert!(matches!(
        op("cloud.reserve", json!({ "replacesChat": "x".repeat(128) })),
        HostOp::CloudReservation { .. }
    ));
}

#[test]
fn repository_actions_take_only_their_shape() {
    let ok = |method: &str, params: Value| {
        assert_eq!(
            op(method, params.clone()),
            HostOp::CloudRepository { method: method.into(), params },
            "{method}"
        );
    };
    let no = |method: &str, params: Value| {
        assert_eq!(op(method, params.clone()), refused(method), "{method} {params}");
    };

    ok("cloud.repo.local", json!({}));
    no("cloud.repo.local", json!({ "x": 1 }));

    ok(
        "cloud.repo.sync",
        json!({ "repos": [], "recent": [], "complete": true, "install_url": "u" }),
    );
    no("cloud.repo.sync", json!({}));
    no("cloud.repo.sync", json!({ "repos": {} }));
    no("cloud.repo.sync", json!({ "repos": [], "other": 1 }));

    for method in ["cloud.repo.list", "cloud.repo.attached"] {
        ok(method, json!({}));
        ok(method, json!({ "session": "a_b.c:d-1", "query": "x" }));
        no(method, json!({ "session": "a b" }));
        no(method, json!({ "session": null }));
        no(method, json!({ "session": "s".repeat(129) }));
        no(method, json!({ "other": 1 }));
    }

    ok("cloud.repo.add", json!({ "repo": "owner/name", "ref": "main" }));
    ok("cloud.repo.add", json!({ "session": "s", "repo": "https://x" }));
    no("cloud.repo.add", json!({}));
    no("cloud.repo.add", json!({ "repo": "" }));
    no("cloud.repo.add", json!({ "repo": "a\u{0}b" }));
    no("cloud.repo.add", json!({ "repo": "r".repeat(2049) }));
    no("cloud.repo.add", json!({ "repo": "r", "x": 1 }));

    ok("cloud.repo.wait_github", json!({}));
    ok("cloud.repo.wait_github", json!({ "timeout_ms": 0 }));
    ok("cloud.repo.wait_github", json!({ "timeout_ms": 60_000.0 }));
    no("cloud.repo.wait_github", json!({ "timeout_ms": 60_001 }));
    no("cloud.repo.wait_github", json!({ "timeout_ms": -1 }));
    no("cloud.repo.wait_github", json!({ "timeout_ms": 1.5 }));
    no("cloud.repo.wait_github", json!({ "timeout_ms": "5" }));
    no("cloud.repo.wait_github", json!({ "timeout_ms": null }));
    no("cloud.repo.wait_github", json!({ "query": "x" }));
}

#[test]
fn github_add_account_matches_the_host_decoder() {
    for params in [json!({ "add_account": true }), json!({ "add_account": true, "repo": null })] {
        assert_eq!(
            serde_json::to_value(op("github.connect", params)).unwrap(),
            json!({ "case": "gitHub", "github": { "request": "addAccount" } })
        );
    }
    for params in [
        json!({ "add_account": false }),
        json!({ "add_account": "true" }),
        json!({ "add_account": null }),
    ] {
        assert_eq!(
            op("github.connect", params),
            HostOp::GitHub { github: GitHubRequest::Connect { repo: None } }
        );
    }
    assert_eq!(
        op("github.connect", json!({ "add_account": true, "repo": "manaflow-ai/cmux" })),
        HostOp::GitHub { github: GitHubRequest::Connect { repo: Some("manaflow-ai/cmux".into()) } }
    );
    assert_eq!(
        op("github.connect", json!({ "add_account": true, "repo": "invalid" })),
        refused("github.connect")
    );
}

#[test]
fn github_requests_are_checked() {
    let gh = |method: &str, params: Value| op(method, params);
    let is = |github: GitHubRequest| HostOp::GitHub { github };

    assert_eq!(gh("github.status", json!({ "anything": 1 })), is(GitHubRequest::Status));

    assert_eq!(gh("github.connect", Value::Null), is(GitHubRequest::Connect { repo: None }));
    assert_eq!(
        gh("github.connect", json!({ "repo": null })),
        is(GitHubRequest::Connect { repo: None })
    );
    assert_eq!(
        gh("github.connect", json!({ "repo": "manaflow-ai/cmux" })),
        is(GitHubRequest::Connect { repo: Some("manaflow-ai/cmux".into()) })
    );
    assert_eq!(gh("github.connect", json!({ "repo": "nope" })), refused("github.connect"));
    assert_eq!(gh("github.connect", json!({ "repo": 3 })), refused("github.connect"));

    assert_eq!(gh("github.repos.list", json!({})), is(GitHubRequest::Repos { query: None }));
    assert_eq!(
        gh("github.repos.list", json!({ "query": "cm" })),
        is(GitHubRequest::Repos { query: Some("cm".into()) })
    );
    assert_eq!(
        gh("github.repos.list", json!({ "query": "q".repeat(1025) })),
        refused("github.repos.list")
    );
    assert_eq!(gh("github.repos.list", json!({ "query": "a\u{0}" })), refused("github.repos.list"));
    assert_eq!(gh("github.repos.list", json!({ "query": [] })), refused("github.repos.list"));

    assert_eq!(
        gh("repo.clone", json!({ "url": "https://x/y.git", "idempotency_key": "k-1" })),
        is(GitHubRequest::CloneUrl { url: "https://x/y.git".into(), key: "k-1".into() })
    );
    assert_eq!(
        gh("repo.clone", json!({ "url": "u", "idempotency_key": "has space" })),
        refused("repo.clone")
    );
    assert_eq!(gh("repo.clone", json!({ "url": "u" })), refused("repo.clone"));
    assert_eq!(
        gh("repo.clone", json!({ "url": "u".repeat(4097), "idempotency_key": "k" })),
        refused("repo.clone")
    );

    assert_eq!(
        gh("github.repos.checkout", json!({ "repo": "o/n", "idempotency_key": "k" })),
        is(GitHubRequest::Checkout { repo: "o/n".into(), candidates: vec![], key: "k".into() })
    );
    assert_eq!(
        gh(
            "github.repos.checkout",
            json!({ "repo": "o/n", "idempotency_key": "k", "candidates": ["/a", "/b"] })
        ),
        is(GitHubRequest::Checkout {
            repo: "o/n".into(),
            candidates: vec!["/a".into(), "/b".into()],
            key: "k".into()
        })
    );
    // Only the first 16 candidates are read; a bad one past them is never looked at.
    let mut many: Vec<Value> = (0..16).map(|i| json!(format!("/p{i}"))).collect();
    many.push(json!("relative"));
    let HostOp::GitHub { github: GitHubRequest::Checkout { candidates, .. } } = gh(
        "github.repos.checkout",
        json!({ "repo": "o/n", "idempotency_key": "k", "candidates": many }),
    ) else {
        panic!("a checkout");
    };
    assert_eq!(candidates.len(), 16);
    for candidates in [json!(["relative"]), json!([1]), json!("/a"), json!(["/a\u{0}"])] {
        assert_eq!(
            gh(
                "github.repos.checkout",
                json!({ "repo": "o/n", "idempotency_key": "k", "candidates": candidates })
            ),
            refused("github.repos.checkout")
        );
    }
    assert_eq!(
        gh("github.repos.checkout", json!({ "repo": "o/.git", "idempotency_key": "k" })),
        refused("github.repos.checkout")
    );
}

#[test]
fn the_answer_is_the_json_the_host_reads() {
    assert_eq!(serde_json::to_value(HostOp::Swift).unwrap(), json!({ "case": "swift" }));
    assert_eq!(
        serde_json::to_value(refused("x")).unwrap(),
        json!({ "case": "unsupported", "method": "x" })
    );
    assert_eq!(
        serde_json::to_value(op("cloud.reserve", json!({ "atOpen": true }))).unwrap(),
        json!({ "case": "cloudReservation", "release": false, "params": {}, "composeKey": null,
                "replacesChat": null, "atOpen": true, "auto": false })
    );
    assert_eq!(
        serde_json::to_value(op(
            "github.repos.checkout",
            json!({ "repo": "o/n", "idempotency_key": "k" })
        ))
        .unwrap(),
        json!({ "case": "gitHub", "github": { "request": "checkout", "repo": "o/n", "candidates": [], "key": "k" } })
    );
    assert_eq!(
        serde_json::to_value(op("repo.clone", json!({ "url": "u", "idempotency_key": "k" })))
            .unwrap(),
        json!({ "case": "gitHub", "github": { "request": "cloneUrl", "url": "u", "key": "k" } })
    );
}

#[test]
fn full_names_follow_the_cloud_rule() {
    for good in
        ["a/b", "manaflow-ai/cmux", "a-b/c.d_e", &format!("{}/{}", "o".repeat(39), "n".repeat(100))]
    {
        assert!(is_github_full_name(good), "{good}");
    }
    for bad in [
        "",
        "a",
        "a/b/c",
        "/b",
        "a/",
        "-a/b",
        "a-/b",
        "a/.",
        "a/..",
        "a/.git",
        "a b/c",
        "a/b c",
        &format!("{}/b", "o".repeat(40)),
        &format!("a/{}", "n".repeat(101)),
    ] {
        assert!(!is_github_full_name(bad), "{bad}");
    }
}

#[test]
fn the_action_run_checks_hold() {
    assert!(is_cloud_environment_id("env_a"));
    assert!(is_cloud_environment_id(&format!("env_{}", "x".repeat(64))));
    assert!(!is_cloud_environment_id(&format!("env_{}", "x".repeat(65))));
    assert!(!is_cloud_environment_id("env_"));
    assert!(!is_cloud_environment_id("env_a.b"));
    assert!(!is_cloud_environment_id("vne_abc"));

    assert!(is_editor_id("vscode") && is_editor_id("rust-rover2"));
    assert!(
        !is_editor_id("")
            && !is_editor_id("VSCode")
            && !is_editor_id(&"a".repeat(33))
            && !is_editor_id("a_b")
    );

    assert!(is_handoff_token("123e4567-e89b-12d3-a456-426614174000"));
    assert!(
        !is_handoff_token("short")
            && !is_handoff_token(&"a".repeat(65))
            && !is_handoff_token("aaaaaaaaaaaaaaa_a")
    );

    assert!(is_github_owner("a") && is_github_owner("a-b") && is_github_owner(&"a".repeat(39)));
    assert!(
        !is_github_owner("")
            && !is_github_owner("-a")
            && !is_github_owner("a-")
            && !is_github_owner(&"a".repeat(40))
    );

    assert!(is_github_repo("manaflow-ai/cmux") && is_github_repo("a/.github"));
    assert!(
        !is_github_repo("a/.")
            && !is_github_repo("a/..")
            && !is_github_repo("a")
            && !is_github_repo("-a/b")
    );
    assert!(!is_github_repo(&format!("{}/{}", "o".repeat(39), "n".repeat(101))));

    let one = vec!["s1".to_owned()];
    assert!(are_session_targets(&one, "chatPlace.set", false));
    assert!(!are_session_targets(&one, "chatPlace.set", true));
    assert!(!are_session_targets(&["a".into(), "b".into()], "chatMove.retry", false));
    assert!(are_session_targets(&["a".into(), "b".into()], "cloudEvacuate", false));
    assert!(!are_session_targets(&[], "cloudBringBackAll", false));
    assert!(!are_session_targets(&["a,b".into()], "cloudEvacuate", false));
    assert!(!are_session_targets(&one, "other", false));
}
