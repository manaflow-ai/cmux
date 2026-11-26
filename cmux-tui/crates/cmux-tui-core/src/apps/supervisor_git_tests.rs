//! Installs from a git repository through the App Store ops, against a
//! local fixture transport (no network): the consent card's listing, the
//! install, the id rule, an update that moves the commit or asks again for
//! new scopes, uninstall, and a restart that loads the install back.

use super::super::git_source::tests::{FakeGit, app_tarball};
use super::*;

const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn with_git(f: &Fixture) -> Arc<FakeGit> {
    let git = Arc::new(FakeGit::default());
    f.supervisor.set_git_transport(git.clone());
    git
}

fn call(
    f: &Fixture,
    op: &str,
    args: Value,
    origin: Origin,
) -> Result<Value, super::super::supervisor::ApiError> {
    f.supervisor.store_call(CLIENT, op, args, origin)
}

/// The consent card's read, then the confirmed install.
fn install(
    f: &Fixture,
    reference: &str,
    key: &str,
) -> Result<Value, super::super::supervisor::ApiError> {
    let card = call(f, "cmux.apps.catalog.get", json!({"app": reference}), Origin::Cli)?;
    let commit = card["commit"].clone();
    call(
        f,
        "cmux.apps.install",
        json!({"app": reference, "commit": commit, "idempotency_key": key}),
        Origin::User,
    )
}

#[test]
fn nothing_installs_from_a_repository_without_its_consent_card() {
    let f = fixture();
    let git = with_git(&f);
    git.serve("octo", "hello", A, &[], &[(A, app_tarball("octo/hello", "1.0.0", json!({})))]);
    let args = json!({"app": "github.com/octo/hello", "idempotency_key": "k"});
    let error = call(&f, "cmux.apps.install", args, Origin::User).unwrap_err();
    assert_eq!(error.code, "apps.git.commit_required");
    let args = json!({"app": "github.com/octo/hello", "commit": A, "idempotency_key": "k"});
    let error = call(&f, "cmux.apps.install", args, Origin::User).unwrap_err();
    assert_eq!(error.code, "apps.git.not_staged");
    assert!(git.gets.lock().unwrap().is_empty(), "nothing was fetched");
}

#[test]
fn a_repository_installs_at_a_pinned_commit_after_its_consent_card_listing() {
    let f = fixture();
    let git = with_git(&f);
    let tar = app_tarball("octo/hello", "1.0.0", json!({"workspace:read": "Show your workspaces"}));
    git.serve("octo", "hello", A, &[("refs/heads/main", A)], &[(A, tar)]);

    // The card's read: the listing at the commit, its scopes and source, nothing installed.
    let card =
        call(&f, "cmux.apps.catalog.get", json!({"app": "github.com/octo/hello"}), Origin::Cli)
            .unwrap();
    assert_eq!(card["app"], "octo/hello");
    assert_eq!(card["commit"], A);
    assert_eq!(card["repository"], "https://github.com/octo/hello");
    assert_eq!(card["reviewed"], false, "a repository not on the community list is not reviewed");
    assert_eq!(card["tier"], "unverified");
    assert_eq!(card["scopes"][0]["scope"], "workspace:read");
    assert!(!f.supervisor.inner.lock().unwrap().mirror.apps.contains_key("octo/hello"));

    // Only the person's confirmed install installs.
    let refused = install_with_origin(&f, Origin::Cli).unwrap_err();
    assert_eq!(refused.code, "apps.origin");
    let installed = install(&f, "github.com/octo/hello", "k1").unwrap();
    assert_eq!(installed["app"]["state"]["installed"], true);
    assert_eq!(installed["app"]["state"]["source"], "git");
    assert_eq!(installed["app"]["commit"], A);
    let dir = f.state.join("apps/git/github.com/octo/hello").join(A);
    assert!(
        dir.join("main.js").is_file(),
        "the package lives at <state>/apps/git/HOST/OWNER/REPO/<commit>"
    );

    let rows = call(&f, "cmux.apps.installed.list", json!({}), Origin::Cli).unwrap();
    let row =
        rows["apps"].as_array().unwrap().iter().find(|r| r["app"] == "octo/hello").unwrap().clone();
    assert_eq!(
        (row["repository"].as_str(), row["commit"].as_str(), row["version"].as_str()),
        (Some("https://github.com/octo/hello"), Some(A), Some("1.0.0"))
    );
    let detail =
        call(&f, "cmux.apps.catalog.get", json!({"app": "octo/hello"}), Origin::Cli).unwrap();
    assert_eq!(detail["source_ref"], "github.com/octo/hello");

    // The anonymous install count: the reference and commit, nothing else.
    let deadline = Instant::now() + Duration::from_secs(5);
    while git.posts.lock().unwrap().is_empty() && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    let posts = git.posts.lock().unwrap().clone();
    assert_eq!(posts.len(), 1);
    assert!(posts[0].0.ends_with("/v1/extensions/installs"));
    assert_eq!(posts[0].1, json!({"ref": "github.com/octo/hello", "commit": A}));
}

fn install_with_origin(
    f: &Fixture,
    origin: Origin,
) -> Result<Value, super::super::supervisor::ApiError> {
    call(
        f,
        "cmux.apps.install",
        json!({"app": "github.com/octo/hello", "commit": A, "idempotency_key": "cli"}),
        origin,
    )
}

#[test]
fn an_app_whose_id_is_not_its_owners_or_is_first_party_never_installs_as_first_party() {
    let f = fixture();
    let git = with_git(&f);
    git.serve("octo", "spoof", A, &[], &[(A, app_tarball("someone/hello", "1.0.0", json!({})))]);
    git.serve("octo", "store", A, &[], &[(A, app_tarball("cmux/app-store", "1.0.0", json!({})))]);
    for repo in ["spoof", "store"] {
        let error = install(&f, &format!("github.com/octo/{repo}"), repo).unwrap_err();
        assert_eq!(error.code, "apps.git.invalid", "{repo}: {}", error.message);
    }
    // manaflow-ai's own repository: still a community (unverified) app.
    git.serve(
        "manaflow-ai",
        "focus-timer",
        A,
        &[],
        &[(A, app_tarball("manaflow-ai/focus-timer", "1.0.0", json!({})))],
    );
    let installed = install(&f, "github.com/manaflow-ai/focus-timer", "mf").unwrap();
    assert_eq!(installed["app"]["tier"], "unverified");
    assert_eq!(installed["app"]["hide_only"], false);
    // A bad reference names the form.
    let error = install(&f, "github.com/octo/he~llo", "bad").unwrap_err();
    assert_eq!(error.code, "apps.git.reference", "{error:?}");
}

#[test]
fn an_update_moves_the_commit_and_asks_again_only_for_new_scopes() {
    let f = fixture();
    let git = with_git(&f);
    let v1 = app_tarball("octo/hello", "1.0.0", json!({"workspace:read": "r"}));
    git.serve("octo", "hello", A, &[("refs/heads/main", A)], &[(A, v1)]);
    install(&f, "github.com/octo/hello", "k1").unwrap();

    // Nothing new: update says so.
    let same = call(
        &f,
        "cmux.apps.update",
        json!({"app": "octo/hello", "idempotency_key": "u0"}),
        Origin::User,
    )
    .unwrap();
    assert_eq!(same["updated"], false);

    // A new commit asking for one more scope: the update op refuses, the
    // card of `install <reference>` (which lists it) moves it.
    let v2 = app_tarball("octo/hello", "1.1.0", json!({"workspace:read": "r", "agents:read": "a"}));
    git.serve("octo", "hello", B, &[("refs/heads/main", B)], &[(B, v2)]);
    let asks = call(
        &f,
        "cmux.apps.update",
        json!({"app": "octo/hello", "idempotency_key": "u1"}),
        Origin::User,
    )
    .unwrap_err();
    assert_eq!(asks.code, "apps.update.needs_consent");
    assert!(
        asks.message.contains("agents:read")
            && asks.message.contains("cmux apps install github.com/octo/hello")
    );
    let moved = install(&f, "github.com/octo/hello", "k2").unwrap();
    assert_eq!(moved["app"]["commit"], B);
    assert_eq!(moved["app"]["version"], "1.1.0");
    let grants: Vec<&str> =
        moved["app"]["grants"].as_array().unwrap().iter().filter_map(Value::as_str).collect();
    assert!(
        grants.contains(&"agents:read"),
        "the confirmed card's read scope is granted: {grants:?}"
    );
    let base = f.state.join("apps/git/github.com/octo/hello");
    assert!(base.join(B).is_dir() && !base.join(A).exists(), "the old commit's files go");

    // A later commit that drops a scope updates without a card and drops its grant.
    const C: &str = "cccccccccccccccccccccccccccccccccccccccc";
    let v3 = app_tarball("octo/hello", "1.2.0", json!({"workspace:read": "r"}));
    git.serve("octo", "hello", C, &[("refs/heads/main", C)], &[(C, v3)]);
    let updated = call(
        &f,
        "cmux.apps.update",
        json!({"app": "github.com/octo/hello", "idempotency_key": "u2"}),
        Origin::User,
    )
    .unwrap();
    assert_eq!(updated["updated"], true);
    assert_eq!(updated["app"]["commit"], C);
    assert!(!updated["app"]["grants"].as_array().unwrap().iter().any(|g| g == "agents:read"));
}

#[test]
fn a_newer_tag_with_a_wider_scope_asks_again_before_it_installs() {
    let f = fixture();
    let git = with_git(&f);
    let v1 = app_tarball("octo/hello", "1.0.0", json!({"workspace:read": "r"}));
    git.serve("octo", "hello", A, &[("refs/heads/main", A), ("refs/tags/v1.0.0", A)], &[(A, v1)]);
    let pinned = install(&f, "github.com/octo/hello@v1.0.0", "k1").unwrap();
    assert_eq!(pinned["app"]["commit"], A);
    assert_eq!(pinned["app"]["tag"], "v1.0.0");

    // A newer release tag asks for one more scope: the update finds it and
    // refuses until its card is confirmed; nothing of v1.1.0 is installed.
    let v1 = app_tarball("octo/hello", "1.0.0", json!({"workspace:read": "r"}));
    let v2 = app_tarball("octo/hello", "1.1.0", json!({"workspace:read": "r", "agents:read": "a"}));
    git.serve(
        "octo",
        "hello",
        B,
        &[("refs/heads/main", B), ("refs/tags/v1.0.0", A), ("refs/tags/v1.1.0", B)],
        &[(A, v1), (B, v2)],
    );
    let asks = call(
        &f,
        "cmux.apps.update",
        json!({"app": "octo/hello", "idempotency_key": "u1"}),
        Origin::User,
    )
    .unwrap_err();
    assert_eq!(asks.code, "apps.update.needs_consent", "{asks:?}");
    assert!(asks.message.contains("agents:read"), "{}", asks.message);
    let base = f.state.join("apps/git/github.com/octo/hello");
    // v1.1.0 may sit staged on disk for the confirmed install; v1.0.0 stays
    // the installed commit (below).
    assert!(base.join(A).is_dir(), "v1.0.0 stays on disk");
    let still =
        call(&f, "cmux.apps.catalog.get", json!({"app": "octo/hello"}), Origin::Cli).unwrap();
    assert_eq!(still["commit"], A, "{still}");
    assert!(
        !still["grants"].as_array().into_iter().flatten().any(|g| g == "agents:read"),
        "the wider scope is not granted: {still}"
    );

    // The confirmed card of the newer tag moves it, with its scope.
    let moved = install(&f, "github.com/octo/hello@v1.1.0", "k2").unwrap();
    assert_eq!(moved["app"]["commit"], B);
    assert_eq!(moved["app"]["tag"], "v1.1.0");
    assert!(moved["app"]["grants"].as_array().unwrap().iter().any(|g| g == "agents:read"));
}

#[test]
fn a_reinstall_of_a_commit_whose_tree_changed_is_refused() {
    let f = fixture();
    let git = with_git(&f);
    git.serve("octo", "hello", A, &[], &[(A, app_tarball("octo/hello", "1.0.0", json!({})))]);
    install(&f, "github.com/octo/hello", "k1").unwrap();
    call(
        &f,
        "cmux.apps.uninstall",
        json!({"app": "octo/hello", "idempotency_key": "rm"}),
        Origin::User,
    )
    .unwrap();
    assert!(
        !f.state.join("apps/git/github.com/octo/hello").join(A).exists(),
        "uninstall removes the files"
    );
    // Same commit, other bytes.
    git.serve("octo", "hello", A, &[], &[(A, app_tarball("octo/hello", "6.6.6", json!({})))]);
    let error = install(&f, "github.com/octo/hello", "k2").unwrap_err();
    assert_eq!(error.code, "apps.git.digest_mismatch");
}

#[test]
fn a_git_install_loads_back_after_a_restart() {
    let f = fixture();
    let git = with_git(&f);
    git.serve("octo", "hello", A, &[], &[(A, app_tarball("octo/hello", "1.0.0", json!({})))]);
    install(&f, "github.com/octo/hello", "k1").unwrap();
    let Fixture { supervisor, _root, .. } = f;
    drop(supervisor);
    let again = fixture_with(&[], Duration::from_secs(60), _root);
    let rows = call(&again, "cmux.apps.installed.list", json!({}), Origin::Cli).unwrap();
    let row = rows["apps"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["app"] == "octo/hello")
        .cloned()
        .unwrap();
    assert_eq!(row["state"]["installed"], true);
    assert_eq!(row["commit"], A);
    assert_eq!(row["state"]["source"], "git");
}

#[test]
fn an_install_is_the_commit_its_card_showed_even_after_the_branch_moves() {
    let f = fixture();
    let git = with_git(&f);
    let one = app_tarball("octo/hello", "1.0.0", json!({}));
    let two = app_tarball("octo/hello", "2.0.0", json!({"net:example.com": "Reach example.com"}));
    git.serve("octo", "hello", A, &[("refs/heads/main", A)], &[(A, one.clone()), (B, two.clone())]);
    let card =
        call(&f, "cmux.apps.catalog.get", json!({"app": "github.com/octo/hello"}), Origin::Cli)
            .unwrap();
    assert_eq!(card["commit"], A);
    // The branch moves and another card is read before the first is confirmed.
    git.serve("octo", "hello", B, &[("refs/heads/main", B)], &[(A, one), (B, two)]);
    let other =
        call(&f, "cmux.apps.catalog.get", json!({"app": "github.com/octo/hello"}), Origin::Cli)
            .unwrap();
    assert_eq!(other["commit"], B);
    let args = json!({"app": "github.com/octo/hello", "commit": A, "idempotency_key": "k"});
    let installed = call(&f, "cmux.apps.install", args, Origin::User).unwrap();
    assert_eq!(installed["app"]["commit"], A, "the first card's commit installs, not the newest");
}

#[test]
fn a_failed_install_keeps_its_card_and_a_retry_with_the_same_key_replays_success() {
    let f = fixture();
    let git = with_git(&f);
    git.serve(
        "octo",
        "hello",
        A,
        &[("refs/heads/main", A)],
        &[(A, app_tarball("octo/hello", "1.0.0", json!({})))],
    );
    let first = install(&f, "github.com/octo/hello", "k").unwrap();
    // The same key again answers the finished install; another commit under it conflicts.
    let args = json!({"app": "github.com/octo/hello", "commit": A, "idempotency_key": "k"});
    let again = call(&f, "cmux.apps.install", args, Origin::User).unwrap();
    assert_eq!(again["app"]["commit"], first["app"]["commit"]);
    let args = json!({"app": "github.com/octo/hello", "commit": B, "idempotency_key": "k"});
    let conflict = call(&f, "cmux.apps.install", args, Origin::User).unwrap_err();
    assert_eq!(conflict.code, "idempotency.conflict");
}
