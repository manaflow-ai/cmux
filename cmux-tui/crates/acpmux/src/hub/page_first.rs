//! Part of `Hub`; see `hub/mod.rs`. A paged session list (`_acpmux/sessions` or `_acpmux/watch`
//! with a `limit`, or a census in `orderBy` order) costs its own rows, not every chat's
//! (plans/cmux-next/acpmux-audit.md, finding 7).
//!
//! The page is picked first, from what paging reads of each row (`session_pages::PageRow`): this
//! daemon's sessions' `updatedAt` and `status` from their metadata, and the peers' mirrored rows
//! as they are kept, none copied. Only the picked rows are built: a closed one from its cached
//! bytes (`closed_rows.rs`), a live one now, a peer's as a list shows it. The rows, their order
//! and the cursors are those of the whole list's page (`list_guard::Snapshot`), which builds
//! every row first: on 2026-11-11 a daemon with 11,236 chats (10,874 closed) took 5.4 s for
//! `ls --limit 5` and 6.1-7.3 s for `ls --limit 1000`.

use super::list_guard::BuiltRow;
use super::session_pages::{PageRow, Picked, pick_page};
use super::*;

/// A row a session list may show, before it is built.
struct Unbuilt {
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
            Source::Peer(row) => row.summary.session_id().unwrap_or(""),
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

impl Hub {
    /// The rows of the page `params` asks for (`session_pages::pick_page`: filters, cursor, order
    /// and `limit`), each built, with tools when `with_tools`, in reply order, and the page's
    /// `nextCursor`. No row outside the page is built.
    pub(crate) fn session_page_rows(
        &self,
        params: &Value,
        with_tools: bool,
    ) -> Result<(Vec<BuiltRow>, Option<Value>), RpcError> {
        // A closed session's row is left out anyway: its handle is not even read.
        let own = if excludes_closed(params) {
            self.live_session_handles()
        } else {
            self.session_handles()
        };
        // This daemon's rows first, then the peers', then the hub machines': of two rows that
        // sort alike, the one a whole list puts first stays first (a stable sort).
        let mut rows: Vec<Unbuilt> = own.into_iter().map(Unbuilt::local).collect();
        let remote = self.remote_sessions.snapshot();
        rows.extend(remote.values().cloned().map(Unbuilt::mirrored));
        drop(remote);
        rows.extend(self.mesh_book_rows(|_| true).into_iter().map(Unbuilt::mirrored));
        // As `session_pages::sort_session_summaries` and `list_guard::RowKey::order` sort.
        rows.sort_by(|a, b| {
            b.updated_at
                .cmp(&a.updated_at)
                .then_with(|| a.session_id().cmp(b.session_id()))
                .then_with(|| a.peer().cmp(&b.peer()))
        });
        let Picked { rows: picked, next } = pick_page(&rows, params)?;
        let states = self.peer_link_states();
        let built = picked
            .iter()
            .filter_map(|&at| rows.get(at))
            .map(|row| match &row.source {
                Source::Own(session) => {
                    BuiltRow::Tree(self.cached_closed_summary(session, with_tools))
                }
                // The row's own text, not parsed (`peer_row.rs`).
                Source::Peer(row) => BuiltRow::Text(
                    super::peers::listed_remote_text(row, &states, with_tools),
                    super::list_guard::RowKey::of_peer(&row.summary, 0),
                ),
            })
            .collect();
        Ok((built, next))
    }
}

/// `excludeStatus` holds `closed`.
fn excludes_closed(params: &Value) -> bool {
    params
        .get("excludeStatus")
        .and_then(Value::as_array)
        .is_some_and(|values| values.iter().any(|value| value.as_str() == Some("closed")))
}
