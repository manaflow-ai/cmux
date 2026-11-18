//! A link's read of the peer's watch list: before the link is ready, or after it on a link that
//! follows a far restart or a path switch (`Peer::lists_after_ready`). Either way the reader
//! publishes the list once, whole, after its last page (`watch_reply!` in
//! `peer_runtime_io.rs`), then `PeerNotice::Listed`.

use super::*;

impl Peer {
    /// Whether this link reads its watch list after it is ready: a link of this instance
    /// published a whole list before and the last link ended for a far restart or a path switch
    /// (`LinkEnd::Restarting`, `Switching`), so the hub holds that list, never marked stale, and
    /// keeps it until the new one is whole. One far restart held its link 66 s in the handshake,
    /// reading 6 MB of list in 1.47 MB pages before it was ready. A first link, and one after an
    /// outage (whose rows went stale), still reads its list first: a first one's hub has none
    /// of this peer's rows to answer from, and the other follows its cursor, a small read.
    pub(super) fn lists_after_ready(&self) -> bool {
        self.whole_list.load(Ordering::SeqCst)
    }

    /// Whether the hub applied the current link's list (its `Listed` notice): until then a
    /// name missing from the rows may only not be listed yet.
    pub(crate) fn rows_listed(&self) -> bool {
        self.rows_link.load(Ordering::SeqCst) == self.link_epoch() + 1
    }

    /// Reads the watch list on link `link` (the peer's build is `build`); `sent` is the reply
    /// to the watch sent with `initialize`, when the handshake kept it (`keep_pipelined`).
    pub(super) async fn read_list(
        &self,
        link: u64,
        build: Option<&String>,
        mut sent: Option<Result<Value, RpcError>>,
    ) -> Result<(), RpcError> {
        // Without tools: an inventory is read per session, on an attachment (whose
        // `session_changed` notices carry it) or `_acpmux/info`, never in the list. With
        // them one host's list was 23 MB for 3,700 rows (2026-10-31), past the message
        // limit, and every link to it built and was refused one list before reading it
        // again without them; without them 16.6 MB. A follow is asked for as the list it
        // patches was read (`cursor_tools`).
        let watch = |tools: bool| json!({"enabled": true, "withTools": tools});
        let row_pages = build.is_some() && self.row_pages_for.lock_or_recover().as_ref() == build;
        // A link that read the list before reads only what changed since its cursor
        // (`hub/row_log.rs`), with or without tools as that list was (`first_watch`). A peer
        // that cannot follow it answers with the whole list, marked `reset`.
        let mut answered = None;
        if let Some((asked, tools)) =
            self.first_watch(build).filter(|(asked, _)| asked.get("afterSeq").is_some())
        {
            match self.watch_first(asked, link, sent.take()).await {
                Err(e) if too_large(&e) => {
                    tracing::warn!(peer = %self.name, "the watch follow is too large ({}); reading the whole list", e.message);
                }
                answer => answered = Some((answer?, tools)),
            }
        }
        let first = if answered.is_some() {
            answered
        } else if row_pages {
            tracing::info!(peer = %self.name, "the watch list needed pages of rows last time; reading it so");
            self.watch_row_pages(link).await?;
            None
        } else {
            match self.watch_first(watch(false), link, sent.take()).await {
                // A peer from before #28182 sends a whole list in one message or not at
                // all (cosmic-gray's NIGHTLY, 16.4 MB without tools, on 2026-10-30): it is
                // read in pages of a count of rows, which such a peer serves.
                Err(e) if too_large(&e) => {
                    tracing::warn!(peer = %self.name, "the watch list is too large ({}); reading it in pages", e.message);
                    self.watch_row_pages(link).await?;
                    *self.row_pages_for.lock_or_recover() = build.cloned();
                    None
                }
                answer => Some((answer?, false)),
            }
        };
        // A list too large for one message comes in pages (a peer served as Web, over
        // plain ws://, gets the whole list), and the reader publishes it once, whole, after
        // the last.
        let tools = first.as_ref().is_some_and(|(_, tools)| *tools);
        if let Some((first, tools)) = first {
            self.watch_pages(first, tools, link).await?;
        }
        // Read whole (its last page too, or the follow): the next follow is asked for as this
        // list was read.
        self.cursor_tools.store(tools, Ordering::SeqCst);
        Ok(())
    }

    /// Reads every page after the watch reply `first` with `_acpmux/sessions {cursor}` on link
    /// `link`; the reader gathers their rows (`watch_key`). A cursor given twice, or one that is
    /// not a string, is an error that ends the link, never a loop or a short list.
    async fn watch_pages(&self, first: Value, tools: bool, link: u64) -> Result<(), RpcError> {
        let (mut seen, mut next) = (HashSet::new(), page_cursor(&first)?);
        while let Some(cursor) = next {
            if !seen.insert(cursor.clone()) {
                let why = format!("the peer gave the watch page cursor {cursor:?} twice");
                return Err(RpcError::internal(why));
            }
            let params = json!({"withTools": tools, "cursor": cursor});
            let page = self.watch_request_on(method::MUX_SESSIONS, params, link).await?;
            next = page_cursor(&page)?;
        }
        Ok(())
    }

    /// [`Self::link_request_on`] for the link's watch list on link `link`, its
    /// `_acpmux/watch` or a page after it: the reader takes the reply's rows (`watch_key`).
    pub(super) async fn watch_request_on(
        &self,
        m: &str,
        params: Value,
        link: u64,
    ) -> Result<Value, RpcError> {
        self.send_request(m, params, Some(link), ListKey::Watch).await
    }
}
