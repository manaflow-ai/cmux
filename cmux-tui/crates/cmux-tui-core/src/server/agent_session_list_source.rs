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

use std::io;
use std::ops::ControlFlow;
use std::path::Path;
use std::time::{Duration, Instant};

use acpmux_client::tokio_list::{self, ListConnection, Opened as Upgraded, Read};
use acpmux_client::wire::{ListFilter, ListView};
use acpmux_list_types::Summary;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

type Connection = ListConnection<OwnedReadHalf, OwnedWriteHalf>;

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
