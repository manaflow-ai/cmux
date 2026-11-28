//! Update offers for git apps (`git_updates.rs`) against the local fixture
//! transport (no network): a pinned version tag offers the newest tag, a
//! widened scope list asks for consent again, and listing the installed apps
//! starts one background check when it is due.

use super::super::git_source::tests::{FakeGit, app_tarball};
use super::*;

const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const C: &str = "cccccccccccccccccccccccccccccccccccccccc";

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
fn install(f: &Fixture, reference: &str, key: &str) -> Value {
    let card = call(f, "cmux.apps.catalog.get", json!({"app": reference}), Origin::Cli).unwrap();
    call(
        f,
        "cmux.apps.install",
        json!({"app": reference, "commit": card["commit"], "idempotency_key": key}),
        Origin::User,
    )
    .unwrap()
}

fn offers(f: &Fixture) -> Vec<Value> {
    let list = call(f, "cmux.apps.updates.list", json!({}), Origin::Cli).unwrap();
    list["updates"].as_array().cloned().unwrap_or_default()
}

#[test]
fn an_update_check_offers_the_newest_tag_and_asks_again_only_for_new_scopes() {
    let f = fixture();
    let git = with_git(&f);
    let v1 = app_tarball("octo/hello", "1.0.0", json!({"workspace:read": "r"}));
    git.serve("octo", "hello", A, &[("refs/tags/v1.0.0", A)], &[(A, v1)]);
    install(&f, "github.com/octo/hello@v1.0.0", "k1");

    // Nothing new at the pinned tag: no offer, and only the refs were read.
    let before = git.gets.lock().unwrap().len();
    f.supervisor.check_updates_now();
    assert!(offers(&f).is_empty());
    assert!(
        git.gets.lock().unwrap()[before..].iter().all(|url| !url.contains("codeload")),
        "no archive is fetched when the commit did not move"
    );

    // A newer version tag with the same scopes: offered, no consent needed.
    let v2 = app_tarball("octo/hello", "1.1.0", json!({"workspace:read": "r"}));
    git.serve("octo", "hello", B, &[("refs/tags/v1.0.0", A), ("refs/tags/v1.1.0", B)], &[(B, v2)]);
    f.supervisor.check_updates_now();
    let found = offers(&f);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0]["app"], "octo/hello");
    assert_eq!(found[0]["installed"]["commit"], A);
    assert_eq!(found[0]["available"]["commit"], B);
    assert_eq!(found[0]["available"]["tag"], "v1.1.0");
    assert_eq!(found[0]["available"]["version"], "1.1.0");
    assert_eq!(found[0]["needs_consent"], false);
    assert_eq!(found[0]["new_scopes"], json!([]));

    // The check never stages: an install without the card's read is refused.
    let unstaged = call(
        &f,
        "cmux.apps.install",
        json!({
            "app": found[0]["update_ref"],
            "commit": found[0]["available"]["commit"],
            "idempotency_key": "x",
        }),
        Origin::User,
    )
    .unwrap_err();
    assert_eq!(unstaged.code, "apps.git.not_staged");

    // The offer is taken with apps.update; then nothing is offered.
    let moved = call(
        &f,
        "cmux.apps.update",
        json!({"app": "octo/hello", "idempotency_key": "u1"}),
        Origin::User,
    )
    .unwrap();
    assert_eq!(moved["app"]["commit"], B);
    assert!(offers(&f).is_empty(), "an offer against the old commit is not listed");

    // A newer tag asking for one more scope: offered with needs_consent,
    // apps.update refuses, and the consent card the offer names moves it.
    let v3 = app_tarball("octo/hello", "1.2.0", json!({"workspace:read": "r", "agents:read": "a"}));
    git.serve(
        "octo",
        "hello",
        C,
        &[("refs/tags/v1.0.0", A), ("refs/tags/v1.1.0", B), ("refs/tags/v1.2.0", C)],
        &[(C, v3)],
    );
    f.supervisor.check_updates_now();
    let found = offers(&f);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0]["available"]["commit"], C);
    assert_eq!(found[0]["needs_consent"], true);
    assert_eq!(found[0]["new_scopes"], json!(["agents:read"]));
    assert_eq!(found[0]["review"], "cmux apps install github.com/octo/hello");
    let asks = call(
        &f,
        "cmux.apps.update",
        json!({"app": "octo/hello", "idempotency_key": "u2"}),
        Origin::User,
    )
    .unwrap_err();
    assert_eq!(asks.code, "apps.update.needs_consent");
    let reviewed = install(&f, "github.com/octo/hello", "k2");
    assert_eq!(reviewed["app"]["commit"], C);
    assert!(
        reviewed["app"]["grants"].as_array().unwrap().iter().any(|g| g == "agents:read"),
        "the confirmed card grants the new scope"
    );
    assert!(offers(&f).is_empty());
}

#[test]
fn listing_installed_apps_starts_one_background_update_check_when_due() {
    let f = fixture();
    let git = with_git(&f);

    // No git app: listing starts nothing.
    call(&f, "cmux.apps.installed.list", json!({}), Origin::Cli).unwrap();
    assert!(git.gets.lock().unwrap().is_empty());

    let v1 = app_tarball("octo/hello", "1.0.0", json!({"workspace:read": "r"}));
    git.serve("octo", "hello", A, &[("refs/heads/main", A)], &[(A, v1)]);
    install(&f, "github.com/octo/hello", "k1");
    let v2 = app_tarball("octo/hello", "1.1.0", json!({"workspace:read": "r"}));
    git.serve("octo", "hello", B, &[("refs/heads/main", B)], &[(B, v2)]);

    // The listing answers at once; the check runs off it and says when the
    // offers changed.
    call(&f, "cmux.apps.installed.list", json!({}), Origin::Cli).unwrap();
    f.wait("update check", |e| e["event"] == "apps-changed" && e["transaction"] == "updates");
    let list = call(&f, "cmux.apps.updates.list", json!({}), Origin::Cli).unwrap();
    assert_eq!(list["checking"], false);
    assert!(list["checked_at"].as_u64().is_some());
    assert_eq!(list["updates"][0]["available"]["commit"], B);

    // Not due again: more listings read nothing from the network.
    let after = git.gets.lock().unwrap().len();
    call(&f, "cmux.apps.installed.list", json!({}), Origin::Cli).unwrap();
    call(&f, "cmux.apps.updates.list", json!({}), Origin::Cli).unwrap();
    assert_eq!(git.gets.lock().unwrap().len(), after, "no second check inside CHECK_EVERY");

    // Uninstalling drops the offer and the tree it fetched.
    call(
        &f,
        "cmux.apps.uninstall",
        json!({"app": "octo/hello", "idempotency_key": "rm"}),
        Origin::User,
    )
    .unwrap();
    assert!(offers(&f).is_empty());
    assert!(!f.state.join("apps/git/github.com/octo/hello").join(B).exists());
}
