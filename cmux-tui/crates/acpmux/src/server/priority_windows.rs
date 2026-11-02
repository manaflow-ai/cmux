//! `_acpmux/priority_window`, `_acpmux/priority_window_close`, `_acpmux/priority_mark` and
//! `_acpmux/priority_next`: a connection's windows over the sessions' lanes
//! (`hub/priority_window.rs`), kept current by one task per connection. The local unix socket
//! only: the windows serve this Mac's sidebar.
//!
//! - `_acpmux/priority_window {window, gen?, kind?, ...}` opens the window or replaces its spec
//!   and answers `{window, ready: true}`. Its rows travel as `_acpmux/priority_window_changed
//!   {window, gen, revision, full: true, keys, rows, ...}`, queued before the answer. A spec's
//!   `importMarks` (the app's saved marks) is taken only while acpmux has no marks of its own, so
//!   a client sends it with its first open.
//! - Each lane change (a `session_changed` record of this daemon's or a peer's session) then
//!   updates the connection's lanes in place, one session's summary read per changed session, and
//!   each window that shows something new gets `_acpmux/priority_window_changed {..., full:
//!   false, keys, rows}`: its keys in order and only the rows whose value changed, the revision
//!   one higher. A Priority window also wakes at its `nextChangeMs` (a snooze ends, an idle chat
//!   ages out) with no lane change.
//! - A missed change (the event channel lagged, a peer link lagged) or a peer link's state change
//!   reads every lane again, so a window is never left behind. A client that sees a revision gap,
//!   or an `_acpmux/priority_lagged`, opens the window again.
//! - `_acpmux/priority_mark {window, op, ...}` marks a chat in a Priority window (`MarkOp`) and
//!   answers `{window, marks}`. The marks are the daemon's, one copy (`hub/priority_marks.rs`):
//!   every window of every connection shows the change.
//! - `_acpmux/priority_next {window, after?}` answers Go to Next Agent Needing Input's next
//!   chat `{window, id}`, from the window's lanes and the marks.
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
use crate::hub::{Hub, HubEvent, PEER_LAGGED, PEER_PERMISSION_PENDING};
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
    /// Wakes the connection's task after an open, a close or a mark: it reads the next wake time.
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

fn window_name(params: &Value) -> Result<String, RpcError> {
    params
        .get("window")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| RpcError::invalid_params("window must be a string"))
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
        NEXT => next(hub, conn, params),
        _ => mark(hub, conn, params).await,
    })
}

async fn open(hub: &Arc<Hub>, conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    let spec = WindowSpec::from_params(params).map_err(RpcError::invalid_params)?;
    let window = spec.window.clone();
    let import = match &spec.kind {
        WindowKind::Priority(priority) => priority.import().cloned(),
        WindowKind::Links { .. } => None,
    };
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
    if let Some(import) = import {
        hub.priority_marks.import(import).await;
    }
    start(hub, conn);
    refresh(hub, conn, Refresh { rebuild: false, woke: true }, Vec::new()).await?;
    // The task reads the window's next wake time from its first message.
    conn.priority_windows.wake.notify_one();
    Ok(json!({"window": window, "ready": true}))
}

fn close(conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let window = window_name(params)?;
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
        let newest = windows.generations.get(&window).copied().unwrap_or(0);
        if generation.is_some_and(|generation| generation < newest) {
            return Ok(json!({"window": window, "closed": false, "stale": true}));
        }
        if let Some(generation) = generation {
            windows.generations.insert(window.clone(), generation);
        }
        windows.by_name.remove(&window).is_some()
    };
    // The task sees the last window gone and ends.
    conn.priority_windows.wake.notify_one();
    Ok(json!({"window": window, "closed": closed}))
}

/// Applies a mark to the daemon's marks. Every connection's task hears the change
/// (`MarksStore::subscribe`) and sends its windows' new rows.
async fn mark(hub: &Arc<Hub>, conn: &Arc<Conn>, params: &Value) -> Result<Value, RpcError> {
    let window = window_name(params)?;
    let op = MarkOp::from_params(params).map_err(RpcError::invalid_params)?;
    let checked = {
        let windows = lock(&conn.priority_windows.state);
        let state = windows
            .by_name
            .get(&window)
            .ok_or_else(|| RpcError::not_found(format!("no window {window:?}")))?;
        let WindowKind::Priority(spec) = &state.spec.kind else {
            return Err(RpcError::invalid_params("marks apply to a priority window"));
        };
        let empty = LaneSet::default();
        spec.mark(op, windows.lanes.as_ref().unwrap_or(&empty)).map_err(RpcError::not_found)?
    };
    let now = now_ms();
    let ((), marks) = hub
        .priority_marks
        .change(|marks| {
            checked.apply(marks, now);
            Ok(())
        })
        .await
        .map_err(RpcError::internal)?;
    refresh(hub, conn, Refresh { rebuild: false, woke: true }, Vec::new()).await?;
    conn.priority_windows.wake.notify_one();
    let marks = serde_json::to_value(&marks).map_err(|e| RpcError::internal(e.to_string()))?;
    Ok(json!({"window": window, "marks": marks}))
}

/// `_acpmux/priority_next {window, after?}`: Go to Next Agent Needing Input, `{window, id}` (id
/// null when no chat waits), from the window's lanes and the marks as they are now.
fn next(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let window = window_name(params)?;
    let after = match params.get("after") {
        None | Some(Value::Null) => None,
        Some(Value::String(after)) => Some(after.as_str()),
        Some(_) => return Err(RpcError::invalid_params("after must be a session id")),
    };
    let marks = hub.priority_marks.get();
    let windows = lock(&conn.priority_windows.state);
    let state = windows
        .by_name
        .get(&window)
        .ok_or_else(|| RpcError::not_found(format!("no window {window:?}")))?;
    let empty = LaneSet::default();
    let lanes = windows.lanes.as_ref().unwrap_or(&empty);
    let id = next_needing_input(&state.spec, lanes, &marks, now_ms(), after);
    Ok(json!({"window": window, "id": id}))
}

/// What one hub event means for the windows.
#[derive(PartialEq, Eq)]
enum Heard {
    /// It changes no lane (a token of output, a tool call's progress, a peer's question).
    Nothing,
    /// It changes the lane of the session it names.
    Lane,
    /// A peer link dropped notices: its rows may be behind; read every lane again.
    Rebuild,
}

/// The records that change a session's lane: what a watcher hears as `session_changed`
/// (`deliver` in `server/mod.rs`).
fn heard(ev: &HubEvent) -> Heard {
    let record = &ev.record;
    if record.kind == PEER_LAGGED {
        return Heard::Rebuild;
    }
    if ev.remote.is_some() {
        let changes = record.dir == "peer" && record.kind != PEER_PERMISSION_PENDING;
        return if changes { Heard::Lane } else { Heard::Nothing };
    }
    let changes = record.kind == "purged"
        || (record.dir == "mux" && change_kind::session_change_kind(&record.kind).is_some());
    if changes { Heard::Lane } else { Heard::Nothing }
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
    let marks = hub.priority_marks.subscribe();
    let (hub, conn) = (hub.clone(), conn.clone());
    // task-owner: the connection (R6): it ends with the connection, its last window or the runtime.
    tokio::spawn(async move {
        if run(&hub, &conn, events, peers, marks).await == End::Stopped {
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

/// Sleeps until `at` (epoch ms) and a little more, so the wake never lands just before the
/// change; forever when there is nothing to wake for.
async fn sleep_until(at: Option<i64>) {
    match at {
        Some(at) => {
            let wait = u64::try_from(at.saturating_sub(now_ms())).unwrap_or(0).saturating_add(50);
            tokio::time::sleep(Duration::from_millis(wait)).await;
        }
        None => std::future::pending().await,
    }
}

async fn run(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    mut events: tokio::sync::broadcast::Receiver<HubEvent>,
    mut peers: tokio::sync::broadcast::Receiver<Value>,
    mut marks: tokio::sync::watch::Receiver<u64>,
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
        let (mut changed, mut rebuild, mut woke) = (Vec::new(), false, false);
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
            // The marks changed (through any window of any connection).
            seen = marks.changed() => {
                if seen.is_err() {
                    return End::Stopped;
                }
                woke = true;
            }
            // An open, a close or a mark here: the loop reads the windows again.
            () = conn.priority_windows.wake.notified() => woke = true,
            // A snooze ends or an idle chat ages out.
            () = sleep_until(wake_at) => woke = true,
        }
        // The changes that came meanwhile: one recompute after all of them.
        loop {
            match events.try_recv() {
                Ok(ev) => changed.push(ev),
                Err(TryRecvError::Lagged(_)) => rebuild = true,
                Err(_) => break,
            }
        }
        rebuild |= changed.iter().any(|ev| heard(ev) == Heard::Rebuild);
        changed.retain(|ev| heard(ev) == Heard::Lane);
        if !woke && !rebuild && changed.is_empty() {
            continue;
        }
        if refresh(hub, conn, Refresh { rebuild, woke }, changed).await.is_err() {
            conn.send(&Message::notification(LAGGED, json!({"dropped": 0})));
            return End::Stopped;
        }
    }
}

/// Why a refresh runs besides its lane records.
#[derive(Clone, Copy, Default)]
struct Refresh {
    /// Read every lane again.
    rebuild: bool,
    /// Something other than a lane changed (the marks, a spec, the clock): every window is
    /// recomputed even when no lane changed.
    woke: bool,
}

/// Applies `changed` (lane records, `heard` says), or reads every lane again (with `rebuild`, or
/// before the first view), and sends each window's message, if any. Only when nothing but lane
/// records came and none changed a lane is no window recomputed.
async fn refresh(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    why: Refresh,
    changed: Vec<HubEvent>,
) -> Result<(), RpcError> {
    let Refresh { rebuild, woke } = why;
    let _one = conn.priority_windows.refreshing.lock().await;
    let events = !changed.is_empty();
    if rebuild || lock(&conn.priority_windows.state).lanes.is_none() {
        let owner = hub.clone();
        let lanes = tokio::task::spawn_blocking(move || owner.lane_set())
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?;
        lock(&conn.priority_windows.state).lanes = Some(lanes);
    } else if events {
        // The last record of each session: its summary says its lane now.
        let mut last: HashMap<String, HubEvent> = HashMap::new();
        for ev in changed {
            last.insert(ev.session_id.clone(), ev);
        }
        let lanes: Vec<_> = last.values().map(|ev| hub.lane_after(ev)).collect();
        let mut windows = lock(&conn.priority_windows.state);
        let Some(set) = windows.lanes.as_mut() else { return Ok(()) };
        let mut any = false;
        for change in lanes {
            any |= set.apply(change);
        }
        if !any && !woke {
            return Ok(());
        }
    }
    let marks = hub.priority_marks.get();
    let now = now_ms();
    let mut windows = lock(&conn.priority_windows.state);
    let Windows { by_name, lanes, .. } = &mut *windows;
    let Some(lanes) = lanes.as_ref() else { return Ok(()) };
    for state in by_name.values_mut() {
        if let Some(message) = state.next(view(&state.spec, lanes, &marks, now)) {
            conn.send(&Message::notification(CHANGED, message));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::hub::RemoteRef;
    use crate::store::EventRecord;

    fn event(dir: &str, kind: &str, remote: bool) -> HubEvent {
        HubEvent {
            session_id: "s".into(),
            record: Arc::new(EventRecord {
                seq: 1,
                at: 0,
                dir: dir.into(),
                kind: kind.into(),
                msg: Value::Null,
                host_seq: None,
            }),
            remote: remote.then(|| RemoteRef { peer: "mini".into(), summary: Value::Null }),
        }
    }

    /// A peer link that dropped notices reads every lane again (its rows may be behind), a
    /// peer's question changes no lane, and a peer's change or purge, or a session record a
    /// watcher hears of, changes one; output does not.
    #[test]
    fn each_record_is_heard_as_what_it_does_to_the_lanes() {
        assert!(heard(&event("peer", PEER_LAGGED, true)) == Heard::Rebuild);
        assert!(heard(&event("peer", PEER_PERMISSION_PENDING, true)) == Heard::Nothing);
        assert!(heard(&event("peer", "purged", true)) == Heard::Lane);
        assert!(heard(&event("peer", "status", true)) == Heard::Lane);
        assert!(heard(&event("mux", "turn_end", false)) == Heard::Lane);
        assert!(heard(&event("mux", "purged", false)) == Heard::Lane);
        assert!(heard(&event("in", "session/update", false)) == Heard::Nothing);
        assert!(heard(&event("mux", "agent_message_chunk", false)) == Heard::Nothing);
    }
}
