//! Owns the session record type and its small state accessors.

use super::*;

pub struct Session {
    pub id: String,
    pub(super) meta: StdMutex<SessionMeta>,
    pub(super) child: Mutex<Option<Arc<ChildAgent>>>,
    /// Held while a child is spawned and initialized, so concurrent
    /// requests for a stopped session start one agent, not several.
    pub(super) spawn_lock: Mutex<()>,
    pub(super) seq: AtomicU64,
    /// Held from sequence allocation until the record is stored and sent,
    /// so the log and fan-out always see sequences in order.
    pub(super) append_lock: StdMutex<()>,
    pub(super) loading: AtomicBool,
    pub(super) turn_lock: Mutex<()>,
    pub(super) turn: StdMutex<Option<TurnInfo>>,
    pub(super) queued: AtomicU64,
    pub(super) queue: StdMutex<Vec<QueuedPrompt>>,
    pub(super) stream: StdMutex<StreamState>,
    pub(super) permissions: StdMutex<permission_groups::PermissionState>,
    /// Bumped (under the `permissions` lock) whenever pending
    /// permissions are cancelled; a request that started before the bump
    /// is answered `cancelled` instead of being registered.
    pub(super) permission_epoch: AtomicU64,
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
    /// Bumps on every status, permission and turn change; waits gate on it.
    pub(super) state_seq: AtomicU64,
    /// Clients attached right now (TUI, web, CLI streams).
    pub(super) attached: std::sync::atomic::AtomicUsize,
    /// Last stderr lines of the current turn, quoted when the agent
    /// process dies without an answer ("Not logged in", a launcher error).
    pub(super) stderr_tail: StdMutex<std::collections::VecDeque<String>>,
    /// Recent client prompt ids and their outcomes, newest last: a prompt
    /// sent again with the same id never runs a second turn.
    pub(super) prompts: StdMutex<std::collections::VecDeque<(String, PromptOutcome)>>,
    /// Bumped when a record failed to reach the store; an agent host entry
    /// is acknowledged only when its record was stored.
    pub(super) append_errors: AtomicU64,
    /// The hub clock's time (`Hub::clock_now`) of the last record or
    /// attach change; the idle harness exit counts from it (`idle.rs`).
    pub(super) last_active: AtomicU64,
    /// Web control ended: the mode left the asking table (`web_control.rs`).
    pub(super) web_control_ended: AtomicBool,
    /// The remote floor's per-session marks (`remote_floor.rs`).
    pub(super) floor: remote_floor::FloorState,
    /// The subagents the agent reported, for attributing their updates.
    pub(super) subagents: StdMutex<crate::subagents::SubagentTree>,
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
    pub fn queue(&self) -> Vec<QueuedPrompt> {
        self.queue.lock().unwrap().clone()
    }
    pub fn pending_permissions(&self) -> Vec<(String, Value)> {
        self.permissions
            .lock()
            .unwrap()
            .pending
            .iter()
            .map(|(k, v)| (k.clone(), v.request.clone()))
            .collect()
    }
    pub(super) fn status(&self) -> SessionStatus {
        self.meta.lock().unwrap().status
    }
}
/// Tags that have not expired, as a flat map.
pub fn live_tags(m: &SessionMeta) -> Value {
    let now = now_ms();
    let mut out = serde_json::Map::new();
    for (k, t) in &m.tags {
        if t.expires_at.map(|e| e > now).unwrap_or(true) {
            out.insert(k.clone(), Value::String(t.value.clone()));
        }
    }
    Value::Object(out)
}

pub(crate) fn short_text(s: &str, max: usize) -> String {
    let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if s.chars().count() <= max {
        s
    } else {
        let mut out: String = s.chars().take(max).collect();
        out.push('…');
        out
    }
}

pub(crate) fn prompt_text(blocks: &[Value]) -> String {
    blocks
        .iter()
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}
