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
//! A read with no `limit` (the whole list, a filter of it, its byte pages, ACP's `session/list`)
//! is picked the same way ([`ListRows`], `list_guard::bounded`): the rows it sends are built as
//! they go, and it stops at its page's bytes. Leo, 2026-11-12: "Delete the pacer, the snapshot
//! variants, watch_delta.rs and Known."

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
}

impl Unbuilt {
    fn local(session: Arc<Session>) -> Self {
        let (updated_at, status) = session.read_meta(|m| (m.updated_at, m.status.as_str()));
        Self { source: Source::Own(session), updated_at, status: Some(status) }
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
            Source::Peer(row) => row.summary.session_id(),
        }
    }

    fn updated_ms(&self) -> u64 {
        self.updated_at
    }

    fn peer(&self) -> Option<&str> {
        match &self.source {
            Source::Own(_) => None,
            Source::Peer(row) => row.summary.peer(),
        }
    }

    fn status(&self) -> Option<&str> {
        match &self.source {
            Source::Own(_) => self.status,
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
            Source::Peer(row) => {
                let row = super::peers::listed_remote_row(row, &self.states);
                if with_tools { row } else { super::views::without_summary_tools(row) }
            }
        }
    }

    /// [`Self::value`], serialized: a closed row of this daemon's is its cached bytes, unparsed.
    pub(crate) fn text(&self, hub: &Hub, row: &Unbuilt, with_tools: bool) -> Arc<str> {
        match &row.source {
            Source::Own(session) => hub.own_row_text(session, with_tools),
            Source::Peer(_) => self.value(hub, row, with_tools).to_string().into(),
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
        if !own_only {
            let open = |r: &RemoteSession| !live_only || r.summary.status() != Some("closed");
            let remote = self.remote_sessions.snapshot();
            rows.extend(remote.values().filter(|r| open(&***r)).cloned().map(Unbuilt::mirrored));
            drop(remote);
            rows.extend(self.mesh_book_rows(&open).into_iter().map(Unbuilt::mirrored));
        }
        // As `session_pages::sort_session_summaries` sorts.
        rows.sort_by(|a, b| {
            b.updated_at
                .cmp(&a.updated_at)
                .then_with(|| a.session_id().cmp(b.session_id()))
                .then_with(|| a.peer().cmp(&b.peer()))
        });
        let states = if own_only { HashMap::new() } else { self.peer_link_states() };
        ListRows { rows, states }
    }

    /// The rows of the page `params` asks for (`session_pages::pick_page`: filters, cursor, order
    /// and `limit`), each built, with tools when `with_tools`, in reply order, and the page's
    /// `nextCursor`. No row outside the page is built.
    pub(crate) fn session_page_rows(
        &self,
        params: &Value,
        with_tools: bool,
    ) -> Result<(Vec<Value>, Option<Value>), RpcError> {
        let list = self.list_rows(excludes_closed(params), false);
        let Picked { rows: picked, next } = pick_page(list.rows(), params)?;
        let built = picked
            .iter()
            .filter_map(|&at| list.rows().get(at))
            .map(|row| list.value(self, row, with_tools))
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

/// `excludeStatus` holds `closed`.
fn excludes_closed(params: &Value) -> bool {
    params
        .get("excludeStatus")
        .and_then(Value::as_array)
        .is_some_and(|values| values.iter().any(|value| value.as_str() == Some("closed")))
}
