//! This crate's one list source (agent service v2, the design doc, row 7c; decision 247). A
//! list caller opens a socket of its own and asks for the upgrade naming `list` as its first
//! request (`acpmux_client::tokio_list`); an `AcpmuxLink` it holds has sent requests and cannot
//! be upgraded. The daemon is the one reader of `acpmux.v2`: on its old answer [`open`] gives
//! [`Opened::V1`] and the caller runs its v1 path whole, on a connection of its own. Each v1 path
//! is a named fallback in `agent_session_list_scan_tests.rs`.
//!
//! The callers here run on std threads, and `tokio_list` is async: a [`Source`] owns a tokio
//! current-thread runtime for as long as its connection, and gives blocking reads. One runtime
//! a source, never one a page, never shared across threads. `within` at [`open`] is one
//! deadline over the whole read: the connect and upgrade, and every page of every walk after
//! it. Past it the read is an error, never a part of the list.

use std::collections::{HashSet, VecDeque};
use std::io;
use std::ops::ControlFlow;
use std::path::Path;
use std::time::{Duration, Instant};

use acpmux_client::tokio_list::{self, KEYS_PER_PAGE, ListConnection, Opened as Upgraded, Read};
use acpmux_client::wire::{ListFilter, ListView};
use acpmux_list_types::{RowKey, Summary};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

use super::{AcpmuxLink, LinkError};

type Connection = ListConnection<OwnedReadHalf, OwnedWriteHalf>;

/// The capability of a daemon that answers rows by key (`_acpmux/info` with `sessionIds`).
pub(crate) const INFO_ROWS: &str = "info-rows-v1";

/// What [`open`] found on the socket.
pub(crate) enum Opened {
    /// The daemon serves the v2 list.
    List(Source),
    /// It does not (no v2, or `list` not in its `acpmux.v2`): the caller's v1 path, whole.
    V1,
}

/// A v2 list connection and the runtime that drives it.
pub(crate) struct Source {
    runtime: tokio::runtime::Runtime,
    connection: Box<Connection>,
    deadline: Instant,
}

/// Opens a list connection on the daemon's socket at `socket`, every read of it bounded by
/// `within` from now.
pub(crate) fn open(socket: &Path, within: Duration) -> io::Result<Opened> {
    let deadline = Instant::now() + within;
    let runtime =
        tokio::runtime::Builder::new_current_thread().enable_io().enable_time().build()?;
    let upgraded = runtime.block_on(bounded(deadline, async {
        let (reader, writer) = tokio::net::UnixStream::connect(socket).await?.into_split();
        tokio_list::open(reader, writer).await
    }))?;
    Ok(match upgraded {
        Upgraded::List(connection) => Opened::List(Source { runtime, connection, deadline }),
        // The halves are dropped here: the v1 path opens its own connection.
        Upgraded::Fallback { .. } => Opened::V1,
    })
}

/// `work`, or a timeout error at `deadline`.
async fn bounded<T>(deadline: Instant, work: impl Future<Output = io::Result<T>>) -> io::Result<T> {
    // timeout: a list read past its caller's deadline is an error, never a part of the list.
    tokio::time::timeout_at(deadline.into(), work).await.map_err(|_| {
        io::Error::new(io::ErrorKind::TimedOut, "the list read ran past its deadline")
    })?
}

impl Source {
    /// Walks `view` (narrowed by `filter`) page by page from its head, handing each page's
    /// summaries to `each` before the next page is asked; `each` may end the walk.
    pub(crate) fn walk(
        &mut self,
        view: ListView,
        filter: Option<ListFilter>,
        mut each: impl FnMut(Vec<Summary>) -> ControlFlow<()>,
    ) -> io::Result<()> {
        let Self { runtime, connection, deadline } = self;
        runtime.block_on(bounded(*deadline, async {
            let mut reading = connection.read(Read::Walk { view, filter }).await?;
            while let Some(page) = reading.next().await? {
                if each(page.rows).is_break() {
                    break;
                }
            }
            Ok(())
        }))
    }
}

/// A summary's `extra`, parsed once for every member a caller reads (empty when it is not an
/// object).
pub(crate) fn extras(summary: &Summary) -> serde_json::Map<String, serde_json::Value> {
    serde_json::from_str(summary.extra.get()).unwrap_or_default()
}

/// Whether the summary's `extra` was bounded away (the daemon writes `{}` for one too large):
/// only the chat's row, read by key, says what it held.
pub(crate) fn bounded_away(summary: &Summary) -> bool {
    summary.extra.get().trim() == "{}"
}

/// The `status` v1's row gives the summary's chat: `extra`'s when the two differ (a stuck or
/// stopping chat), else the summary's `state` (`hub/list_tee/summary.rs`). `extra` is the
/// summary's [`extras`].
pub(crate) fn v1_status(
    summary: &Summary,
    extra: &serde_json::Map<String, serde_json::Value>,
) -> String {
    extra
        .get("status")
        .and_then(serde_json::Value::as_str)
        .map_or_else(|| summary.state.clone(), str::to_owned)
}

/// One page of a `family` ask (`Read::Family`).
pub(crate) struct FamilyPage {
    pub(crate) rows: Vec<Summary>,
    /// The hot part's kin go on in the snapshot's part.
    pub(crate) cold_unread: bool,
    /// Rows of this page at the depth bound that have hot children of their own.
    pub(crate) deeper: Vec<RowKey>,
}

/// What [`kin`] asks: one `family` filter, its hot part or with `cold` the snapshot's, page by
/// page to `each`, which may end it.
pub(crate) trait Family {
    fn family(
        &mut self,
        root: &RowKey,
        cold: bool,
        each: &mut dyn FnMut(FamilyPage) -> ControlFlow<()>,
    ) -> io::Result<()>;
}

impl Family for Source {
    fn family(
        &mut self,
        root: &RowKey,
        cold: bool,
        each: &mut dyn FnMut(FamilyPage) -> ControlFlow<()>,
    ) -> io::Result<()> {
        let Self { runtime, connection, deadline } = self;
        runtime.block_on(bounded(*deadline, async {
            let mut reading = connection.read(Read::Family { root: root.clone(), cold }).await?;
            while let Some(page) = reading.next().await? {
                let deeper = page
                    .deeper
                    .iter()
                    .map(|key| RowKey::new(&*key.origin, &*key.chat_id))
                    .collect();
                let page = FamilyPage { rows: page.rows, cold_unread: page.cold_unread, deeper };
                if each(page).is_break() {
                    break;
                }
            }
            Ok(())
        }))
    }
}

/// This machine's chats under its chat `root` at any depth, through the list's one parent edge
/// (decisions 137 and 140), at most `max`, in the order the asks found them. Each ask is one
/// `family` filter: its hot part, then its snapshot part when the hot part says `coldUnread`.
/// The rows a hot part leaves out are asked for again under their own key: those under a row at
/// the depth bound (`deeper`), and those under a cold row (a cold row's own kin, hot or cold, are
/// in neither part of its parent's answer). A peer's row is never one, nor a row under one: v1's
/// readers (`agent_session_children::descendants`, `chief_work::family`) leave peers out.
///
/// With `with_cold` false no snapshot part is asked, whatever a page says (decision 301): the
/// hub says `coldUnread` whenever its snapshot is not empty, not when the key has cold kin, and
/// a cold part is the snapshot's pager, read to its end at 256 KiB a request. So a hot-only
/// read costs the hot kin alone, and a cold one about (closed rows / 400) requests a pass, for
/// 1 + (cold rows found) passes.
pub(crate) fn kin(
    list: &mut impl Family,
    root: &str,
    max: usize,
    with_cold: bool,
) -> io::Result<Vec<Summary>> {
    let root = RowKey::new("local", root);
    let mut seen = HashSet::from([root.clone()]);
    let mut left_out = HashSet::new();
    let mut asked = HashSet::new();
    let mut asks = VecDeque::from([root]);
    let mut found = Vec::new();
    while let Some(key) = asks.pop_front() {
        if found.len() >= max {
            break;
        }
        if !asked.insert(key.clone()) {
            continue;
        }
        let mut cold_unread = false;
        for cold in [false, true] {
            if cold && !(with_cold && cold_unread) {
                break;
            }
            list.family(&key, cold, &mut |page| {
                cold_unread |= page.cold_unread;
                asks.extend(page.deeper);
                for row in page.rows {
                    let row_key = RowKey::new(row.origin.as_str(), row.chat_id.as_str());
                    // A hot part is depth first, so a row's parent came before it.
                    if row.origin != "local"
                        || row.parent.as_ref().is_some_and(|parent| left_out.contains(parent))
                    {
                        left_out.insert(row_key);
                        continue;
                    }
                    if !seen.insert(row_key.clone()) {
                        continue;
                    }
                    if cold {
                        asks.push_back(row_key);
                    }
                    found.push(row);
                    if found.len() >= max {
                        return ControlFlow::Break(());
                    }
                }
                ControlFlow::Continue(())
            })?;
            if found.len() >= max {
                break;
            }
        }
    }
    Ok(found)
}

/// The rows `ids` name as `_acpmux/sessions` writes them (`_acpmux/info` with `sessionIds`, a
/// daemon that lists `info-rows-v1`), a hundred a request, each request within `within` of the
/// first; the ids past a reply's bytes are asked again. An id that names no row now (a chat
/// purged since its summary) is left out. The rows are in v1's list order.
pub(crate) fn rows_by_id(
    link: &AcpmuxLink,
    ids: Vec<String>,
    within: Duration,
) -> Result<Vec<serde_json::Value>, LinkError> {
    let deadline = Instant::now() + within;
    let mut queue: VecDeque<String> = ids.into();
    let mut rows = Vec::new();
    while !queue.is_empty() {
        let ask: Vec<String> = queue.drain(..queue.len().min(KEYS_PER_PAGE)).collect();
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err(LinkError::Timeout);
        }
        let mut reply =
            link.call("_acpmux/info", serde_json::json!({"sessionIds": ask, "row": true}), left)?;
        let Some(serde_json::Value::Array(got)) =
            reply.get_mut("rows").map(serde_json::Value::take)
        else {
            return Err(LinkError::BadList("rows by id held no rows".into()));
        };
        let rest: Vec<String> = reply
            .get("rest")
            .and_then(serde_json::Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(serde_json::Value::as_str)
            .map(str::to_owned)
            .collect();
        // A reply that answers none of what it was asked made no progress: never asked again.
        if got.is_empty() && !rest.is_empty() {
            return Err(LinkError::BadList("rows by id answered none of its ids".into()));
        }
        rows.extend(got);
        for id in rest.into_iter().rev() {
            queue.push_front(id);
        }
    }
    super::sort_newest_first(&mut rows);
    Ok(rows)
}
