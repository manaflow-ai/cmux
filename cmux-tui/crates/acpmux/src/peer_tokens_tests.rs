use super::*;

#[test]
fn a_replaced_cache_cannot_erase_or_overwrite_the_same_urls_new_tokens() {
    let dir = tempfile::tempdir().unwrap();
    let book = Arc::new(LastGood::open(Some(dir.path())));
    let old = TokenCache::default();
    old.back(book.clone(), "box", "ssh://box", |_| true);
    old.activate();
    old.persist();
    let stale = ("old-dashboard".into(), Some("old-peer".into()));
    old.keep(&stale);
    let replacement = TokenCache::default();
    replacement.back(book.clone(), "box", "ssh://box", |_| true);
    replacement.activate();
    replacement.persist();
    let fresh = ("new-dashboard".into(), Some("new-peer".into()));
    replacement.keep(&fresh);

    // Force the old connection's refusal after its replacement authenticated.
    old.forget();
    assert_eq!(book.tokens.get("box", "ssh://box"), Some(fresh.clone()));
    // An old ssh read can finish late too; it must not restore stale credentials.
    old.keep(&stale);
    assert_eq!(book.tokens.get("box", "ssh://box"), Some(fresh.clone()));
    assert_eq!(
        LastGood::open(Some(dir.path())).tokens.get("box", "ssh://box"),
        Some(fresh),
        "the next daemon must still skip the ssh read"
    );
    replacement.forget();
    assert_eq!(book.tokens.get("box", "ssh://box"), None);
}

#[test]
fn registration_order_owns_tokens_even_when_preparations_finish_in_reverse() {
    let book = Arc::new(LastGood::open(None));
    let first = TokenCache::default();
    let second = TokenCache::default();
    first.back(book.clone(), "box", "ssh://box", |_| true);
    second.back(book.clone(), "box", "ssh://box", |_| true);
    second.activate();
    second.keep(&("second".into(), Some("peer-second".into())));
    first.activate();
    let current = ("first".into(), Some("peer-first".into()));
    first.keep(&current);
    second.forget();
    second.persist();
    assert_eq!(book.tokens.get("box", "ssh://box"), Some(current.clone()));
    // Merely preparing a third peer must not retire the registered writer.
    let third = TokenCache::default();
    third.back(book.clone(), "box", "ssh://box", |_| false);
    third.persist();
    drop(second);
    first.forget();
    assert_eq!(book.tokens.get("box", "ssh://box"), None);
    first.keep(&current);
    assert_eq!(book.tokens.get("box", "ssh://box"), Some(current));
}

#[test]
fn keeps_only_a_read_with_a_peer_token() {
    let cache = TokenCache::default();
    cache.keep(&("dash".into(), None));
    assert_eq!(cache.get(), None, "a remote with no peer token is read at each connect");
    cache.keep(&("dash".into(), Some("peer".into())));
    assert_eq!(cache.get(), Some(("dash".into(), Some("peer".into()))));
    let next = TokenCache::default();
    next.carry(&cache);
    assert_eq!(next.get(), cache.get());
    cache.forget();
    assert_eq!(cache.get(), None);
}

/// A replacement pointed at another URL never starts with, or keeps, the old host's tokens.
#[test]
fn carry_across_a_url_change_takes_nothing() {
    let dir = tempfile::tempdir().unwrap();
    let open = || Arc::new(LastGood::open(Some(dir.path())));
    let old = TokenCache::default();
    old.back(open(), "box", "ssh://box", |_| true);
    old.activate();
    old.persist();
    old.keep(&("dash".into(), Some("peer".into())));
    let moved = TokenCache::default();
    moved.back(open(), "box", "ssh://elsewhere", |_| true);
    moved.activate();
    moved.persist();
    moved.carry(&old);
    assert_eq!(moved.get(), None);
    let next = TokenCache::default();
    next.back(open(), "box", "ssh://elsewhere", |_| true);
    next.activate();
    next.persist();
    assert_eq!(next.get(), None, "nothing was kept under the new URL");
}

/// What a peer keeps reaches the next run's peer of the same name and URL only, and a
/// forget (refused, served as Web, the remote restarting) removes it from the file.
#[test]
fn a_backed_cache_starts_with_what_the_last_run_kept_and_forget_removes_it() {
    let dir = tempfile::tempdir().unwrap();
    let read: Tokens = ("dash".into(), Some("peer".into()));
    let first = TokenCache::default();
    first.back(Arc::new(LastGood::open(Some(dir.path()))), "box", "ssh://box", |_| true);
    first.activate();
    first.persist();
    assert_eq!(first.get(), None);
    first.keep(&read);

    // The next run.
    let open = || Arc::new(LastGood::open(Some(dir.path())));
    let next = TokenCache::default();
    next.back(open(), "box", "ssh://box", |_| true);
    next.activate();
    next.persist();
    assert_eq!(next.get(), Some(read.clone()), "kept across the restart");
    let moved = TokenCache::default();
    moved.back(open(), "box", "ssh://elsewhere", |_| true);
    moved.activate();
    moved.persist();
    assert_eq!(moved.get(), None, "a changed URL reads again");

    next.forget();
    assert_eq!(open().tokens.get("box", "ssh://box"), None, "forget removes the entry");
    let after = TokenCache::default();
    after.back(open(), "box", "ssh://box", |_| true);
    after.activate();
    after.persist();
    assert_eq!(after.get(), None);

    // A configured token that disagrees wins, and the stale entry leaves the file: removing
    // that configuration later does not bring it back.
    after.keep(&read);
    let configured = TokenCache::default();
    configured.back(open(), "box", "ssh://box", |(token, _)| token == "configured");
    configured.activate();
    configured.persist();
    assert_eq!(configured.get(), None, "a configured token it disagrees with wins");
    assert_eq!(open().tokens.get("box", "ssh://box"), None, "and its entry is dropped");
}

/// Review of #38002: a token read that finished after `stop` opened a tunnel anyway.
#[tokio::test]
async fn a_stopped_peer_opens_no_tunnel_and_reads_no_tokens() {
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = super::super::Peer::new("p", "ssh://box.invalid:7777", None, None, tx);
    peer.stop();
    assert_eq!(peer.open_tunnel().await.err().as_deref(), Some("peer stopped"));
    assert!(peer.tunnel.lock().await.is_none(), "no ssh after stop");
    assert_eq!(peer.connect_tokens().await.err().as_deref(), Some("peer stopped"));
}

#[test]
fn a_401_or_403_upgrade_is_a_refusal_and_nothing_else_is() {
    assert!(refused_status(401));
    assert!(refused_status(403));
    assert!(!refused_status(502));
    assert!(!refused(&tokio_tungstenite::tungstenite::Error::ConnectionClosed));
}
