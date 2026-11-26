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
        Self { source: Source::Own(session), updated_at, status: Some(status) }
    }

    /// This daemon's session where the kept order placed it (`list_order.rs`), by the `updatedAt`
    /// it was placed by: a window of the order stays in its order.
    fn placed(row: super::list_order::OrderRow, updated_at: u64) -> Self {
        match row {
            super::list_order::OrderRow::Own(session) => {
                let status = session.read_meta(|m| m.status.as_str());
                Self { source: Source::Own(session), updated_at, status: Some(status) }
            }
            super::list_order::OrderRow::Evicted(row) => Self::evicted(row),
        }
    }

    fn evicted(row: Arc<super::evict::Evicted>) -> Self {
        let (updated_at, status) = (row.updated_at(), row.status().as_str());
        Self { source: Source::Evicted(row), updated_at, status: Some(status) }
    }

    fn mirrored(row: Arc<RemoteSession>) -> Self {
        let updated_at = row.summary.updated_ms();
        Self { source: Source::Peer(row), updated_at, status: None }
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
}

/// Every row a list read may show, in list order, none built yet: what a read with no `limit` picks
/// its rows from, and builds only those it sends.
pub(crate) struct ListRows {
    rows: Vec<Unbuilt>,
    states: HashMap<String, &'static str>,
}

impl ListRows {
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
            let open = |r: &RemoteSession| !live_only || r.summary.status() != Some("closed");
            let remote = self.remote_sessions.snapshot();
            rows.extend(remote.values().filter(|r| open(r)).cloned().map(Unbuilt::mirrored));
            drop(remote);
            rows.extend(self.mesh_book_rows(open).into_iter().map(Unbuilt::mirrored));
        }
        sort_rows(&mut rows);
        let states = if own_only { HashMap::new() } else { self.peer_link_states() };
        ListRows { rows, states }
    }

    /// The page `params` picks, and the rows it is picked from. A newest-first page by `limit`
    /// of a list with its closed rows (the app's first page, and each page after it) is picked
    /// from a window of the kept order (`list_order.rs`) from its cursor: the rows it may hold
    /// and some more, not every chat. A window too short for the page (filters left too few of
    /// its rows) is read again four times longer, until the page is full or the order ends. Any
    /// other page is picked from every row.
    fn picked_page(&self, params: &Value) -> Result<(ListRows, Picked), RpcError> {
        let ordered = params.get("orderBy").is_some_and(|order| !order.is_null());
        let limit = params.get("limit").and_then(Value::as_u64);
        let limit = limit.and_then(|limit| usize::try_from(limit).ok());
        let from = super::session_pages::page_from(params);
        if let (Some(limit), Some(from)) = (limit, from)
            && !ordered
            && !excludes_closed(params)
        {
            let mut most = limit.saturating_add(WINDOW_ROOM);
            loop {
                let (own, all) = self.own_rows_from(from, most);
                // A page starts past its cursor's row, found by its `updatedAt` and id key: many
                // rows of one `updatedAt` may come before it. The window holds it, or has passed
                // its `updatedAt` (it moved or went: the page starts at the first row no newer,
                // as a pick from every row does). Before, a window of only that `updatedAt` started
                // pages at its first row, and they repeated it (#42131 review, F1).
                let past = own.last().is_some_and(|(_, at)| from.is_some_and(|from| *at < from));
                let list = self.window_rows(own, all, from);
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
        let list = self.list_rows(excludes_closed(params), false);
        let picked = pick_page(list.rows(), params)?;
        Ok((list, picked))
    }

    /// The window `own` (the kept order's rows from `from`, all of them when `all`) and the peers'
    /// rows that sort among them, sorted: the start of the list from `from`.
    fn window_rows(
        &self,
        own: Vec<(super::list_order::OrderRow, u64)>,
        all: bool,
        from: Option<u64>,
    ) -> ListRows {
        let last = if all { None } else { own.last().map(|(s, at)| (*at, s.id().to_owned())) };
        let mut rows: Vec<Unbuilt> =
            own.into_iter().map(|(s, at)| Unbuilt::placed(s, at)).collect();
        // A peer's row sorts before the window's last own row when newer, or as new and a lower id.
        let within = |r: &RemoteSession| {
            let (at, id) = (r.summary.updated_ms(), r.summary.session_id().unwrap_or(""));
            from.is_none_or(|from| at <= from)
                && last.as_ref().is_none_or(|(last_at, last_id)| {
                    at > *last_at || (at == *last_at && id < last_id.as_str())
                })
        };
        let remote = self.remote_sessions.snapshot();
        rows.extend(remote.values().filter(|r| within(r)).cloned().map(Unbuilt::mirrored));
        drop(remote);
        rows.extend(self.mesh_book_rows(within).into_iter().map(Unbuilt::mirrored));
        sort_rows(&mut rows);
        ListRows { rows, states: self.peer_link_states() }
    }

    /// The page `params` asks for (`session_pages::pick_page`: filters, cursor, order and
    /// `limit`), picked, none of its rows built yet: [`Hub::session_page_text`] builds them as its
    /// reply's bytes take them.
    pub(crate) fn session_page(&self, params: &Value) -> Result<PickedPage, RpcError> {
        let (list, Picked { rows, next }) = self.picked_page(params)?;
        Ok(PickedPage { list, rows, next, made: Default::default() })
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
                .or_insert_with(|| page.list.text(self, row, with_tools))
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
        let (list, Picked { rows: picked, next }) = self.picked_page(params)?;
        let built = picked
            .iter()
            .filter_map(|&at| list.rows().get(at))
            .map(|row| match &row.source {
                Source::Own(_) | Source::Evicted(_) => {
                    BuiltRow::Tree(list.value(self, row, with_tools))
                }
                Source::Peer(peer) => {
                    BuiltRow::Peer(list.peer_text(peer, with_tools), peer.clone())
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
        let list = self.list_rows(excludes_closed(params), own_only);
        let text = |row: &Unbuilt| list.text(self, row, with_tools);
        super::list_guard::bounded(list.rows(), text, params, budget)
    }
}

impl Hub {
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
        let closed = |row: &RemoteSession| row.summary.status() == Some("closed");
        let peers = self.remote_sessions.read().values().filter(|row| closed(row)).count();
        let remote = peers + self.mesh_book_count(closed);
        ClosedListed { all: own + remote, remote }
    }
}

/// [`Hub::closed_listed`]: the closed rows the unfiltered list holds, and of those the ones other
/// machines list.
pub(crate) struct ClosedListed {
    pub(crate) all: usize,
    pub(crate) remote: usize,
}

/// A page by `limit` picked ([`Hub::session_page`]): the rows it is picked from, its rows' places
/// among them in reply order, its `nextCursor` (null when the list ends there), and the rows'
/// texts built so far, by place.
pub(crate) struct PickedPage {
    list: ListRows,
    rows: Vec<usize>,
    next: Option<Value>,
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

/// `excludeStatus` holds `closed`.
fn excludes_closed(params: &Value) -> bool {
    params
        .get("excludeStatus")
        .and_then(Value::as_array)
        .is_some_and(|values| values.iter().any(|value| value.as_str() == Some("closed")))
}
