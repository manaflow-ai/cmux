//! `_acpmux/chats_window` and `_acpmux/chats_window_close`: a connection's windows over the chat
//! index (`chats/window.rs`), kept current by one task per connection.
//!
//! - `_acpmux/chats_window {window, query?, harness?, folder?, account?, limit?, topLevel?,
//!   exclude?, keys?}` opens the window or replaces its spec, and answers `{window, ready}`. The
//!   rows travel as `_acpmux/chats_window_changed {window, revision, full: true, keys, rows,
//!   hasMore}`, queued before the answer, on the same ordered path as every later diff.
//! - Each index change or chat activity change then recomputes the connection's windows, and each
//!   window that shows something new gets `_acpmux/chats_window_changed {window, revision,
//!   full: false, keys, rows, hasMore}`: its keys in order and only the rows whose value changed.
//!   The revision goes up by one per message of that window. A client that sees a revision gap,
//!   or an `_acpmux/lagged` (the connection dropped a notification), opens the window again.
//! - `_acpmux/chats_window_close {window}` stops it.
//!
//! Owned (R6): the connection's one task ends when its connection closes, when its last window
//! closes (a later open starts a new one), and with the runtime at daemon exit; a drop guard
//! counts it out on every path (`live_tasks`).
//!
//! The state is level-triggered: a window is recomputed from the index as it is now, so a lagged
//! or coalesced change can never leave a window behind.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex};

use serde_json::{Value, json};
use tokio::sync::broadcast::error::RecvError;

use super::Conn;
use crate::chats::{ChatService, WindowSpec, WindowState};
use crate::hub::Hub;
use crate::rpc::{Message, RpcError};

/// A connection's chat windows.
#[derive(Default)]
pub(super) struct ConnWindows {
    /// Held while a recompute sends, so every window's messages leave in revision order.
    windows: StdMutex<Windows>,
    /// Wakes the connection's task after a chat activity change or a close.
    wake: tokio::sync::Notify,
}

#[derive(Default)]
struct Windows {
    by_name: BTreeMap<String, WindowState>,
    /// The connection's task runs. Set and cleared under this lock, so an open never misses a
    /// task that is ending, and a task never ends with a window open.
    task: bool,
}

/// Window tasks alive in this process (tests check that none outlives its connection).
static LIVE_TASKS: AtomicUsize = AtomicUsize::new(0);

/// How many chat window tasks are alive in this process.
pub fn live_tasks() -> usize {
    LIVE_TASKS.load(Ordering::Acquire)
}

/// Counts one task out however it ends: return, connection close, or cancel at runtime drop.
struct Live;

impl Live {
    fn new() -> Self {
        LIVE_TASKS.fetch_add(1, Ordering::AcqRel);
        Self
    }
}

impl Drop for Live {
    fn drop(&mut self) {
        LIVE_TASKS.fetch_sub(1, Ordering::AcqRel);
    }
}

fn lock<T>(mutex: &StdMutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

impl ConnWindows {
    fn is_empty(&self) -> bool {
        lock(&self.windows).by_name.is_empty()
    }
}

/// `_acpmux/chats_window`.
pub(super) async fn open(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    service: Option<Arc<ChatService>>,
    params: &Value,
) -> Result<Value, RpcError> {
    let spec = WindowSpec::from_params(params).map_err(RpcError::invalid_params)?;
    let window = spec.window.clone();
    {
        let mut windows = lock(&conn.chat_windows.windows);
        let revision = windows.by_name.get(&window).map_or(0, WindowState::revision);
        windows.by_name.insert(window.clone(), WindowState::new(spec, revision));
    }
    let Some(service) = service else {
        // The index has not started (the app connects at launch): the window fills when it does.
        let (owner, conn) = (hub.clone(), conn.clone());
        hub.when_chats_ready(Box::new(move |service| {
            if !conn.out.is_closed() {
                start(&owner, service, &conn);
                conn.chat_windows.wake.notify_one();
            }
        }));
        return Ok(json!({"window": window, "ready": false}));
    };
    start(hub, &service, conn);
    refresh(hub, &service, conn).await?;
    Ok(json!({"window": window, "ready": true}))
}

/// `_acpmux/chats_window_close`.
pub(super) fn close(conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let window = params
        .get("window")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("window must be a string"))?;
    let closed = lock(&conn.chat_windows.windows).by_name.remove(window).is_some();
    // The task sees the last window gone and ends.
    conn.chat_windows.wake.notify_one();
    Ok(json!({"window": window, "closed": closed}))
}

/// A chat's activity changed (`chats::push_activity`): the connection's windows recompute.
pub(super) fn activity_changed(conn: &Conn) {
    if !conn.chat_windows.is_empty() {
        conn.chat_windows.wake.notify_one();
    }
}

/// Starts the connection's task unless it runs: it recomputes the windows after each index change
/// and each wake, until the connection closes or its last window closes.
fn start(hub: &Arc<Hub>, service: &Arc<ChatService>, conn: &Arc<Conn>) {
    {
        let mut windows = lock(&conn.chat_windows.windows);
        if windows.task || windows.by_name.is_empty() {
            return;
        }
        windows.task = true;
    }
    let mut changes = service.subscribe();
    let (hub, service, conn) = (hub.clone(), service.clone(), conn.clone());
    let live = Live::new();
    // task-owner: the connection (R6): it ends with the connection, its last window or the runtime.
    crate::supervised::spawn_scoped(async move {
        let _live = live;
        loop {
            {
                let mut windows = lock(&conn.chat_windows.windows);
                if windows.by_name.is_empty() {
                    windows.task = false;
                    return;
                }
            }
            tokio::select! {
                () = conn.out.closed() => break,
                next = changes.recv() => match next {
                    // A lagged receiver missed changes, not the state: the recompute reads the index now.
                    Ok(_) | Err(RecvError::Lagged(_)) => {}
                    Err(RecvError::Closed) => break,
                },
                () = conn.chat_windows.wake.notified() => {}
            }
            if refresh(&hub, &service, &conn).await.is_err() {
                break;
            }
        }
        let mut windows = lock(&conn.chat_windows.windows);
        windows.by_name.clear();
        windows.task = false;
    });
}

/// Recomputes every window of `conn` and sends each one's message, if any. The index lock may be
/// held by a scan, so this runs off the executor.
async fn refresh(
    hub: &Arc<Hub>,
    service: &Arc<ChatService>,
    conn: &Arc<Conn>,
) -> Result<(), RpcError> {
    let activity = hub.chat_activity();
    let (service, conn) = (service.clone(), conn.clone());
    crate::daemon::spawn_blocking(move || {
        let mut windows = lock(&conn.chat_windows.windows);
        for state in windows.by_name.values_mut() {
            let rows = service.window_rows(&state.spec, &activity);
            if let Some(message) = state.next(rows) {
                conn.send(&Message::notification("_acpmux/chats_window_changed", message));
            }
        }
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))
}
