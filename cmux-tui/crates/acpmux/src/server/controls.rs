//! Opt-in v1 controls beside the list stream. Snapshot pages are requested in order; `live`
//! commits the snapshot and releases its buffered changes. A fresh open replaces the stream.
//! All queued bytes (pages, staged changes, pump and transport) share one 256 KiB budget.
use super::outbound::Line;
use super::{Conn, Hub, HubEvent, Message, RpcError, Value, json};
use serde::Deserialize;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

pub(crate) const METHOD: &str = "_acpmux/controls";
pub(crate) const NOTICE: &str = "_acpmux/control";
pub(crate) const FEATURE: &str = "linkControls";
pub(crate) const BOUND: usize = 256 << 10;
pub(crate) const PAGE: usize = 64 << 10;
const RESERVE: usize = 1024;
pub(crate) static RESYNCS: AtomicU64 = AtomicU64::new(0);
pub(crate) static CUTS: AtomicU64 = AtomicU64::new(0);

#[derive(Default)]
pub(super) struct Budget(AtomicUsize);
impl Budget {
    fn take(self: &Arc<Self>, size: usize, terminal: bool) -> Option<Ticket> {
        let limit = if terminal { BOUND } else { BOUND - RESERVE };
        self.0
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |held| {
                held.checked_add(size).filter(|n| *n <= limit)
            })
            .ok()?;
        Some(Ticket { budget: self.clone(), size })
    }
}
pub(super) struct Ticket {
    budget: Arc<Budget>,
    size: usize,
}
impl Drop for Ticket {
    fn drop(&mut self) {
        self.budget.0.fetch_sub(self.size, Ordering::AcqRel);
    }
}

#[derive(Default)]
pub(super) struct Controls {
    budget: Arc<Budget>,
    open: Mutex<Option<Open>>,
}
struct Open {
    id: String,
    asks: bool,
    ready: bool,
    sessions: VecDeque<Arc<crate::hub::Session>>,
    after: Option<String>,
    page: u64,
    done: bool,
    live: bool,
    staged: VecDeque<Line>,
}
#[derive(Deserialize)]
struct Request {
    kinds: Option<Vec<String>>,
    stream: Option<String>,
    page: Option<u64>,
    #[serde(default)]
    live: bool,
}

pub(super) fn offered(hub: &Hub, conn: &Conn) -> bool {
    conn.auth.peer_daemon() && hub.link_v2.v2().is_some()
}

pub(super) fn handle(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    if !offered(hub, conn) {
        return Err(RpcError::method_not_found(METHOD));
    }
    let request: Request = serde_json::from_value(params.clone())
        .map_err(|e| RpcError::invalid_params(e.to_string()))?;
    conn.out.settle();
    let mut state = conn.controls.open.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(kinds) = request.kinds {
        if request.stream.is_some()
            || request.page.is_some()
            || request.live
            || kinds.is_empty()
            || kinds.len() > 2
            || kinds.iter().any(|k| !matches!(k.as_str(), "asks" | "ready"))
        {
            return Err(RpcError::invalid_params("controls opens with kinds: asks, ready"));
        }
        if conn.controls.budget.0.load(Ordering::Acquire) > BOUND - PAGE - RESERVE {
            return Err(resync_error());
        }
        let asks = kinds.iter().any(|k| k == "asks");
        let ready = kinds.iter().any(|k| k == "ready");
        *state = Some(Open {
            id: uuid::Uuid::now_v7().to_string(),
            asks,
            ready,
            sessions: if asks { hub.control_sessions() } else { VecDeque::new() },
            after: None,
            page: 0,
            done: false,
            live: false,
            staged: VecDeque::new(),
        });
    } else {
        let Some(open) = state.as_ref() else {
            return Err(resync_error());
        };
        if request.stream.as_deref() != Some(&open.id) || open.live {
            return Err(resync_error());
        }
        if request.live {
            if !open.done || request.page.is_some() {
                return Err(RpcError::invalid_params("finish snapshot pages before live"));
            }
            let Some(open) = state.as_mut() else {
                return Err(resync_error());
            };
            conn.raise_gate();
            for line in open.staged.drain(..) {
                conn.out.push_control(line);
            }
            open.live = true;
            return Ok(json!({"stream": open.id, "phase": "live", "ready": open.ready}));
        }
        if request.page != Some(open.page) || open.done {
            return Err(resync_error());
        }
    }
    let Some(open) = state.as_mut() else {
        return Err(resync_error());
    };
    let mut entries = Vec::new();
    if open.page == 0 && open.ready {
        entries.push(json!({"kind": "ready", "key": ["local"], "value": {
            "personInstance": hub.person.instance(), "githubLink": true,
        }}));
    }
    let mut bytes = entries.iter().map(|e| e.to_string().len() + 1).sum::<usize>();
    // One session's page at a time: the response never copies the rest of its asks or rows.
    while let Some(session) = open.sessions.front() {
        let room = PAGE.saturating_sub(2048 + bytes);
        if room < PAGE / 2 {
            break;
        }
        let (page, next) = match hub.control_ask_page(session, open.after.as_deref(), room) {
            Ok(page) => page,
            Err(_) if !entries.is_empty() => break,
            Err(error) => {
                *state = None;
                return Err(error);
            }
        };
        bytes += page.iter().map(|e| e.to_string().len() + 1).sum::<usize>();
        entries.extend(page);
        open.after = next;
        if open.after.is_some() {
            break;
        }
        open.sessions.pop_front();
    }
    open.done = open.sessions.is_empty();
    let page = open.page;
    open.page += 1;
    Ok(json!({"stream": open.id, "phase": "snapshot", "page": page,
        "next": (!open.done).then_some(open.page), "entries": entries}))
}

pub(crate) fn resync_error() -> RpcError {
    RpcError::new(-32000, "controls must reopen from a snapshot")
        .with_data(json!({"reason": "controls.resync"}))
}

impl Controls {
    /// The reply's bytes have the same lifetime and budget as notifications, including pages.
    pub(super) fn reply(&self, conn: &Conn, msg: &Message, line: String) {
        conn.out.settle();
        if let Some(ticket) = self.budget.take(line.len(), false) {
            if !conn.out.push_control(Line { text: line, ticket: Some(ticket), ..Line::default() })
            {
                // A closed transport never opens broker readiness, even if the handler had
                // committed the snapshot before its reply found that the reader was gone.
                self.open.lock().unwrap_or_else(|e| e.into_inner()).take();
            }
        } else {
            self.resync(conn, "overflow");
            if let Message::Response { id, .. } = msg {
                conn.out.push(Message::err(id.clone(), resync_error()).to_line());
            }
        }
    }

    fn send(&self, conn: &Conn, entry: Value) {
        let mut state = self.open.lock().unwrap_or_else(|e| e.into_inner());
        let Some(open) = state.as_mut() else { return };
        let line = Message::notification(
            NOTICE,
            json!({"stream": open.id, "phase": "change", "entry": entry}),
        )
        .to_line();
        conn.out.settle();
        let Some(ticket) = self.budget.take(line.len(), false) else {
            drop(state);
            self.resync(conn, "overflow");
            return;
        };
        let line = Line { text: line, ticket: Some(ticket), ..Line::default() };
        if open.live {
            conn.raise_gate();
            conn.out.push_control(line);
        } else {
            open.staged.push_back(line);
        }
    }

    pub(super) fn resync(&self, conn: &Conn, reason: &str) {
        let mut state = self.open.lock().unwrap_or_else(|e| e.into_inner());
        let Some(open) = state.take() else { return };
        let id = open.id.clone();
        drop(open); // Buffered changes end explicitly at resync, never silently.
        RESYNCS.fetch_add(1, Ordering::Relaxed);
        let line = Message::notification(
            NOTICE,
            json!({"stream": id, "phase": "resync", "origin": "local", "reason": reason}),
        )
        .to_line();
        conn.out.settle();
        if let Some(ticket) = self.budget.take(line.len(), true) {
            conn.raise_gate();
            conn.out.push_control(Line { text: line, ticket: Some(ticket), ..Line::default() });
        }
    }

    pub(super) fn event(&self, hub: &Hub, conn: &Conn, event: &HubEvent) {
        if event.remote.is_some() {
            return;
        } // Only the authenticated owner's own asks.
        if !self.open.lock().unwrap_or_else(|e| e.into_inner()).as_ref().is_some_and(|o| o.asks) {
            return;
        }
        let rec = &event.record;
        if !crate::hub::is_permission_ask(&rec.kind)
            && !matches!(
                rec.kind.as_str(),
                "permission_decision"
                    | "permission_auto"
                    | "permission_withdrawn"
                    | "permission_resolved"
            )
        {
            return;
        }
        let Some(id) = rec.msg.get("permissionId").and_then(Value::as_str) else {
            self.resync(conn, "ask_membership_changed");
            return;
        };
        // Read the authority now: an event queued before its snapshot cannot resurrect a
        // decided ask after it. A removed ask is a keyed tombstone, never list absence.
        let entry = if crate::hub::is_permission_ask(&rec.kind) {
            hub.control_ask(&event.session_id, id).unwrap_or_else(|| {
                json!({"kind": "asks", "key": [event.session_id, id], "value": null, "end": "gone"})
            })
        } else {
            let end = match rec.kind.as_str() {
                "permission_decision" => "decided",
                "permission_auto" => "auto",
                "permission_withdrawn" => "withdrawn",
                "permission_resolved" => "resolved",
                _ => return,
            };
            json!({"kind": "asks", "key": [event.session_id, id],
                "value": crate::server::event_value(&event.session_id, rec), "end": end})
        };
        let entry = if entry.get("end").is_none() && entry.to_string().len() > PAGE / 2 {
            CUTS.fetch_add(1, Ordering::Relaxed);
            let Some(value) = entry.get("value") else {
                self.resync(conn, "ask_missing_value");
                return;
            };
            let Some(key) = entry.get("key") else {
                self.resync(conn, "ask_missing_key");
                return;
            };
            let Some(session_id) = value.get("sessionId").cloned() else {
                self.resync(conn, "ask_missing_fields");
                return;
            };
            let Some(permission_id) = value.get("permissionId").cloned() else {
                self.resync(conn, "ask_missing_fields");
                return;
            };
            let Some(person_instance) = value.get("personInstance").cloned() else {
                self.resync(conn, "ask_missing_fields");
                return;
            };
            let Some(decision_nonce) = value.get("decisionNonce").cloned() else {
                self.resync(conn, "ask_missing_fields");
                return;
            };
            let Some(parent) = value.get("parent").cloned() else {
                self.resync(conn, "ask_missing_fields");
                return;
            };
            let Some(handle) = value.get("handle").cloned() else {
                self.resync(conn, "ask_missing_fields");
                return;
            };
            let Some(label) = value.get("label").cloned() else {
                self.resync(conn, "ask_missing_fields");
                return;
            };
            json!({"kind": "asks", "key": key, "cut": true, "value": {
                "sessionId": session_id,
                "permissionId": permission_id,
                "personInstance": person_instance,
                "decisionNonce": decision_nonce,
                "parent": parent,
                "handle": handle,
                "label": label,
            }})
        } else {
            entry
        };
        self.send(conn, entry);
    }
}

#[cfg(test)]
#[path = "controls_tests.rs"]
mod tests;
