//! `_acpmux/priority_window`, `_acpmux/priority_window_close` and `_acpmux/priority_mark`: a
//! connection's windows over the sessions' lanes (`hub/priority_window.rs`), kept current by one
//! task per connection. The local unix socket only: the windows serve this Mac's sidebar.
//!
//! - `_acpmux/priority_window {window, gen?, kind?, ...}` opens the window or replaces its spec
//!   and answers `{window, ready: true}`. Its rows travel as `_acpmux/priority_window_changed
//!   {window, gen, revision, full: true, keys, rows, ...}`, queued before the answer.
//! - Each lane change (a `session_changed` record of this daemon's or a peer's session) then
//!   updates the connection's lanes in place, one session's summary read per changed session, and
//!   each window that shows something new gets `_acpmux/priority_window_changed {..., full:
//!   false, keys, rows}`: its keys in order and only the rows whose value changed, the revision
//!   one higher. A Priority window also wakes at its `nextChangeMs` (a snooze ends, an idle chat
//!   ages out) with no lane change.
//! - A missed change (the event channel lagged) or a peer link's state change reads every lane
//!   again, so a window is never left behind. A client that sees a revision gap, or an
//!   `_acpmux/priority_lagged`, opens the window again.
//! - `_acpmux/priority_mark {window, op, ...}` marks a chat in a Priority window
//!   (`MarkOp`) and answers `{window, marks}`, after the window's message for the new marks.
//! - `_acpmux/priority_next {window, after?}` answers Go to Next Agent Needing Input's next
//!   chat `{window, id}`, from the window's lanes and marks.
//! - `_acpmux/priority_window_close {window, gen?}` stops it.
//! - Each request names the client's generation of the window (`gen`); an older open or close
//!   than one already seen is refused as `stale`, as `_acpmux/chats_window` does.
//!
//! Owned (R6): the connection's task ends when its connection closes, when its last window
//! closes (a later open starts a new one), and with the runtime at daemon exit.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};
use tokio::sync::broadcast::error::{RecvError, TryRecvError};

use super::{Conn, Origin, change_kind};
use crate::hub::priority_window::{
    LaneSet, MarkOp, WindowKind, WindowSpec, WindowState, next_needing_input, view,
};
use crate::hub::{Hub, HubEvent};
use crate::rpc::{Message, RpcError};

const OPEN: &str = "_acpmux/priority_window";
const CLOSE: &str = "_acpmux/priority_window_close";
const MARK: &str = "_acpmux/priority_mark";
const NEXT: &str = "_acpmux/priority_next";
const CHANGED: &str = "_acpmux/priority_window_changed";
const LAGGED: &str = "_acpmux/priority_lagged";

/// A connection's lane windows.
#[derive(Default)]
pub(super) struct ConnWindows {
    /// Held for map changes, a lane write and a window's view and send, never across an await.
    state: StdMutex<Windows>,
    /// One recompute at a time, so one that read the lanes earlier never sends after a later one.
    refreshing: tokio::sync::Mutex<()>,
    /// Wakes the connection's task after a close or a mark.
    wake: tokio::sync::Notify,
}

#[derive(Default)]
struct Windows {
    by_name: BTreeMap<String, WindowState>,
    /// The highest generation seen for each window name, opens and closes alike.
    generations: HashMap<String, u64>,
    /// The connection's task runs.
    task: bool,
    /// Every lane, read when the first window opens; none while no window is open.
    lanes: Option<LaneSet>,
}

fn lock<T>(mutex: &StdMutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_millis()).unwrap_or(i64::MAX))
}

/// Answers the lane window methods; None for every other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(m, OPEN | CLOSE | MARK | NEXT) {
        return None;
    }
    if conn.origin != Origin::Local {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (served only on the local unix socket)"
        ))));
    }
    Some(match m {
        OPEN => open(hub, conn, params).await,
        CLOSE => close(conn, params),
        NEXT => next(conn, params),
        _ => mark(hub, conn, params).await,
    })
}

async fn open(hub: &Arc<Hub>, conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    let spec = WindowSpec::from_params(params).map_err(RpcError::invalid_params)?;
    let window = spec.window.clone();
    {
        let mut windows = lock(&conn.priority_windows.state);
        let newest = windows.generations.get(&window).copied().unwrap_or(0);
        if spec.generation < newest {
            return Ok(json!({"window": window, "gen": spec.generation, "stale": true}));
        }
        windows.generations.insert(window.clone(), spec.generation);
        let revision = windows.by_name.get(&window).map_or(0, WindowState::revision);
        windows.by_name.insert(window.clone(), WindowState::new(spec, revision));
    }
    start(hub, conn);
    refresh(hub, conn, false, Vec::new()).await?;
    Ok(json!({"window": window, "ready": true}))
}

fn close(conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let window = params
        .get("window")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("window must be a string"))?;
    let generation = match params.get("gen") {
        None | Some(Value::Null) => None,
        Some(value) => Some(
            value
                .as_u64()
                .ok_or_else(|| RpcError::invalid_params("gen must be a non-negative number"))?,
        ),
    };
    let closed = {
        let mut windows = lock(&conn.priority_windows.state);
        let newest = windows.generations.get(window).copied().unwrap_or(0);
        if generation.is_some_and(|generation| generation < newest) {
            return Ok(json!({"window": window, "closed": false, "stale": true}));
        }
        if let Some(generation) = generation {
            windows.generations.insert(window.to_owned(), generation);
        }
        windows.by_name.remove(window).is_some()
    };
    // The task sees the last window gone and ends.
    conn.priority_windows.wake.notify_one();
    Ok(json!({"window": window, "closed": closed}))
}

async fn mark(hub: &Arc<Hub>, conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    let window = params
        .get("window")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("window must be a string"))?
        .to_owned();
    let op = MarkOp::from_params(params).map_err(RpcError::invalid_params)?;
    let marks = {
        let mut windows = lock(&conn.priority_windows.state);
        let Windows { by_name, lanes, .. } = &mut *windows;
        let state = by_name
            .get_mut(&window)
            .ok_or_else(|| RpcError::not_found(format!("no window {window:?}")))?;
        let WindowKind::Priority(spec) = &mut state.spec.kind else {
            return Err(RpcError::invalid_params("marks apply to a priority window"));
        };
        let empty = LaneSet::default();
        spec.apply(&op, lanes.as_ref().unwrap_or(&empty), now_ms()).map_err(RpcError::not_found)?;
        serde_json::to_value(spec.marks()).map_err(|e| RpcError::internal(e.to_string()))?
    };
    refresh(hub, conn, false, Vec::new()).await?;
    Ok(json!({"window": window, "marks": marks}))
}

/// `_acpmux/priority_next {window, after?}`: Go to Next Agent Needing Input, `{window, id}` (id
/// null when no chat waits), from the window's lanes and marks as they are now.
fn next(conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let window = params
        .get("window")
        .and_then(Value::as_str)
        .ok_or_else(|| RpcError::invalid_params("window must be a string"))?;
    let after = match params.get("after") {
        None | Some(Value::Null) => None,
        Some(Value::String(after)) => Some(after.as_str()),
        Some(_) => return Err(RpcError::invalid_params("after must be a session id")),
    };
    let windows = lock(&conn.priority_windows.state);
    let state = windows
        .by_name
        .get(window)
        .ok_or_else(|| RpcError::not_found(format!("no window {window:?}")))?;
    let empty = LaneSet::default();
    let lanes = windows.lanes.as_ref().unwrap_or(&empty);
    Ok(json!({"window": window, "id": next_needing_input(&state.spec, lanes, now_ms(), after)}))
}

/// The records that change a session's lane: what a watcher hears as `session_changed`.
fn changes_lane(ev: &HubEvent) -> bool {
    let record = &ev.record;
    if ev.remote.is_some() {
        return record.dir == "peer";
    }
    record.kind == "purged"
        || (record.dir == "mux" && change_kind::session_change_kind(&record.kind).is_some())
}

/// Starts the connection's task unless it runs.
fn start(hub: &Arc<Hub>, conn: &Arc<Conn>) {
    {
        let mut windows = lock(&conn.priority_windows.state);
        if windows.task || windows.by_name.is_empty() {
            return;
        }
        windows.task = true;
    }
    // Subscribed before the first read of the lanes, so no change after that read is missed.
    let (events, peers) = (hub.subscribe(), hub.peer_states().subscribe());
    let (hub, conn) = (hub.clone(), conn.clone());
    // task-owner: the connection (R6): it ends with the connection, its last window or the runtime.
    tokio::spawn(async move {
        if run(&hub, &conn, events, peers).await == End::Stopped {
            // The connection closed, the hub stopped or a read failed: no window goes on.
            let mut windows = lock(&conn.priority_windows.state);
            windows.by_name.clear();
            windows.lanes = None;
            windows.task = false;
        }
    });
}

/// How the connection's task ended.
#[derive(PartialEq, Eq)]
enum End {
    /// Its last window closed; the state is already reset.
    Closed,
    /// Anything else.
    Stopped,
}

async fn run(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mut events: tokio::sync::broadcast::Receiver<HubEvent>,
    mut peers: tokio::sync::broadcast::Receiver<Value>,
) -> End {
    loop {
        let wake_at = {
            let mut windows = lock(&conn.priority_windows.state);
            if windows.by_name.is_empty() {
                // Under the lock an open checks `task` under: a later open starts a new task.
                windows.task = false;
                windows.lanes = None;
                return End::Closed;
            }
            windows.by_name.values().filter_map(WindowState::next_change).min()
        };
        // A little late, so the wake never lands just before the change.
        let wait =
            wake_at.map(|at| Duration::from_millis(u64::try_from(at - now_ms()).unwrap_or(0) + 50));
        let (mut changed, mut rebuild) = (Vec::new(), false);
        tokio::select! {
            () = conn.closed() => return End::Stopped,
            next = events.recv() => match next {
                Ok(ev) => changed.push(ev),
                Err(RecvError::Lagged(_)) => rebuild = true,
                Err(RecvError::Closed) => return End::Stopped,
            },
            note = peers.recv() => match note {
                // A peer's link came or went: its rows did too.
                Ok(_) | Err(RecvError::Lagged(_)) => rebuild = true,
                Err(RecvError::Closed) => return End::Stopped,
            },
            () = conn.priority_windows.wake.notified() => {}
            () = async { match wait { Some(wait) => tokio::time::sleep(wait).await, None => std::future::pending().await } } => {}
        }
        // The changes that came meanwhile: one recompute after all of them.
        loop {
            match events.try_recv() {
                Ok(ev) => changed.push(ev),
                Err(TryRecvError::Lagged(_)) => rebuild = true,
                Err(_) => break,
            }
        }
        // Most records change no lane (a token of output, a tool call's progress): nothing to do,
        // unless a mark, a close or the clock woke the task.
        let only_events = !changed.is_empty() && !rebuild;
        if only_events && !changed.iter().any(changes_lane) {
            continue;
        }
        if refresh(hub, conn, rebuild, changed).await.is_err() {
            conn.send(&Message::notification(LAGGED, json!({"dropped": 0})));
            return End::Stopped;
        }
    }
}

/// Applies `changed` (or reads every lane again, with `rebuild` or before the first view) and
/// sends each window's message, if any.
async fn refresh(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    rebuild: bool,
    changed: Vec<HubEvent>,
) -> Result<(), RpcError> {
    let _one = conn.priority_windows.refreshing.lock().await;
    if rebuild || lock(&conn.priority_windows.state).lanes.is_none() {
        let owner = hub.clone();
        let lanes = tokio::task::spawn_blocking(move || owner.lane_set())
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?;
        lock(&conn.priority_windows.state).lanes = Some(lanes);
    } else {
        // The last record of each session: its summary says its lane now.
        let mut last: HashMap<String, HubEvent> = HashMap::new();
        for ev in changed.into_iter().filter(changes_lane) {
            last.insert(ev.session_id.clone(), ev);
        }
        let lanes: Vec<_> = last.values().map(|ev| hub.lane_after(ev)).collect();
        if let Some(set) = lock(&conn.priority_windows.state).lanes.as_mut() {
            for (id, lane) in lanes {
                set.set(id, lane);
            }
        }
    }
    let now = now_ms();
    let mut windows = lock(&conn.priority_windows.state);
    let Windows { by_name, lanes, .. } = &mut *windows;
    let Some(lanes) = lanes.as_ref() else { return Ok(()) };
    for state in by_name.values_mut() {
        if let Some(message) = state.next(view(&state.spec, lanes, now)) {
            conn.send(&Message::notification(CHANGED, message));
        }
    }
    Ok(())
}
