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
    /// Fired when the queue's head may have changed (a prompt left the queue,
    /// a turn ended): queued prompts wait on it for their turn (`queue.rs`).
    pub(super) queue_moved: Notify,
    /// Being moved to another daemon (`transfer_out.rs`): the transfer id. It takes no prompt
    /// and starts nothing queued until the move commits (it closes) or aborts.
    pub(super) moving: StdMutex<Option<String>>,
    /// Prompts `restore_queues` rebuilt, `(promptId, turnId)`, until their run asks for its turn.
    pub(super) restored: StdMutex<Vec<(String, String)>>,
    pub(super) stream: StdMutex<StreamState>,
    pub(super) permissions: StdMutex<permission_groups::PermissionState>,
    /// Bumped (under the `permissions` lock) whenever pending
    /// permissions are cancelled; a request that started before the bump
    /// is answered `cancelled` instead of being registered.
    pub(super) permission_epoch: AtomicU64,
    /// When the session last began waiting on the person (`Waiting`), in ms;
    /// 0 while it is not. The lane's `input` since (cx-v9k2f): later records,
    /// a draft save or a second ask do not move it.
    pub(super) input_since: AtomicU64,
    /// Agent permission requests read but not yet past their group
    /// (`permission_groups::AskInFlight`); `asks_landed` fires when the
    /// last one lands. A group is not shown while one is on its way.
    pub(super) asks_in_flight: std::sync::atomic::AtomicUsize,
    pub(super) asks_landed: Notify,
    pub(super) rehydrate: AtomicBool,
    /// The agent's context was emptied (`/clear`, `/compact`): its next
    /// prompt is told every forum rule again (`hub/forum.rs`).
    pub(super) forum_retell: AtomicBool,
    /// The chat's route changed during a turn: restart the harness on it when
    /// the turn ends (`route_switch.rs`).
    pub(super) route_switch: AtomicBool,
    pub(super) inbound_tx: mpsc::Sender<Inbound>,
    pub(super) inbound_rx: Mutex<Option<mpsc::Receiver<Inbound>>>,
    pub(super) steering: AtomicBool,
    /// The answer of a steer that ended its turn, with the turn's id: the
    /// turn's other prompts take it (`steer_end.rs`, codex-acp).
    pub(super) steer_end: tokio::sync::watch::Sender<Option<(String, Value)>>,
    /// Set on a freshly forked Claude session: the parent's agent session id
    /// to pass as `--resume <id> --fork-session` on first spawn.
    pub(super) fork_from: StdMutex<Option<String>>,
    /// The model and the effort acpmux last set on this session (its own
    /// start values or a client's set), so a repeated set is no new pick
    /// (`start_defaults.rs`).
    pub(super) applied: StdMutex<Applied>,
    /// Set once the session is purged, so late events do not recreate its
    /// files while the directory is being removed.
    pub(super) purged: AtomicBool,
    /// Bumps on every status, permission and turn change; waits gate on it.
    pub(super) state_seq: AtomicU64,
    /// Clients attached right now (TUI, web, CLI streams).
    pub(super) attached: std::sync::atomic::AtomicUsize,
    /// Of those, the ones that do not show the chat (`hub/seen.rs`).
    pub(super) hidden: std::sync::atomic::AtomicUsize,
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
    /// The commands its harness runs in the background (`processes.rs`).
    pub(super) processes: StdMutex<processes::ProcessTable>,
}

impl Session {
    /// Notes whether the session now waits on the person: `input_since` is when it began
    /// (the lane's `input` since, cx-v9k2f), 0 while it does not.
    pub(super) fn mark_waiting(&self, waiting: bool) {
        self.input_since.store(if waiting { now_ms() } else { 0 }, Ordering::SeqCst);
    }

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
    pub fn moving(&self) -> Option<String> {
        self.moving.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
    /// A failed turn holds the prompts that waited behind it (`queue.rs` `pause_queue`).
    pub fn queue_paused(&self) -> bool {
        self.queue.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|q| q.held)
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

/// The person's text of a prompt: its text blocks, without the hidden context acpmux added
/// (`prompt_context.rs`).
pub(crate) fn prompt_text(blocks: &[Value]) -> String {
    blocks
        .iter()
        .filter(|b| !crate::prompt_context::is_context(b))
        .filter_map(|b| b.get("text").and_then(Value::as_str))
        .collect::<Vec<_>>()
        .join("\n")
}

/// What acpmux last set on a session (`Session::applied`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct Applied {
    pub model: Option<String>,
    pub effort: Option<String>,
    /// The approval digest of the preset contents `session/new` resolved
    /// with, and the one its harness last spawned with
    /// (`start_gate/preset_bind.rs`).
    pub preset_resolved: Option<String>,
    pub preset_spawned: Option<String>,
}
