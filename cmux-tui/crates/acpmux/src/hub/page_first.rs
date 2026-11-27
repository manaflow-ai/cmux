//! Part of `Hub`; see `hub/mod.rs`. A paged session list (`_acpmux/sessions` or `_acpmux/watch`
//! with a `limit`, or a census in `orderBy` order) costs its own rows, not every chat's
//! (plans/cmux-next/acpmux-audit.md, finding 7).
//!
//! The page is picked first, from what paging reads of each row (`session_pages::PageRow`): this
//! daemon's sessions' `updatedAt` and `status` from their metadata, and the peers' mirrored rows
//! as they are kept, none copied. Only the picked rows are built: a closed one from its cached
//! bytes (`closed_rows.rs`), a live one now, a peer's as a list shows it. On 2026-11-11 a daemon
//! with 11,236 chats (10,874 closed) took 5.4 s for `ls --limit 5` and 6.1-7.3 s for
//! `ls --limit 1000`, when a page was cut from a shared build of every row.
//!
//! A newest-first page by `limit` with the closed rows in it (the app's first page) is picked from
//! a window of this daemon's rows kept in list order (`list_order.rs`) and the peers' rows that
//! sort among them, so it sorts no chat and reads about its own rows: on 2026-11-12 sorting every
//! chat for it made an 11,000-chat daemon's first page 1.36x a 525-chat one's (#42131).
//!
//! A read with no `limit` (the whole list, a filter of it, its byte pages, ACP's `session/list`)
//! is picked the same way ([`ListRows`], `list_guard::bounded`): the rows it sends are built as
//! they go, and it stops at its page's bytes. Leo, 2026-11-12: "Delete the pacer, the snapshot
//! variants, watch_delta.rs and Known."

#[cfg(test)]
use super::list_guard::BuiltRow;
use super::session_pages::{PageRow, Picked, pick_page};
use super::*;

/// A row a session list may show, before it is built.
pub(crate) struct Unbuilt {
    source: Source,
    updated_at: u64,
    status: Option<&'static str>,
    /// This daemon's session is neither a side chat nor started by another chat's agent: true
    /// until [`ListRows::mark_top_level`] reads it, which only a `topLevelOnly` read asks for
    /// (its parent's state is a second lookup a plain list never pays).
    top_level: bool,
}

enum Source {
    /// This daemon's session.
    Own(Arc<Session>),
    /// A peer's mirrored row (or a hub machine's, `mesh_book.rs`).
    Peer(Arc<RemoteSession>),
    /// This daemon's chat that left memory (`evict.rs`): its kept row.
    Evicted(Arc<super::evict::Evicted>),
}

impl Unbuilt {
    fn local(session: Arc<Session>) -> Self {
        let (updated_at, status) = session.read_meta(|m| (m.updated_at, m.status.as_str()));
        Self { source: Source::Own(session), updated_at, status: Some(status), top_level: true }
    }

    /// This daemon's session where the kept order placed it (`list_order.rs`), by the `updatedAt`
    /// it was placed by: a window of the order stays in its order.
    fn placed(row: super::list_order::OrderRow, updated_at: u64) -> Self {
        match row {
            super::list_order::OrderRow::Own(session) => {
                let status = session.read_meta(|m| m.status.as_str());
                Self {
                    source: Source::Own(session),
                    updated_at,
                    status: Some(status),
                    top_level: true,
                }
            }
            super::list_order::OrderRow::Evicted(row) => Self::evicted(row),
        }
    }

    /// A row of the kept order as it is now, by its own `updatedAt`.
    fn unplaced(row: super::list_order::OrderRow) -> Self {
        match row {
            super::list_order::OrderRow::Own(session) => Self::local(session),
            super::list_order::OrderRow::Evicted(row) => Self::evicted(row),
        }
    }

    fn evicted(row: Arc<super::evict::Evicted>) -> Self {
        let (updated_at, status) = (row.updated_at(), row.status().as_str());
        Self { source: Source::Evicted(row), updated_at, status: Some(status), top_level: true }
    }

    fn mirrored(row: Arc<RemoteSession>) -> Self {
        let updated_at = row.summary.updated_ms();
        Self { source: Source::Peer(row), updated_at, status: None, top_level: true }
    }
}

impl PageRow for Unbuilt {
    fn session_id(&self) -> &str {
        match &self.source {
            Source::Own(session) => &session.id,
            Source::Evicted(row) => row.id(),
            Source::Peer(row) => row.summary.session_id().unwrap_or(""),
        }
    }

    fn updated_ms(&self) -> u64 {
        self.updated_at
    }

    fn peer(&self) -> Option<&str> {
        match &self.source {
            Source::Own(_) | Source::Evicted(_) => None,
            Source::Peer(row) => row.summary.peer(),
        }
    }

    fn status(&self) -> Option<&str> {
        match &self.source {
            Source::Own(_) | Source::Evicted(_) => self.status,
            Source::Peer(row) => row.summary.status(),
        }
    }

    fn top_level(&self) -> bool {
        match &self.source {
            Source::Own(_) | Source::Evicted(_) => self.top_level,
            Source::Peer(row) => row.summary.top_level(),
        }
    }
}

/// Every row a list read may show, in list order, none built yet: what a read with no `limit` picks
/// its rows from, and builds only those it sends.
pub(crate) struct ListRows {
    rows: Vec<Unbuilt>,
    states: HashMap<String, &'static str>,
}

impl ListRows {
    /// Reads whether each of this daemon's rows is top level, as its summary would say
    /// (`session_order::top_level_summary`): no live `side` tag, no sub-session link
    /// (`startedBy`), no listed parent (`spawnedBy`, [`Hub::spawned_by_session`]). Only for a read
    /// with `topLevelOnly`; a peer's row carries its own answer, and an evicted chat's is read
    /// from the row it kept when it left memory.
    fn mark_top_level(&mut self, hub: &Hub, params: &Value) -> Result<(), RpcError> {
        if !super::session_pages::bool_filter(params, "topLevelOnly")? {
            return Ok(());
        }
        for row in &mut self.rows {
            if let Source::Evicted(kept) = &row.source {
                let kept = serde_json::from_str::<Value>(&kept.row_text(false));
                row.top_level =
                    kept.map_or(true, |kept| crate::session_order::top_level_summary(&kept));
                continue;
            }
            let Source::Own(session) = &row.source else { continue };
            let own_child = session.read_meta(|m| {
                let now = crate::store::now_ms();
                m.subsession.as_ref().is_some_and(|link| !link.started_by.is_empty())
                    || m.tags
                        .get(super::btw::SIDE_TAG)
                        .is_some_and(|tag| tag.expires_at.is_none_or(|expires| expires > now))
            });
            row.top_level = !own_child && hub.spawned_by_session(session).is_none();
        }
        Ok(())
    }

    /// The rows, newest first, as `session_pages::sort_session_summaries` sorts them.
    pub(crate) fn rows(&self) -> &[Unbuilt] {
        &self.rows
    }

    /// `row` as the list shows it, with tools when `with_tools`.
    pub(crate) fn value(&self, hub: &Hub, row: &Unbuilt, with_tools: bool) -> Value {
        match &row.source {
            Source::Own(session) => hub.cached_closed_summary(session, with_tools),
            Source::Evicted(row) => {
                serde_json::from_str(&row.row_text(with_tools)).unwrap_or(Value::Null)
            }
            // Parsed from the text the list writes (`peer_row.rs`), its tools left out unless
            // `with_tools`.
            Source::Peer(row) => {
                serde_json::from_str(&self.peer_text(row, with_tools)).unwrap_or(Value::Null)
            }
        }
    }

    /// Peer row `row` as the list writes it, with tools when `with_tools`: its own text, no parse.
    fn peer_text(&self, row: &RemoteSession, with_tools: bool) -> String {
        super::peers::listed_remote_text(row, &self.states, with_tools)
    }

    /// [`Self::value`], serialized: a closed row of this daemon's is its cached bytes, unparsed.
    pub(crate) fn text(&self, hub: &Hub, row: &Unbuilt, with_tools: bool) -> Arc<str> {
        match &row.source {
            Source::Own(session) => hub.own_row_text(session, with_tools),
            Source::Evicted(row) => row.row_text(with_tools),
            Source::Peer(row) => self.peer_text(row, with_tools).into(),
        }
    }
}

impl Hub {
    /// Every row a list may show, sorted, none built: this daemon's (only its live ones when
    /// `live_only`) and, unless `own_only`, the peers' and the hub machines' (`live_only`: not the
    /// closed ones).
    pub(crate) fn list_rows(&self, live_only: bool, own_only: bool) -> ListRows {
        // A closed session's row is left out anyway: its handle is not even read.
        let own = if live_only { self.live_session_handles() } else { self.session_handles() };
        // This daemon's rows first, then the peers', then the hub machines': of two rows that
        // sort alike, the one a whole list puts first stays first (a stable sort).
        let mut rows: Vec<Unbuilt> = own.into_iter().map(Unbuilt::local).collect();
        // The chats that left memory: listed from their kept rows (`evict.rs`).
        rows.extend(
            self.evicted
                .rows()
                .into_iter()
                .filter(|row| !live_only || row.status() != SessionStatus::Closed)
                .map(Unbuilt::evicted),
        );
        if !own_only {
            // The peers' rows in list order from their index (`remote_rows.rs`): a live list reads
            // no closed row.
            let remote = self.remote_sessions.snapshot();
            rows.extend(remote.in_order(None, live_only).cloned().map(Unbuilt::mirrored));
            drop(remote);
            let open = |r: &RemoteSession| !live_only || !r.summary.closed();
            rows.extend(self.mesh_book_rows(open).into_iter().map(Unbuilt::mirrored));
        }
        sort_rows(&mut rows);
        let states = if own_only { HashMap::new() } else { self.peer_link_states() };
        ListRows { rows, states }
    }

    /// The page `params` picks, and the rows it is picked from. A newest-first page by `limit`
    /// (the app's first page and each after it, a live list's pages) is picked from a window of
    /// the list from its cursor: this daemon's rows from the kept order (`list_order.rs`, or its
    /// live rows for a live list) and the peers' from their index (`remote_rows.rs`), the rows it
    /// may hold and some more, not every chat. A window too short for the page (filters left too
    /// few of its rows) is read again four times longer, until the page is full or the list ends.
    /// Any other page is picked from every row.
    fn picked_page(&self, params: &Value) -> Result<(ListRows, Picked), RpcError> {
        let ordered = params.get("orderBy").is_some_and(|order| !order.is_null());
        let limit = params.get("limit").and_then(Value::as_u64);
        let limit = limit.and_then(|limit| usize::try_from(limit).ok());
        let from = super::session_pages::page_from(params);
        if let (Some(limit), Some(from)) = (limit, from)
            && !ordered
        {
            let open_only = excludes_closed(params);
            let mut most = limit.saturating_add(WINDOW_ROOM);
            loop {
                // A page starts past its cursor's row, found by its `updatedAt` and id key: many
                // rows of one `updatedAt` may come before it. The window holds it, or has passed
                // its `updatedAt` (it moved or went: the page starts at the first row no newer,
                // as a pick from every row does). Before, a window of only that `updatedAt` started
                // pages at its first row, and they repeated it (#42131 review, F1).
                let Window { mut list, all, past } = self.window(from, most, open_only);
                list.mark_top_level(self, params)?;
                let named = |row: &Unbuilt| super::session_pages::names_cursor(params, row);
                let reached = from.is_none() || past || list.rows().iter().any(named);
                let picked = pick_page(list.rows(), params)?;
                // A cursor for the rest: the window held more of the page's rows than it takes.
                if all || (reached && picked.next.as_ref().is_some_and(|next| !next.is_null())) {
                    return Ok((list, picked));
                }
                most = most.saturating_mul(4);
            }
        }
        let mut list = self.list_rows(excludes_closed(params), false);
        list.mark_top_level(self, params)?;
        let picked = pick_page(list.rows(), params)?;
        Ok((list, picked))
    }

    /// The first `most` rows of the list from `from` (no closed one when `open_only`), sorted:
    /// at most `most` of this daemon's and `most` of the peers', each read in order from where
    /// `from` starts, and the hub machines' from there. Costs `most`, not the list.
    fn window(&self, from: Option<u64>, most: usize, open_only: bool) -> Window {
        let (own, own_all) = if open_only {
            self.own_live_from(from, most)
        } else {
            let (own, all) = self.own_rows_from(from, most);
            (own.into_iter().map(|(s, at)| Unbuilt::placed(s, at)).collect(), all)
        };
        let mut rows = own;
        let remote = self.remote_sessions.snapshot();
        let before = rows.len();
        rows.extend(remote.in_order(from, open_only).take(most).cloned().map(Unbuilt::mirrored));
        let remote_all = rows.len() - before < most;
        drop(remote);
        let within = |r: &RemoteSession| {
            from.is_none_or(|from| r.summary.updated_ms() <= from)
                && (!open_only || !r.summary.closed())
        };
        rows.extend(self.mesh_book_rows(within).into_iter().map(Unbuilt::mirrored));
        sort_rows(&mut rows);
        let all = own_all && remote_all && rows.len() <= most;
        rows.truncate(most);
        let past = rows.last().is_some_and(|row| from.is_some_and(|from| row.updated_at < from));
        Window { list: ListRows { rows, states: self.peer_link_states() }, all, past }
    }

    /// At most `most` of this daemon's live rows in list order from the first no newer than
    /// `from`, and whether they are all of them: the live rows are few, read from their index
    /// (`live_session_ids`), none closed, with the chats that left memory open (`evict.rs`), as
    /// [`Self::list_rows`] lists them.
    fn own_live_from(&self, from: Option<u64>, most: usize) -> (Vec<Unbuilt>, bool) {
        let evicted = self
            .evicted
            .rows()
            .into_iter()
            .filter(|row| row.status() != SessionStatus::Closed)
            .map(Unbuilt::evicted);
        let mut rows: Vec<Unbuilt> = self
            .live_session_handles()
            .into_iter()
            .map(Unbuilt::local)
            .chain(evicted)
            .filter(|row| from.is_none_or(|from| row.updated_at <= from))
            .collect();
        sort_rows(&mut rows);
        let all = rows.len() < most;
        rows.truncate(most);
        (rows, all)
    }

    /// The page `params` asks for (`session_pages::pick_page`: filters, cursor, order and
    /// `limit`), picked, none of its rows built yet: [`Hub::session_page_text`] builds them as its
    /// reply's bytes take them.
    pub(crate) fn session_page(&self, params: &Value) -> Result<PickedPage, RpcError> {
        let fields = row_fields(params)?;
        let (list, Picked { rows, next }) = self.picked_page(params)?;
        Ok(PickedPage { list, rows, next, fields, made: Default::default() })
    }

    /// `page`'s reply text: its rows in reply order, each built (with tools when `with_tools`)
    /// only when it goes, as many as fit in `budget` bytes, at least one, with the `nextCursor` of
    /// the rest (`list_guard::cut_page` cuts the same way). A row larger than `budget` alone is
    /// trimmed (`list_guard::fit_row`).
    ///
    /// Rows are built as the bytes take them, not every picked row first: `acpmux ls` asks for
    /// pages of 1000 rows and more, of which a page of 4 KB rows sends about 260 in its 1 MB, and
    /// building every picked row first made each page cost up to 1000 rows, and a whole list of
    /// N rows about N²/520 row builds (docs/findings/2026-11-23-acpmux-cli-startup-tax.md in
    /// cmuxterm-hq: 355 ms for 833 rows). A row built for a larger `budget` is not built again
    /// for a smaller one (`list_reply.rs` `within_limit`).
    pub(crate) fn session_page_text(
        &self,
        page: &PickedPage,
        params: &Value,
        with_tools: bool,
        budget: usize,
    ) -> String {
        let mut next = page.next.clone();
        let (mut texts, mut used) = (Vec::<Arc<str>>::with_capacity(64), 0_usize);
        let mut last: Option<&Unbuilt> = None;
        for &at in &page.rows {
            let Some(row) = page.list.rows().get(at) else { continue };
            let text = page
                .made
                .borrow_mut()
                .entry(at)
                .or_insert_with(|| match &page.fields {
                    // Only the members `fields` keeps (`row_fields`), not the whole row.
                    Some(fields) => only_fields(page.list.value(self, row, with_tools), fields)
                        .to_string()
                        .into(),
                    None => page.list.text(self, row, with_tools),
                })
                .clone();
            let text: Arc<str> = match super::list_guard::fit_row(&text, row, budget) {
                std::borrow::Cow::Borrowed(_) => text,
                std::borrow::Cow::Owned(fitted) => fitted.into(),
            };
            // One more byte for the comma between rows.
            let total = used.saturating_add(text.len()).saturating_add(1);
            if let Some(last) = last
                && total > budget
            {
                next = Some(Value::String(super::list_guard::page_cursor(params, last)));
                break;
            }
            used = total;
            texts.push(text);
            last = Some(row);
        }
        super::list_guard::page_text(next.map(|next| next.to_string()), &texts)
    }

    /// The rows of the page `params` asks for (`session_pages::pick_page`: filters, cursor, order
    /// and `limit`), each built, with tools when `with_tools`, in reply order, and the page's
    /// `nextCursor`. No row outside the page is built.
    #[cfg(test)]
    pub(crate) fn session_page_rows(
        &self,
        params: &Value,
        with_tools: bool,
    ) -> Result<(Vec<BuiltRow>, Option<Value>), RpcError> {
        let fields = row_fields(params)?;
        let (list, Picked { rows: picked, next }) = self.picked_page(params)?;
        let built = picked
            .iter()
            .filter_map(|&at| list.rows().get(at))
            .map(|row| match (&row.source, &fields) {
                (Source::Own(_) | Source::Evicted(_), None) => {
                    BuiltRow::Tree(list.value(self, row, with_tools))
                }
                (Source::Peer(peer), None) => {
                    BuiltRow::Peer(list.peer_text(peer, with_tools), peer.clone())
                }
                (_, Some(fields)) => {
                    BuiltRow::Tree(only_fields(list.value(self, row, with_tools), fields))
                }
            })
            .collect();
        Ok((built, next))
    }

    /// The reply text of a list read with no `limit` (`params`: the whole list, a filter of it,
    /// or a byte page by its `h` cursor) of this daemon's rows and, unless `own_only`, the
    /// peers': at most `budget` bytes of rows (`list_guard::bounded`), each built as it goes.
    pub(crate) fn session_list_text(
        &self,
        params: &Value,
        with_tools: bool,
        own_only: bool,
        budget: usize,
    ) -> Result<String, RpcError> {
        if let Some(text) = self.indexed_list_text(params, with_tools, own_only, budget) {
            return Ok(text);
        }
        let mut list = self.list_rows(excludes_closed(params), own_only);
        list.mark_top_level(self, params)?;
        let text = |row: &Unbuilt| list.text(self, row, with_tools);
        super::list_guard::bounded(list.rows(), text, params, budget)
    }
}

impl Hub {
    /// [`Self::session_list_text`] of the whole list with no filter (no `peer`, `status`,
    /// `localOnly` or `excludeStatus`; no cursor, or a byte page's `h` cursor), read from the
    /// indexes: the newest rows while the list fits in `budget` (`list_order.rs`,
    /// `remote_rows.rs` list order), else the byte page from its cursor in page-key order
    /// (the same indexes by `session_pages::page_key_of`). It reads the rows it sends and a
    /// window more, never a clone, hash and sort of every row as `list_guard::bounded` does: a
    /// whole read of 10,000 chats sorted all of them for each of its 27 pages. None: a read this
    /// does not cover, which `bounded` answers as before.
    fn indexed_list_text(
        &self,
        params: &Value,
        with_tools: bool,
        own_only: bool,
        budget: usize,
    ) -> Option<String> {
        if !plain_whole(params) {
            return None;
        }
        let cursor = match params.get("cursor") {
            None | Some(Value::Null) => None,
            Some(_) => Some(super::session_pages::hash_cursor(params)?),
        };
        let states = if own_only { HashMap::new() } else { self.peer_link_states() };
        let list = ListRows { rows: Vec::new(), states };
        let fit = |row: &Unbuilt| -> String {
            let text = list.text(self, row, with_tools);
            super::list_guard::fit_row(&text, row, budget).into_owned()
        };
        // The rows the newest-first try built, by row: a first page of a list too big to send
        // whole is mostly the same rows, and building a row is most of a page's cost.
        let mut built = HashMap::new();
        if cursor.is_none() {
            match self.newest_whole(own_only, budget, &fit) {
                Ok(whole) => return Some(super::list_guard::page_text(None, &whole)),
                Err(rows) => built = rows,
            }
        }
        let mut most = BYTE_WINDOW;
        loop {
            let (rows, complete) = self.keyed_window(cursor, most, own_only);
            let (mut page, mut used, mut last) = (Vec::new(), 0_usize, None);
            let mut ended = true;
            for (hash, row) in &rows {
                let text = built.remove(&row_pair(row)).unwrap_or_else(|| fit(row));
                let total = used.saturating_add(text.len()).saturating_add(1);
                if last.is_some_and(|last| last != *hash) && total > budget {
                    ended = false;
                    break;
                }
                (used, last) = (total, Some(*hash));
                page.push(text);
            }
            if !ended || complete {
                let more = !ended || (complete && page.len() < rows.len());
                let next = more.then(|| format!("h{:032x}", last.unwrap_or_default()));
                let next = next.map(|next| Value::String(next).to_string());
                return Some(super::list_guard::page_text(next, &page));
            }
            // The window ran out before the page's bytes did: a longer one.
            most = most.saturating_mul(4);
        }
    }

    /// Every row newest first, as a list that fits sends it, when it fits in `budget`; else
    /// the rows it built before they passed it, by row ([`row_pair`]). Reads in growing windows
    /// of the kept orders, so a big list stops at its first budget's worth of rows.
    fn newest_whole(
        &self,
        own_only: bool,
        budget: usize,
        fit: &dyn Fn(&Unbuilt) -> String,
    ) -> Result<Vec<String>, HashMap<RowPair, String>> {
        let mut most = BYTE_WINDOW;
        let mut built: HashMap<RowPair, String> = HashMap::new();
        loop {
            let (rows, all) = if own_only {
                let (own, all) = self.own_rows_from(None, most);
                (own.into_iter().map(|(s, at)| Unbuilt::placed(s, at)).collect::<Vec<_>>(), all)
            } else {
                let Window { list, all, .. } = self.window(None, most, false);
                (list.rows, all)
            };
            let (mut page, mut used) = (Vec::new(), 0_usize);
            for row in &rows {
                let pair = row_pair(row);
                let text = built.remove(&pair).unwrap_or_else(|| fit(row));
                used = used.saturating_add(text.len()).saturating_add(1);
                if used > budget {
                    built.insert(pair, text);
                    built.extend(page.into_iter().zip(&rows).map(|(t, r)| (row_pair(r), t)));
                    return Err(built);
                }
                page.push(text);
            }
            if all {
                return Ok(page);
            }
            // A longer window starts again from its newest row: keep what this one built.
            built.extend(page.into_iter().zip(&rows).map(|(t, r)| (row_pair(r), t)));
            most = most.saturating_mul(4);
        }
    }

    /// The rows past page key `after` in page-key order (ties by session id, then peer, one
    /// row a pair), as `session_pages::byte_page` orders them: at most `most` of this daemon's
    /// and `most` of the peers', cut where the first source that was not read to its end
    /// stops (a row past there may lie in it), and the hub machines' past `after`. True when
    /// every source was read to its end.
    fn keyed_window(
        &self,
        after: Option<u128>,
        most: usize,
        own_only: bool,
    ) -> (Vec<(u128, Unbuilt)>, bool) {
        let (own, own_all) = self.own_rows_by_key(after, most);
        let mut bound = (!own_all).then(|| own.last().map_or(0, |(key, _)| *key));
        let mut rows: Vec<(u128, Unbuilt)> =
            own.into_iter().map(|(key, row)| (key, Unbuilt::unplaced(row))).collect();
        if !own_only {
            let remote = self.remote_sessions.snapshot();
            let peers: Vec<(u128, Arc<RemoteSession>)> =
                remote.by_page_key(after).take(most).map(|(key, r)| (key, r.clone())).collect();
            drop(remote);
            if peers.len() == most {
                let last = peers.last().map_or(0, |(key, _)| *key);
                bound = Some(bound.map_or(last, |bound| bound.min(last)));
            }
            rows.extend(peers.into_iter().map(|(key, r)| (key, Unbuilt::mirrored(r))));
            let key = |r: &RemoteSession| {
                super::session_pages::page_key_of(
                    r.summary.session_id().unwrap_or(""),
                    r.summary.peer(),
                )
            };
            let past = |r: &RemoteSession| after.is_none_or(|after| key(r) > after);
            rows.extend(
                self.mesh_book_rows(past).into_iter().map(|r| (key(&r), Unbuilt::mirrored(r))),
            );
        }
        let pair = row_pair;
        // Stable, so of a row listed twice the first (this daemon's, then a peer's) is kept.
        rows.sort_by(|(a, ra), (b, rb)| a.cmp(b).then_with(|| pair(ra).cmp(&pair(rb))));
        rows.dedup_by(|(_, a), (_, b)| pair(a) == pair(b));
        if let Some(bound) = bound {
            rows.retain(|(key, _)| *key <= bound);
        }
        (rows, bound.is_none())
    }

    /// The rows `keys` name, as `_acpmux/sessions` writes them with `with_tools`: this daemon's
    /// session by its id ([`Hub::own_row_text`], a closed one from its cached bytes), a peer's
    /// or a hub machine's by its `PEER/ID` row key (the mirrored row, never asked of the peer).
    /// `None` for a key that names no row. Only the rows asked for are built, whatever the
    /// list's size (`_acpmux/info` with `sessionIds`, agent service v2 row 7b).
    pub(crate) fn rows_by_key(&self, keys: &[String], with_tools: bool) -> Vec<Option<Arc<str>>> {
        /// A key's row, found before any is built.
        enum Found {
            Own(Arc<Session>),
            Mirrored(Arc<RemoteSession>),
        }
        // The lookups only under the locks, one lock at a time: no row is built while a peer's
        // writer waits.
        let mut found: Vec<Option<Found>> =
            keys.iter().map(|key| self.session_by_id(key).map(Found::Own)).collect();
        {
            let remote = self.remote_sessions.read();
            for (key, found) in keys.iter().zip(found.iter_mut()) {
                if found.is_none() && key.contains('/') {
                    *found = remote.get(key.as_str()).cloned().map(Found::Mirrored);
                }
            }
        }
        let mut states = None;
        keys.iter()
            .zip(found)
            .map(|(key, found)| match found {
                Some(Found::Own(session)) => Some(self.own_row_text(&session, with_tools)),
                found => {
                    let row = match found {
                        Some(Found::Mirrored(row)) => row,
                        _ if key.contains('/') => self.mesh_book_row(key)?,
                        _ => return None,
                    };
                    let states = states.get_or_insert_with(|| self.peer_link_states());
                    Some(super::peers::listed_remote_text(&row, states, with_tools).into())
                }
            })
            .collect()
    }

    /// How many closed rows `_acpmux/sessions` with no filter lists: this daemon's `own` closed
    /// sessions and the peers' and hub machines' mirrored ones, read from their status with no
    /// row built (`ls`'s hidden line, beside a read of the live view), and of those the mirrored
    /// ones (which the v2 list does not hold: a form that walks its whole view reads v1 while
    /// any is listed).
    pub(crate) fn closed_listed(&self, own: usize) -> ClosedListed {
        // The peers' closed rows are counted as they are written (`remote_rows.rs`).
        let peers = self.remote_sessions.read().closed_count();
        let remote = peers + self.mesh_book_count(|row| row.summary.closed());
        ClosedListed { all: own + remote, remote }
    }
}

/// [`Hub::closed_listed`]: the closed rows the unfiltered list holds, and of those the ones other
/// machines list.
pub(crate) struct ClosedListed {
    pub(crate) all: usize,
    pub(crate) remote: usize,
}

/// [`Hub::window`]: the rows, whether they are every row from its start, and whether its last row
/// is older than its start.
struct Window {
    list: ListRows,
    all: bool,
    past: bool,
}

/// A page by `limit` picked ([`Hub::session_page`]): the rows it is picked from, its rows' places
/// among them in reply order, its `nextCursor` (null when the list ends there), and the rows'
/// texts built so far, by place.
pub(crate) struct PickedPage {
    list: ListRows,
    rows: Vec<usize>,
    next: Option<Value>,
    /// The members each row keeps (`row_fields`), None: every member.
    fields: Option<HashSet<String>>,
    made: std::cell::RefCell<HashMap<usize, Arc<str>>>,
}

/// The rows a window of the kept order holds past a page's `limit`: a filter or two may leave a
/// few of them out without a second read.
pub(super) const WINDOW_ROOM: usize = 64;

/// Newest first, ties by id, then by peer (this daemon's own first), as
/// `session_pages::sort_session_summaries` sorts: a stable sort, so of two rows alike the one put
/// first stays first.
fn sort_rows(rows: &mut [Unbuilt]) {
    rows.sort_by(|a, b| {
        b.updated_at
            .cmp(&a.updated_at)
            .then_with(|| a.session_id().cmp(b.session_id()))
            .then_with(|| a.peer().cmp(&b.peer()))
    });
}

/// The members a row keeps whatever `fields` names: what a page's cursor, its filters and a
/// client's row key read, and the keys a peer's masking pass knows a summary by
/// (`server/peer_text.rs` `SUMMARY_KEYS`): a row cut without `harness` and `lastSeq` would reach
/// a peer with its prompt and preview unmasked.
const KEPT_FIELDS: [&str; 7] =
    ["sessionId", "qualifiedSessionId", "peer", "updatedAt", "status", "harness", "lastSeq"];

/// A page's `fields` (`_acpmux/sessions {limit, fields: [..]}`): the top-level members each row
/// keeps (a dotted path keeps its first segment's member whole), with [`KEPT_FIELDS`]. None when
/// absent: every member. A caller that prints a few fields of a live list of 850 rows was sent
/// about 1 MB a read for them (`acpmux-ls-paged`, 2026-11-19).
fn row_fields(params: &Value) -> Result<Option<HashSet<String>>, RpcError> {
    let invalid = || RpcError::invalid_params("fields must be an array of strings");
    match params.get("fields") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(fields)) => {
            let mut kept: HashSet<String> = KEPT_FIELDS.iter().map(|f| (*f).to_owned()).collect();
            for field in fields {
                let field = field.as_str().ok_or_else(invalid)?;
                kept.insert(field.split('.').next().unwrap_or(field).to_owned());
            }
            Ok(Some(kept))
        }
        Some(_) => Err(invalid()),
    }
}

/// `row` with only the members `fields` keeps.
fn only_fields(mut row: Value, fields: &HashSet<String>) -> Value {
    if let Some(members) = row.as_object_mut() {
        members.retain(|key, _| fields.contains(key));
    }
    row
}

/// A listed row's session id and peer (None: this daemon's): one row of the list.
type RowPair = (String, Option<String>);

fn row_pair(row: &Unbuilt) -> RowPair {
    (row.session_id().to_owned(), row.peer().map(str::to_owned))
}

/// The rows a whole read's window holds first ([`Hub::indexed_list_text`]); it grows fourfold
/// while the page's bytes outlast it.
const BYTE_WINDOW: usize = 512;

/// A whole read with no filter: no `peer`, `status`, `localOnly`, `topLevelOnly` (its rows are
/// marked by [`ListRows::mark_top_level`]) or `excludeStatus`, and no
/// cursor but a byte page's (`h` and 32 hex digits, no `~k` filter).
fn plain_whole(params: &Value) -> bool {
    let empty = |k: &str| match params.get(k) {
        None | Some(Value::Null) | Some(Value::Bool(false)) => true,
        Some(Value::String(s)) => s.is_empty(),
        Some(Value::Array(a)) => a.is_empty(),
        _ => false,
    };
    let cursor_ok = match params.get("cursor") {
        None | Some(Value::Null) => true,
        Some(_) => super::session_pages::hash_cursor(params).is_some(),
    };
    cursor_ok
        && ["peer", "status", "localOnly", "topLevelOnly", "excludeStatus"].into_iter().all(empty)
}

/// `excludeStatus` holds `closed`.
fn excludes_closed(params: &Value) -> bool {
    params
        .get("excludeStatus")
        .and_then(Value::as_array)
        .is_some_and(|values| values.iter().any(|value| value.as_str() == Some("closed")))
}

#[cfg(test)]
#[path = "page_window_tests.rs"]
mod window_tests;
