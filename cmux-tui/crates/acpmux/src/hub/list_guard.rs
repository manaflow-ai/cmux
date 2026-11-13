//! Part of `Hub`; see `hub/mod.rs`. What every session list reply (`_acpmux/sessions`,
//! `_acpmux/watch`, ACP's `session/list`) is made of: the hub's event channel, whose sends stamp
//! the list positions (`row_log.rs`), and the text of a page.
//!
//! Leo, 2026-11-12: "Replace the list with a row log carrying a seq number; app and peers fetch
//! the first page (visible rows first) then follow changes from a cursor; a reconnect resumes from
//! its cursor and never refetches the list. Delete the pacer, the snapshot variants,
//! watch_delta.rs and Known."
//!
//! No list is built whole and shared, and none is paced: a page picks its rows from their keys and
//! builds only those (`page_first.rs`), a read with no `limit` builds its rows as they go and stops
//! at its page's bytes ([`bounded`]), and a follow builds the rows that changed. A request never
//! waits for its turn and is never refused for its cost; it costs its own page.

use super::session_pages::PageRow;
use super::*;
use acpmux_book::index::{ForkOf, RowKey, Summary};
use acpmux_core::life::V2;
use cmux_json::JsonSet as _;
use std::collections::{HashMap, HashSet};
use std::ops::Range;
use tokio::sync::Notify;

/// The hub's event channel. Every send is a change some list shows.
pub(crate) struct Events {
    tx: broadcast::Sender<HubEvent>,
    /// Changes that may reach any closed row: a send with no session of its own
    /// ([`Events::send`], [`Events::changed`]), a parent's tags, a session coming or going.
    /// Closed summary bytes carry this generation and their own session's
    /// (`Session::summary_gen`, [`Events::send_row`], [`Events::row_changed`]), so a change of one
    /// chat rebuilds its own row only (`Hub::cached_closed_summary`).
    pub(super) summary_generation: Arc<AtomicU64>,
    /// The list's row log (`row_log.rs`): a row change is stamped and sent under its lock, so
    /// list positions go out in their order.
    rows: std::sync::Mutex<super::row_log::RowLog>,
    /// This daemon's rows that changed with no notice (a streamed chunk's preview, an attach).
    /// Each is stamped and told (`session_changed` of kind `row`) before a list position is read
    /// next, so no cursor a client took from a notice is past a change it was never sent
    /// (#42091 F1).
    untold: std::sync::Mutex<HashSet<String>>,
    /// Records since the last list read that reach other rows: each one's session and its parent
    /// (`Hub::note_rows_reading`).
    reaching: std::sync::Mutex<Vec<(String, Option<String>)>>,
    /// This run's id for list positions: a cursor of another run is no cursor here.
    epoch: String,
    tee: std::sync::Mutex<Option<Arc<TeeHandle>>>,
}

/// A non-blocking mark channel from v1 list changes to the one v2 summary task.
pub(crate) struct TeeHandle {
    state: Arc<TeeState>,
}

impl TeeHandle {
    fn mark(&self, id: &str) {
        let mut pending = self.state.pending.lock().unwrap_or_else(|e| e.into_inner());
        pending.insert(id.to_owned());
        drop(pending);
        self.state.notify.notify_one();
    }
}

struct TeeState {
    pending: std::sync::Mutex<HashSet<String>>,
    notify: Notify,
}

impl TeeState {
    fn take(&self, limit: usize) -> Vec<String> {
        let mut pending = self.pending.lock().unwrap_or_else(|e| e.into_inner());
        let ids: Vec<String> = pending.iter().take(limit).cloned().collect();
        for id in &ids {
            pending.remove(id);
        }
        ids
    }
}

/// Installs the v1-to-v2 mark queue and returns its single draining task.
/// Marks are deduplicated under a short mutex and never wait on the writer.
pub(crate) fn start_v2_tee(
    v1: Arc<Hub>,
    v2: Arc<V2>,
) -> (Arc<TeeHandle>, impl std::future::Future<Output = ()> + Send + 'static) {
    let state = Arc::new(TeeState { pending: Default::default(), notify: Notify::new() });
    let handle = Arc::new(TeeHandle { state: Arc::clone(&state) });
    let task = async move {
        v1.wait_store().await;

        // The first walk is deliberately after the complete v1 store load. It feeds the
        // published index in bounded batches and yields between batches so startup work remains
        // responsive. A later mark always rebuilds from the current session, never from the
        // event that caused it.
        let sessions = v1.session_handles();
        for batch in sessions.chunks(256) {
            for session in batch {
                if let Some(summary) = summary_from_session(&v1, session) {
                    let _ = v2.hub.submit(summary);
                }
            }
            tokio::task::yield_now().await;
        }

        let mut expiries = HashMap::new();
        loop {
            let mut wake = std::pin::pin!(tokio::time::sleep(std::time::Duration::from_secs(1)));
            tokio::select! {
                _ = state.notify.notified() => {},
                _ = &mut wake => mark_expired(&v1, &state, &mut expiries),
            }
            let ids = state.take(256);
            if !ids.is_empty() {
                let sessions: HashMap<_, _> = v1
                    .session_handles()
                    .into_iter()
                    .map(|session| (session.id.clone(), session))
                    .collect();
                for id in ids {
                    match sessions.get(&id) {
                        Some(session) => {
                            if let Some(summary) = summary_from_session(&v1, session) {
                                let _ = v2.hub.submit(summary);
                            }
                        }
                        None => {
                            let _ = v2.hub.remove("local", &id);
                        }
                    }
                }
            }
            tokio::task::yield_now().await;
        }
    };
    (handle, task)
}

fn mark_expired(v1: &Hub, state: &TeeState, expiries: &mut HashMap<String, Option<u64>>) {
    let now = crate::store::now_ms();
    for session in v1.session_handles() {
        let next = session.read_meta(|meta| crate::hub::views::next_tag_expiry(meta, now));
        let previous = expiries.insert(session.id.clone(), next);
        if previous.flatten().is_some_and(|at| at <= now) || next.is_some_and(|at| at <= now) {
            state.pending.lock().unwrap_or_else(|e| e.into_inner()).insert(session.id.clone());
            state.notify.notify_one();
        }
    }
}

/// The bounded keyed-page provider used until chat actors own their checkpoints.
pub(crate) struct V1PageProvider {
    hub: Arc<Hub>,
}

impl V1PageProvider {
    pub(crate) fn new(hub: Arc<Hub>) -> Self {
        Self { hub }
    }
}

impl acpmux_core::hub::PageProvider for V1PageProvider {
    fn row(&self, key: &RowKey) -> Option<Arc<Summary>> {
        if key.origin.as_ref() != "local" {
            return None;
        }
        self.hub
            .session_handles()
            .into_iter()
            .find(|session| session.id == key.chat_id.as_ref())
            .and_then(|session| summary_from_session(&self.hub, &session).map(Arc::new))
    }
}

/// Converts the v1 list row once, retaining v1's extension keys in `extra` while moving the
/// durable identity and lineage edges into typed summary fields.
fn summary_from_session(v1: &Hub, session: &Session) -> Option<Summary> {
    let mut row = v1.session_list_summary(session);
    let object = row.as_object_mut()?;
    let meta = session.meta();
    let chat_id = object.remove("sessionId")?.as_str()?.to_owned();
    let title = object
        .remove("title")
        .and_then(|value| value.as_str().map(str::to_owned))
        .unwrap_or_else(|| meta.name.clone());
    let harness = object.remove("harness").and_then(|value| value.as_str().map(str::to_owned))?;
    let state = object
        .remove("state")
        .or_else(|| object.remove("status"))
        .and_then(|value| value.as_str().map(str::to_owned))?;
    let last_activity = object.remove("updatedAt").and_then(|value| value.as_u64()).unwrap_or(0);
    let unread_turns = object.remove("unreadTurns").and_then(|value| value.as_u64()).unwrap_or(0);
    let unread = object.remove("unread").and_then(|value| value.as_bool()).unwrap_or(false);
    let workspace = object.remove("workspaceId").and_then(|value| {
        (!value.is_null()).then(|| value.as_str().unwrap_or_default().to_owned())
    });
    let cwd = object.remove("cwd").and_then(|value| value.as_str().map(str::to_owned));
    let parent = crate::hub::views::activity_parent_id(&meta).map(|id| RowKey::new("local", id));
    let fork_of = meta
        .parent_id
        .clone()
        .map(|id| ForkOf { key: RowKey::new("local", id), seq: meta.fork_seq.unwrap_or(0) });
    object.remove("spawnedBy");
    for key in [
        "sessionId",
        "status",
        "parent",
        "parentId",
        "forkSeq",
        "origin",
        "pinned",
        "peer",
        "stale",
    ] {
        object.remove(key);
    }
    let extra = serde_json::value::to_raw_value(&row).ok()?;
    let summary = Summary {
        chat_id,
        title,
        harness,
        state,
        last_activity,
        unread: if unread_turns == 0 && unread {
            1
        } else {
            unread_turns.min(u32::MAX as u64) as u32
        },
        workspace,
        origin: "local".to_owned(),
        pinned: false,
        peer_form: None,
        parent,
        fork_of,
        folder: cwd.map(|path| path.trim_end_matches('/').to_owned()),
        extra,
    };
    summary.prepare().ok()
}

impl Events {
    pub(super) fn new(capacity: usize) -> Self {
        Self {
            tx: broadcast::channel(capacity).0,
            summary_generation: Arc::new(AtomicU64::new(0)),
            rows: Default::default(),
            untold: Default::default(),
            reaching: Default::default(),
            epoch: super::row_log::new_epoch(),
            tee: Default::default(),
        }
    }

    pub(crate) fn install_tee(&self, tee: Arc<TeeHandle>) {
        *self.tee.lock().unwrap_or_else(|e| e.into_inner()) = Some(tee);
    }

    fn mark_tee(&self, id: &str) {
        if let Some(tee) = self.tee.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            tee.mark(id);
        }
    }

    /// Sends `event`, stamped with the list position of the row it changes, if any.
    fn stamped(&self, mut event: HubEvent) -> Result<usize, broadcast::error::SendError<HubEvent>> {
        let Some((key, gone)) = super::row_log::row_change(&event) else {
            return self.tx.send(event);
        };
        let mut rows = self.rows.lock().unwrap_or_else(|e| e.into_inner());
        event.list_seq = rows.stamp(key, gone);
        self.tx.send(event)
    }

    /// Marks `session`'s row changed with no notice a watcher hears (a streamed chunk's preview,
    /// an attach): it is stamped and told before the next list position is read
    /// ([`Self::tell_untold`]).
    fn stamp_own(&self, session: &str) {
        self.untold.lock().unwrap_or_else(|e| e.into_inner()).insert(session.to_owned());
    }

    /// Stamps and tells every row changed with no notice since the last read: a follow after
    /// it sends each as it is now, and a watcher hears each as `session_changed`.
    fn tell_untold(&self) {
        let untold = std::mem::take(&mut *self.untold.lock().unwrap_or_else(|e| e.into_inner()));
        for session in untold {
            self.tell_row(&session);
        }
    }

    /// A record of `session` (whose parent is `parent`) reached other rows: told before the next
    /// list read (`Hub::tell_reached`).
    pub(super) fn reaches(&self, session: &str, parent: Option<String>) {
        let mut reaching = self.reaching.lock().unwrap_or_else(|e| e.into_inner());
        reaching.push((session.to_owned(), parent));
    }

    pub(super) fn take_reaching(&self) -> Vec<(String, Option<String>)> {
        std::mem::take(&mut *self.reaching.lock().unwrap_or_else(|e| e.into_inner()))
    }

    /// Stamps this daemon's row `session` and tells the watchers: a change a record of another
    /// row made to it (`Hub::tell_reached`), or one no record carries.
    pub(super) fn tell_row(&self, session: &str) {
        let _ = self.stamped(super::row_log::row_event(session));
    }

    pub(super) fn list_head(&self) -> u64 {
        self.tell_untold();
        self.rows.lock().unwrap_or_else(|e| e.into_inner()).head()
    }

    pub(super) fn list_epoch(&self) -> &str {
        &self.epoch
    }

    pub(super) fn list_since(&self, after: u64) -> Option<super::row_log::Since> {
        self.tell_untold();
        self.rows.lock().unwrap_or_else(|e| e.into_inner()).since(after)
    }

    /// Marks every closed row stale, then sends `event`. A peer's event goes through
    /// [`Events::send_remote`]: sent here, it made every local closed row stale (a peer's
    /// reattach notice did).
    pub(super) fn send(
        &self,
        event: HubEvent,
    ) -> Result<usize, broadcast::error::SendError<HubEvent>> {
        debug_assert!(event.remote.is_none(), "a peer's event goes through Events::send_remote");
        self.all_rows_stale();
        if crate::server::session_change_kind(&event.record.kind).is_some()
            || event.record.kind == "purged"
        {
            self.mark_tee(&event.session_id);
        }
        self.stamped(event)
    }

    pub(super) fn subscribe(&self) -> broadcast::Receiver<HubEvent> {
        self.tx.subscribe()
    }

    /// Sends a live chat's streamed chunk ([`streamed_chunk`]): the closed rows' cached bytes stay
    /// fresh. A chunk changes only its own chat's row (its preview, `updatedAt`, sequence numbers
    /// and subagent previews), and no row of another chat reads those; a live chat's row is never
    /// cached (`Hub::cached_closed_summary`). Hundreds of chunks a second while agents stream
    /// otherwise rebuilt every closed row on every list.
    pub(super) fn send_live_stream(
        &self,
        event: HubEvent,
    ) -> Result<usize, broadcast::error::SendError<HubEvent>> {
        self.stamp_own(&event.session_id);
        self.tx.send(event)
    }

    /// Sends a peer's change ([`HubEvent::remote`], `peers.rs`): every local closed row keeps its
    /// bytes, since none reads a peer's rows.
    pub(super) fn send_remote(
        &self,
        event: HubEvent,
    ) -> Result<usize, broadcast::error::SendError<HubEvent>> {
        debug_assert!(event.remote.is_some(), "a local event goes through Events::send");
        self.stamped(event)
    }

    /// Sends a change of `session`'s own row, which no other row reads (`Hub::append`): of the
    /// closed rows' cached bytes only `session`'s go stale. A record no watcher hears as
    /// `session_changed` (a tool call, `respawn_pending`) still changes the row (its preview,
    /// `updatedAt`, `respawnPending`): it is told before the next list read, as a change no record
    /// carries is (#42091 F1).
    pub(super) fn send_row(
        &self,
        session: &Session,
        event: HubEvent,
    ) -> Result<usize, broadcast::error::SendError<HubEvent>> {
        session.summary_gen.fetch_add(1, Ordering::SeqCst);
        self.mark_tee(&session.id);
        if super::row_log::row_change(&event).is_none() {
            self.stamp_own(&session.id);
        }
        self.stamped(event)
    }

    /// A change of `session`'s own row no event carries (an attach, a start under way): only
    /// `session`'s cached closed row goes stale, and the row is told before the next list read.
    pub(super) fn row_changed(&self, session: &Session) {
        self.stamp_own(&session.id);
        session.summary_gen.fetch_add(1, Ordering::SeqCst);
        self.mark_tee(&session.id);
    }

    /// Every closed row's cached bytes go stale (a session came that may be another's parent).
    pub(super) fn all_rows_stale(&self) {
        self.summary_generation.fetch_add(1, Ordering::SeqCst);
    }

    /// A change no event carries that may reach any row (new usage warning thresholds): every
    /// closed row goes stale, and no cursor from before it can be followed (`RowLog::barrier`), so
    /// each reconnecting client reads the first page again. Before, a follow after it was empty
    /// and the client kept the rows as they were (review of #41865 at 316f5ca).
    pub(super) fn changed(&self) {
        self.all_rows_stale();
        self.rows.lock().unwrap_or_else(|e| e.into_inner()).barrier();
    }
}

/// A streamed text chunk from the agent: what [`Events::send_live_stream`] sends for a live chat.
pub(super) fn streamed_chunk(dir: &str, kind: &str) -> bool {
    dir == "in"
        && matches!(kind, "agent_message_chunk" | "agent_thought_chunk" | "user_message_chunk")
}

/// Whether a record may change another session's row: `tags` (a parent's `archived` and
/// `spawnedBy` tags decide whether its children fold under it, `Hub::spawned_by`), and a session
/// that comes or goes (a child names it as its parent). Every other record of a session changes
/// its own row only; a child's count in its parent follows its status
/// (`subsession_index::Index::generation`).
pub(super) fn reaches_other_rows(dir: &str, kind: &str) -> bool {
    dir == "mux" && matches!(kind, "tags" | "created" | "purged" | "reopened")
}

/// Where each row of a list's text is, and the paging keys of each (`at` its place).
pub(crate) type Built = (String, Vec<Range<usize>>, Vec<Value>);

/// The reply to `params` that has no `limit` (the whole list, or a filter of it), of `sorted`
/// (every row a list may show, in list order, none built), each row's text made by `text` only
/// when it goes: every row it lists, newest first, as before; or, when they come to more than
/// `budget` bytes or `params` has a page's cursor, a page of them that fits, with the
/// `nextCursor` of the rest (`session_pages::byte_page`, in an order updates do not change). It
/// builds rows until they pass `budget`, not the list: one daemon's whole list was 17 MB with
/// tools on 2026-10-30, past the message limit, and was refused whole; on 2026-11-12 one of
/// 11,000 chats took 6.77 s at p95 when it was built whole first.
pub(crate) fn bounded<R: PageRow, T: AsRef<str>>(
    sorted: &[R],
    text: impl Fn(&R) -> T,
    params: &Value,
    budget: usize,
) -> Result<String, RpcError> {
    // A page's cursor (`h...`) is byte_page's; a session list cursor (`k...`) stays a filter, as
    // before: the rows after the session it names. A page of a list a `k` cursor started carries
    // it on (`h...~k...`), so every page keeps its cutoff.
    let mut filters = params.clone();
    let (cursor, after) = match params.get("cursor") {
        None | Some(Value::Null) => (None, None),
        Some(Value::String(text)) if text.starts_with('h') => match text.split_once('~') {
            Some((page, after)) => (Some(page), Some(after)),
            None => (Some(text.as_str()), None),
        },
        Some(Value::String(text)) => (None, Some(text.as_str())),
        Some(_) => return Err(RpcError::invalid_params("cursor must be a string")),
    };
    if let Some(p) = filters.as_object_mut() {
        match after {
            Some(after) => p.insert("cursor".to_owned(), Value::String(after.to_owned())),
            None => p.remove("cursor"),
        };
    }
    let picked = super::session_pages::pick_page(sorted, &filters)?;
    let rows: Vec<&R> = picked.rows.iter().filter_map(|&at| sorted.get(at)).collect();
    // Each row is made once: the rows the whole try made are reused by its byte page.
    let made: std::cell::RefCell<HashMap<usize, String>> = Default::default();
    let row = |n: usize| -> String {
        if let Some(done) = made.borrow_mut().remove(&n) {
            return done;
        }
        let Some(&row) = rows.get(n) else { return "null".into() };
        let text = text(row);
        fit_row(text.as_ref(), row, budget).into_owned()
    };
    if cursor.is_none() {
        let (mut page, mut used) = (Vec::new(), 0_usize);
        let fits = (0..rows.len()).all(|n| {
            let text = row(n);
            used = used.saturating_add(text.len()).saturating_add(1);
            page.push(text);
            used <= budget
        });
        if fits {
            return Ok(page_text(None, &page));
        }
        made.borrow_mut().extend(page.into_iter().enumerate());
    }
    let (page, next) = super::session_pages::byte_page(&rows, cursor, budget, row, String::len)?;
    let next = next.map(|next| after.map_or_else(|| next.clone(), |k| format!("{next}~{k}")));
    Ok(page_text(next.map(|next| Value::String(next).to_string()), &page))
}

/// A page's result text, `{"nextCursor":<next>,"sessions":[<rows>]}` (no `nextCursor` when
/// `next` is `None`; `next` is already JSON), in one allocation of its exact size plus
/// [`LINE_ROOM`], so the reply line is made in it (`server/list_reply.rs` `reply_line_in`).
/// A page is megabytes: growing it by doubling, then copying it into its line, left three or
/// four freed blocks of megabytes per page, which macOS's allocator keeps (270 MB of
/// "Malloc Large (empty)" after 40 `ls` of 3000 rows, aws-m4pro-2, 2026-11-11).
pub(crate) fn page_text<R: AsRef<str>>(next: Option<String>, rows: &[R]) -> String {
    const CURSOR: &str = "\"nextCursor\":";
    const SESSIONS: &str = "\"sessions\":[";
    let rows_len: usize = rows.iter().map(|row| row.as_ref().len()).sum();
    let size = 1
        + next.as_ref().map_or(0, |next| CURSOR.len() + next.len() + 1)
        + SESSIONS.len()
        + rows_len
        + rows.len().saturating_sub(1)
        + 2;
    let mut text = String::with_capacity(size + LINE_ROOM);
    text.push('{');
    if let Some(next) = next {
        text.push_str(CURSOR);
        text.push_str(&next);
        text.push(',');
    }
    text.push_str(SESSIONS);
    for (n, row) in rows.iter().enumerate() {
        if n > 0 {
            text.push(',');
        }
        text.push_str(row.as_ref());
    }
    text.push_str("]}");
    debug_assert_eq!(text.len(), size);
    text
}

/// A paged reply's text: `rows` (paging keys, each naming its row in `text` by `at`), as many as
/// fit in `budget` bytes, at least one, and `next` (the picked page's `nextCursor`) first. A page
/// cut short by its bytes ends with the `nextCursor` of its last row, as a page of that many rows
/// would: 1000 rows of a busy host with usage were more than one message, refused whole on every
/// retry. A row larger than `budget` alone is trimmed ([`row_text`]).
pub(crate) fn cut_page(
    (text, spans): (&str, &[Range<usize>]),
    rows: &[Value],
    mut next: Option<Value>,
    params: &Value,
    budget: usize,
) -> String {
    let (mut page, mut used) = (Vec::with_capacity(rows.len()), 0_usize);
    for (n, key) in rows.iter().enumerate() {
        let row = row_text(text, spans, key, budget);
        // One more byte for the comma between rows.
        let total = used.saturating_add(row.len()).saturating_add(1);
        if n > 0 && total > budget {
            let last = rows.get(n.saturating_sub(1)).unwrap_or(key);
            next = Some(Value::String(page_cursor(params, last)));
            break;
        }
        used = total;
        page.push(row);
    }
    page_text(next.map(|next| next.to_string()), &page)
}

/// A list row built for a page (`Hub::session_page_rows`): this daemon's as a tree, or a peer's
/// as its text (`PeerRow::listed`) with its row, whose paging keys are kept typed: never parsed.
pub(crate) enum BuiltRow {
    Tree(Value),
    Peer(String, Arc<RemoteSession>),
}

impl PageRow for BuiltRow {
    fn session_id(&self) -> &str {
        match self {
            Self::Tree(row) => PageRow::session_id(row),
            Self::Peer(_, r) => r.summary.session_id().unwrap_or(""),
        }
    }

    fn updated_ms(&self) -> u64 {
        match self {
            Self::Tree(row) => PageRow::updated_ms(row),
            Self::Peer(_, r) => r.summary.updated_ms(),
        }
    }

    fn peer(&self) -> Option<&str> {
        match self {
            Self::Tree(row) => PageRow::peer(row),
            Self::Peer(_, r) => r.summary.peer(),
        }
    }

    fn status(&self) -> Option<&str> {
        match self {
            Self::Tree(row) => PageRow::status(row),
            Self::Peer(_, r) => r.summary.status(),
        }
    }
}

/// A row [`serialize_in_order`] writes: its text, and its paging keys.
pub(crate) trait InOrder {
    fn write(&self, out: &mut Vec<u8>);
    fn paging_keys(&self, at: usize) -> Value;
}

impl InOrder for Value {
    fn write(&self, out: &mut Vec<u8>) {
        // A Value always serializes, and Vec's writer cannot fail.
        let _ = serde_json::to_writer(out, self);
    }

    fn paging_keys(&self, at: usize) -> Value {
        paging_keys(self, at)
    }
}

impl InOrder for BuiltRow {
    fn write(&self, out: &mut Vec<u8>) {
        match self {
            Self::Tree(row) => row.write(out),
            Self::Peer(text, _) => out.extend_from_slice(text.as_bytes()),
        }
    }

    fn paging_keys(&self, at: usize) -> Value {
        match self {
            Self::Tree(row) => paging_keys(row, at),
            Self::Peer(_, r) => {
                let row = &r.summary;
                keys_of(at, row.session_id(), row.updated_ms(), row.peer(), row.status())
            }
        }
    }
}

/// `rows`, in the order given (not sorted), as a list's text, where each is in it, and the
/// paging keys of each (`at` its place): what [`cut_page`] cuts.
pub(crate) fn serialize_in_order<R: InOrder>(rows: &[R]) -> Built {
    let prefix = br#"{"sessions":["#;
    let mut whole = Vec::from(&prefix[..]);
    let (mut spans, mut keys) = (Vec::with_capacity(rows.len()), Vec::with_capacity(rows.len()));
    for (at, row) in rows.iter().enumerate() {
        if at > 0 {
            whole.push(b',');
        }
        let start = whole.len();
        row.write(&mut whole);
        spans.push(start..whole.len());
        keys.push(row.paging_keys(at));
    }
    whole.extend_from_slice(b"]}");
    // serde_json writes UTF-8.
    (String::from_utf8(whole).unwrap_or_default(), spans, keys)
}

/// Spare capacity a page keeps for its reply line's frame (`{"id":..,"jsonrpc":"2.0",
/// "result":` and `}\n`), so the line is made in place for any id up to about 200 bytes.
pub(crate) const LINE_ROOM: usize = 256;

/// Row `key` of `text` ([`fit_row`]).
fn row_text<'a>(
    text: &'a str,
    spans: &[Range<usize>],
    key: &Value,
    budget: usize,
) -> std::borrow::Cow<'a, str> {
    let at = key.get("at").and_then(Value::as_u64).and_then(|at| usize::try_from(at).ok());
    let Some(row) = at.and_then(|at| spans.get(at)).and_then(|span| text.get(span.clone())) else {
        return "null".into();
    };
    fit_row(row, key, budget)
}

/// `row` (whose paging keys are `key`): whole when it fits in `budget`, else trimmed to fit, its
/// largest fields first (`reply_fit.rs`), or as [`too_large_stub`] when even the fields it keeps
/// do not.
fn fit_row<'a, K: PageRow + ?Sized>(
    row: &'a str,
    key: &K,
    budget: usize,
) -> std::borrow::Cow<'a, str> {
    if row.len() <= budget {
        return row.into();
    }
    let mut value: Value = serde_json::from_str(row).unwrap_or_default();
    if super::reply_fit::fit_object(&mut value, budget) {
        value.to_string().into()
    } else {
        too_large_stub(key, row.len()).into()
    }
}

/// Row text `row` ([`fit_row`]): whole when it fits in `budget`, else trimmed to fit or a stub
/// with its keys, as a page sends a row too large for it. Parsed only when it does not fit.
pub(crate) fn fit_text(row: String, budget: usize) -> String {
    if row.len() <= budget {
        return row;
    }
    let mut value: Value = serde_json::from_str(&row).unwrap_or_default();
    let keys = paging_keys(&value, 0);
    if super::reply_fit::fit_object(&mut value, budget) {
        value.to_string()
    } else {
        too_large_stub(&keys, row.len())
    }
}

/// The cursor of the page after `last`: a census's (`orderBy`, `s:<id>`) or the list's
/// (`session_pages::cursor_after`).
fn page_cursor(params: &Value, last: &Value) -> String {
    let census = params.get("orderBy").and_then(Value::as_str).is_some_and(|o| !o.is_empty());
    if census {
        format!("s:{}", last.get("sessionId").and_then(Value::as_str).unwrap_or(""))
    } else {
        super::session_pages::cursor_after(last)
    }
}

/// A row larger than a page alone even trimmed (a kept field that large) goes as this stub, with
/// its size, as a record too large for a reply goes (`hub/paging.rs`): a page holds at least one
/// row, and one that large would be refused, page and all. It keeps the row's paging keys (an id
/// longer than 4 KiB as null), so a client still sees the chat and can read it alone
/// (`_acpmux/info`).
fn too_large_stub<K: PageRow + ?Sized>(key: &K, bytes: usize) -> String {
    let id = Some(key.session_id()).filter(|id| !id.is_empty() && id.len() <= 4 << 10);
    let updated = Some(key.updated_ms()).filter(|at| *at != 0);
    let mut stub = json!({
        "sessionId": id,
        "updatedAt": updated,
        "omitted": {"bytes": bytes, "reason": "too_large"},
    });
    for (k, v) in [("peer", key.peer()), ("status", key.status())] {
        if let Some(v) = v {
            stub.set(k, Value::String(v.to_owned()));
        }
    }
    stub.to_string()
}

/// The paging keys of `row`, at `at` in its list's text: `sessionId`, `updatedAt`, `peer` and
/// `status`, each only when it has one.
fn paging_keys(row: &Value, at: usize) -> Value {
    let text = |k: &str| row.get(k).and_then(Value::as_str);
    let updated = row.get("updatedAt").and_then(Value::as_u64).unwrap_or_default();
    keys_of(at, text("sessionId"), updated, text("peer"), text("status"))
}

/// [`paging_keys`] of a row's fields (`updatedAt` 0 as none).
fn keys_of(
    at: usize,
    id: Option<&str>,
    updated: u64,
    peer: Option<&str>,
    status: Option<&str>,
) -> Value {
    let mut keys = json!({"at": at});
    if let Some(id) = id {
        keys.set("sessionId", Value::String(id.to_owned()));
    }
    if updated != 0 {
        keys.set("updatedAt", Value::from(updated));
    }
    for (k, v) in [("peer", peer), ("status", status)] {
        if let Some(v) = v {
            keys.set(k, Value::String(v.to_owned()));
        }
    }
    keys
}

/// Where a client's request is, for a test's hold (`Hub::hold_requests_for_tests`): about to be
/// served (`server/mod.rs`), or its list reply sent from inside it (`server/list_reply.rs`)
/// built and not queued yet, or queued to the client with the request not finished yet.
#[doc(hidden)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RequestStage {
    Dispatch,
    ListBuilt,
    ListQueued,
}

/// A test's hold on requests at each [`RequestStage`], by method and id: the request waits for
/// the future it returns, and a cancel may drop it there.
#[doc(hidden)]
pub type RequestHold = Arc<
    dyn Fn(
            RequestStage,
            &str,
            &Value,
        ) -> std::pin::Pin<Box<dyn std::future::Future<Output = ()> + Send>>
        + Send
        + Sync,
>;

impl Hub {
    /// Integration-test hold on requests (`tests/cancel_list_reply.rs`): a cancel races a request
    /// at a stage the test picks, never by timing. Set once per hub; a daemon never sets it.
    #[doc(hidden)]
    pub fn hold_requests_for_tests(&self, hold: RequestHold) {
        let _ = self.list_guard.hold.set(hold);
    }

    /// Waits out a test's hold at `stage` of request `id` of method `m`, if one is set.
    pub(crate) async fn request_hold(&self, stage: RequestStage, m: &str, id: &Value) {
        if let Some(hold) = self.list_guard.hold.get() {
            hold(stage, m, id).await;
        }
    }
}

#[derive(Default)]
pub(crate) struct ListGuard {
    /// A test's hold on requests (`Hub::hold_requests_for_tests`); unset in a daemon.
    pub(crate) hold: std::sync::OnceLock<RequestHold>,
}

#[cfg(test)]
#[path = "list_guard_tests.rs"]
mod tests;

#[cfg(test)]
#[path = "list_scale_tests.rs"]
mod scale_tests;
