//! The remote daemon's tokens an `ssh://` peer read over ssh, kept for its next connect.
//!
//! Reading them is a whole ssh login of its own (`read_config_argv`), before the tunnel's login:
//! about 10 round trips, 400 ms at a 40 ms RTT, on every redial. The dashboard token lives in
//! the remote's config and the peer token for as long as the remote daemon runs, so a redial
//! presents the ones it read last and reads again only when they stop working:
//! - the upgrade is refused (401 or 403): the dashboard token changed; read again once, at once;
//! - the remote served the link as Web: its peer token changed (`Peer::stale_token`);
//! - the remote announced a restart (Close 1012): its next launch writes a new peer token.
//!
//! Only a read that found a peer token is kept: a remote with none is starting, or too old to
//! make one, and is read again at each connect as before (`TOKEN_REREADS`).
//!
//! A peer of the hub keeps them on disk too (`peer_kept_tokens.rs`), so its daemon's next run
//! starts with them and the same three cases read them again.

use crate::peer_kept_tokens::{Generation, KeptTokens};
use crate::peer_last_good::LastGood;
use std::sync::{Arc, Mutex, OnceLock};

/// The dashboard token and the peer token.
pub(crate) type Tokens = (String, Option<String>);

#[derive(Default)]
pub(crate) struct TokenCache {
    tokens: Mutex<Option<Tokens>>,
    /// Where they are kept on disk, and under which peer name and URL (`back`).
    disk: OnceLock<(Arc<LastGood>, String, String, Generation)>,
}

impl TokenCache {
    pub(crate) fn get(&self) -> Option<Tokens> {
        self.tokens.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Keep these on disk from now on as `name`'s, read over `url`, and start with what is kept
    /// there for both when `usable` takes it (it agrees with the configured half).
    pub(crate) fn back(
        &self,
        book: Arc<LastGood>,
        name: &str,
        url: &str,
        usable: impl FnOnce(&Tokens) -> bool,
    ) {
        self.disk.get_or_init(|| {
            let (generation, kept) = book.tokens.bind(name, url);
            match kept {
                Some(kept) if usable(&kept) => {
                    let mut tokens = self.tokens.lock().unwrap_or_else(|e| e.into_inner());
                    tokens.get_or_insert(kept);
                }
                // Registration flushes a rejected entry after claiming ownership.
                _ => {}
            }
            (book, name.to_owned(), url.to_owned(), generation)
        });
    }

    pub(crate) fn activate(&self) {
        if let Some((_, _, _, generation)) = self.kept() {
            generation.activate();
        }
    }

    /// Reconcile after registration, outside the shared registry lock. An older
    /// registration finishing this late cannot change the current owner's file.
    pub(crate) fn persist(&self) {
        let current = self.tokens.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((kept, name, url, generation)) = self.kept() {
            match current.as_ref() {
                Some(tokens) => kept.keep_current(name, url, generation, tokens),
                None => kept.forget_current(name, url, generation),
            }
        }
    }

    fn kept(&self) -> Option<(&KeptTokens, &str, &str, &Generation)> {
        self.disk.get().map(|(book, name, url, generation)| {
            (&book.tokens, name.as_str(), url.as_str(), generation)
        })
    }

    /// Kept only with a peer token (see the module note).
    pub(crate) fn keep(&self, tokens: &Tokens) {
        if tokens.1.is_some() {
            let mut current = self.tokens.lock().unwrap_or_else(|e| e.into_inner());
            *current = Some(tokens.clone());
            if let Some((kept, name, url, generation)) = self.kept() {
                kept.keep_current(name, url, generation, tokens);
            }
        }
    }

    pub(crate) fn forget(&self) {
        let mut current = self.tokens.lock().unwrap_or_else(|e| e.into_inner());
        *current = None;
        if let Some((kept, name, url, generation)) = self.kept() {
            kept.forget_current(name, url, generation);
        }
    }

    /// A replacement of the same peer (`Hub::spawn_peer`) starts with what the old one read,
    /// only when both read over the same URL (the caller checks that too): tokens read from one
    /// host are never kept as another's.
    pub(crate) fn carry(&self, from: &TokenCache) {
        let same_url = match (self.disk.get(), from.disk.get()) {
            (Some((_, _, to, _)), Some((_, _, of, _))) => to == of,
            _ => true,
        };
        if same_url && let Some(tokens) = from.get() {
            self.keep(&tokens);
        }
    }
}

impl Drop for TokenCache {
    fn drop(&mut self) {
        if let Some((book, name, _, generation)) = self.disk.take() {
            book.tokens.release(&name, generation);
        }
    }
}

/// The remote refused the WebSocket upgrade's credentials.
pub(crate) fn refused(error: &tokio_tungstenite::tungstenite::Error) -> bool {
    matches!(error, tokio_tungstenite::tungstenite::Error::Http(response)
        if refused_status(response.status().as_u16()))
}

fn refused_status(status: u16) -> bool {
    matches!(status, 401 | 403)
}

#[cfg(test)]
mod tests {
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
}
