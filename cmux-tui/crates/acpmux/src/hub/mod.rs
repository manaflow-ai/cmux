//! The hub owns every session, its child agent, its event log, and the
//! fan-out channel that attached clients subscribe to.
//!
//! Method groups live in sibling files: `peers` (remote daemons), `lifecycle`
//! (spawn, resume, fork), `permissions` (agent requests and policy), `turns`
//! (prompt, cancel, config), `transfer` (export, import), `views` (summaries).

mod lifecycle;
mod peers;
mod permissions;
mod transfer;
mod turns;
mod views;


use crate::agent::{ChildAgent, Direction, Inbound};
use crate::config::{AgentProfile, Config, PermissionPolicy};
use crate::rpc::{Id, Message, RpcError, method};
use crate::store::{EventRecord, META_SCHEMA, SessionMeta, SessionStatus, Store, now_ms};
use anyhow::Result;
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use tokio::sync::{Mutex, Notify, RwLock, broadcast, mpsc, oneshot};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Fan-out item: one appended record for one session. `remote` carries the
/// peer name and the peer's session summary when the session lives elsewhere.
#[derive(Debug, Clone)]
pub struct HubEvent {
    pub session_id: String,
    pub record: EventRecord,
    pub remote: Option<RemoteRef>,
}

#[derive(Debug, Clone)]
pub struct RemoteRef {
    pub peer: String,
    pub summary: Value,
}

/// A session that lives on a peer daemon.
#[derive(Debug, Clone)]
pub struct RemoteSession {
    pub peer: String,
    pub summary: Value,
}

#[derive(Debug)]
pub(super) struct PendingPermission {
    pub(super) request: Value,
    pub(super) reply: oneshot::Sender<Value>,
}

#[derive(Debug, Clone)]
pub struct TurnInfo {
    pub started_at: u64,
    pub client: String,
    pub prompt_preview: String,
}

pub struct Session {
    pub id: String,
    pub(super) meta: StdMutex<SessionMeta>,
    pub(super) child: Mutex<Option<Arc<ChildAgent>>>,
    pub(super) seq: AtomicU64,
    pub(super) loading: AtomicBool,
    pub(super) turn_lock: Mutex<()>,
    pub(super) turn: StdMutex<Option<TurnInfo>>,
    pub(super) queued: AtomicU64,
    pub(super) pending_permissions: StdMutex<HashMap<String, PendingPermission>>,
    pub(super) rehydrate: AtomicBool,
    pub(super) inbound_tx: mpsc::Sender<Inbound>,
    pub(super) inbound_rx: Mutex<Option<mpsc::Receiver<Inbound>>>,
    pub(super) steering: AtomicBool,
    /// Set on a freshly forked Claude session: the parent's agent session id
    /// to pass as `--resume <id> --fork-session` on first spawn.
    pub(super) fork_from: StdMutex<Option<String>>,
    /// Set once the session is purged, so late events do not recreate its
    /// files while the directory is being removed.
    pub(super) purged: AtomicBool,
}

impl Session {
    pub fn meta(&self) -> SessionMeta {
        self.meta.lock().unwrap().clone()
    }
    pub fn turn(&self) -> Option<TurnInfo> {
        self.turn.lock().unwrap().clone()
    }
    pub fn queued(&self) -> u64 {
        self.queued.load(Ordering::SeqCst)
    }
    pub fn pending_permissions(&self) -> Vec<(String, Value)> {
        self.pending_permissions
            .lock()
            .unwrap()
            .iter()
            .map(|(k, v)| (k.clone(), v.request.clone()))
            .collect()
    }
    pub(super) fn status(&self) -> SessionStatus {
        self.meta.lock().unwrap().status
    }
}

pub struct Hub {
    pub config: RwLock<Config>,
    pub(super) store: Box<dyn Store>,
    pub(super) sessions: StdMutex<HashMap<String, Arc<Session>>>,
    pub(super) events: broadcast::Sender<HubEvent>,
    pub shutdown: Notify,
    pub started_at: u64,
    pub(super) peers: StdMutex<HashMap<String, Arc<crate::peer::Peer>>>,
    pub(super) remote_sessions: StdMutex<HashMap<String, RemoteSession>>,
    pub(super) peer_notices: mpsc::Sender<(String, crate::peer::PeerNotice)>,
    pub(super) peer_notices_rx: Mutex<Option<mpsc::Receiver<(String, crate::peer::PeerNotice)>>>,
    /// Models each agent has advertised, keyed by agent profile name. Filled
    /// whenever a session starts, so the picker can list a harness that has
    /// no live session.
    pub(super) known_models: StdMutex<HashMap<String, Vec<(String, String)>>>,
}

pub(super) fn short_text(s: &str, max: usize) -> String {
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.chars().count() <= max {
        s
    } else {
        let mut out: String = s.chars().take(max).collect();
        out.push('…');
        out
    }
}

pub(super) fn prompt_text(blocks: &[Value]) -> String {
    blocks
        .iter()
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

impl Hub {
    pub fn new(config: Config, store: Box<dyn Store>) -> Arc<Self> {
        let (events, _) = broadcast::channel(8192);
        let (peer_notices, peer_notices_rx) = mpsc::channel(4096);
        let peers_cfg = config.peers.clone();
        let hub = Arc::new(Self {
            config: RwLock::new(config),
            store,
            sessions: StdMutex::new(HashMap::new()),
            events,
            shutdown: Notify::new(),
            started_at: now_ms(),
            peers: StdMutex::new(HashMap::new()),
            remote_sessions: StdMutex::new(HashMap::new()),
            peer_notices,
            peer_notices_rx: Mutex::new(Some(peer_notices_rx)),
            known_models: StdMutex::new(HashMap::new()),
        });
        hub.load_from_store();
        if tokio::runtime::Handle::try_current().is_ok() {
            let h = hub.clone();
            tokio::spawn(async move { h.peer_notice_loop().await });
            for (name, pc) in peers_cfg {
                hub.start_peer(&name, &pc.url, pc.token.clone());
            }
        }
        hub
    }

    pub fn subscribe(&self) -> broadcast::Receiver<HubEvent> {
        self.events.subscribe()
    }

    pub(super) fn load_from_store(self: &Arc<Self>) {
        let metas = match self.store.list() {
            Ok(m) => m,
            Err(e) => {
                tracing::warn!("store list failed: {e}");
                return;
            }
        };
        let mut sessions = self.sessions.lock().unwrap();
        for mut meta in metas {
            if meta.status != SessionStatus::Closed {
                meta.status = SessionStatus::Idle;
            }
            let session = self.make_session(meta);
            sessions.insert(session.id.clone(), session);
        }
        tracing::info!("loaded {} sessions from store", sessions.len());
    }

    pub(super) fn make_session(&self, meta: SessionMeta) -> Arc<Session> {
        let (inbound_tx, inbound_rx) = mpsc::channel(1024);
        Arc::new(Session {
            id: meta.id.clone(),
            seq: AtomicU64::new(meta.last_seq),
            meta: StdMutex::new(meta),
            child: Mutex::new(None),
            loading: AtomicBool::new(false),
            turn_lock: Mutex::new(()),
            turn: StdMutex::new(None),
            queued: AtomicU64::new(0),
            pending_permissions: StdMutex::new(HashMap::new()),
            rehydrate: AtomicBool::new(false),
            inbound_tx,
            inbound_rx: Mutex::new(Some(inbound_rx)),
            steering: AtomicBool::new(false),
            fork_from: StdMutex::new(None),
            purged: AtomicBool::new(false),
        })
    }

    // ------------------------------------------------------------ lookup

    pub fn sessions(&self) -> Vec<Arc<Session>> {
        let mut v: Vec<_> = self.sessions.lock().unwrap().values().cloned().collect();
        v.sort_by(|a, b| b.meta().updated_at.cmp(&a.meta().updated_at));
        v
    }

    /// Resolve by id, exact name, or unique prefix of either.
    pub fn resolve(&self, key: &str) -> Result<Arc<Session>, RpcError> {
        let sessions = self.sessions.lock().unwrap();
        if let Some(s) = sessions.get(key) {
            return Ok(s.clone());
        }
        let mut by_name: Vec<_> = sessions
            .values()
            .filter(|s| s.meta().name == key)
            .cloned()
            .collect();
        if by_name.len() == 1 {
            return Ok(by_name.remove(0));
        }
        let by_prefix: Vec<_> = sessions
            .values()
            .filter(|s| s.id.starts_with(key) || s.meta().name.starts_with(key))
            .cloned()
            .collect();
        match by_prefix.len() {
            1 => Ok(by_prefix.into_iter().next().unwrap()),
            0 => Err(RpcError::not_found(format!("no session matches {key:?}"))),
            n => Err(RpcError::invalid_params(format!(
                "{key:?} matches {n} sessions; use the id"
            ))),
        }
    }

    // ------------------------------------------------------------ logging

    pub(super) fn append(&self, session: &Session, dir: &str, kind: &str, msg: Value) -> EventRecord {
        let seq = session.seq.fetch_add(1, Ordering::SeqCst) + 1;
        let record = EventRecord {
            seq,
            at: now_ms(),
            dir: dir.into(),
            kind: kind.into(),
            msg,
        };
        if session.purged.load(Ordering::SeqCst) {
            return record;
        }
        if let Err(e) = self.store.append(&session.id, &record) {
            tracing::warn!(session = %session.id, "append failed: {e}");
        }
        {
            let mut m = session.meta.lock().unwrap();
            m.last_seq = seq;
            m.event_count += 1;
            m.updated_at = record.at;
        }
        let _ = self.events.send(HubEvent {
            session_id: session.id.clone(),
            record: record.clone(),
            remote: None,
        });
        record
    }

    pub(super) fn save_meta(&self, session: &Session) {
        let meta = session.meta();
        if let Err(e) = self.store.save(&meta) {
            tracing::warn!(session = %session.id, "save meta failed: {e}");
        }
    }

    pub(super) fn set_status(&self, session: &Session, status: SessionStatus) {
        let changed = {
            let mut m = session.meta.lock().unwrap();
            let changed = m.status != status;
            m.status = status;
            m.updated_at = now_ms();
            changed
        };
        if changed {
            self.append(session, "mux", "status", json!({"status": status.to_string()}));
            self.save_meta(session);
        }
    }

    pub fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        self.store.events(id, after, limit)
    }

    pub fn session_dir(&self, id: &str) -> Option<PathBuf> {
        self.store.session_dir(id)
    }

}


/// Browser URL for the dashboard, with the token in the query string.
pub fn web_url(w: &crate::config::WebSocketConfig) -> String {
    let host = w.listen.replace("0.0.0.0", "127.0.0.1").replace("[::]", "[::1]");
    match &w.token {
        Some(t) => format!("http://{host}/?token={t}"),
        None => format!("http://{host}/"),
    }
}

pub fn current_model(m: &SessionMeta) -> Option<String> {
    if let Some(opts) = m.config_options.as_ref().and_then(Value::as_array) {
        for o in opts {
            if o.get("id").and_then(Value::as_str) == Some("model") {
                if let Some(v) = o.get("currentValue").and_then(Value::as_str) {
                    return Some(v.to_owned());
                }
            }
        }
    }
    m.models
        .as_ref()
        .and_then(|x| x.get("currentModelId"))
        .and_then(Value::as_str)
        .map(str::to_owned)
}
