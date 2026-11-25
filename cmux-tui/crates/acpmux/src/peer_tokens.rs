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
#[path = "peer_tokens_tests.rs"]
mod tests;
