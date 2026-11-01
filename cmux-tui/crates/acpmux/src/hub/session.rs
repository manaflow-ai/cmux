//! Owns the session record type and its small state accessors.

use super::*;

/// The steers of a session's running turn that Send now can hurry (`Session::steer_now`).
#[derive(Default)]
pub(super) struct SteerNow {
    /// Sent to the agent and not answered yet: it reads them when its current step ends. Each
    /// with the person who sent it (`author.rs`), `None` for the owner.
    pub(super) waiting: std::collections::HashMap<String, Option<String>>,
    /// Queued prompts sent now: their steer stops the agent's current step.
    pub(super) step: std::collections::HashSet<String>,
    /// What each steer of `waiting` is, by prompt id: the turn it starts when its agent reads
    /// it after the turn it was steered into ended (`carried_turn.rs`).
    pub(super) sent: std::collections::HashMap<String, super::carried_turn::SteerSent>,
    /// The turns the agent's latest carries started, newest last, by the carry's number: a
    /// steer it reads in one names it (`carried_turn.rs`).
    pub(super) carries: std::collections::VecDeque<(u64, String)>,
    /// Each carried turn after the turn it took the place of (from, to), newest last: a Stop
    /// that saw the turn before still stops the one its agent runs now (`cancel.rs`).
    pub(super) successors: std::collections::VecDeque<(String, String)>,
}

pub struct Session {
    pub id: String,
    pub(super) meta: StdMutex<SessionMeta>,
    pub(super) child: Mutex<Option<Arc<ChildAgent>>>,
    /// Held while a child is spawned and initialized, so concurrent
    /// requests for a stopped session start one agent, not several.
    pub(super) spawn_lock: Mutex<()>,
    /// Held shared by a request that reaches the harness outside a turn (a start, a mode
    /// change); the idle pass takes it exclusively while it lists and ends the harness.
    pub(super) harness_use: tokio::sync::RwLock<()>,
    /// The hub clock's time of the last log of why the idle harness stays up (`idle_census.rs`).
    pub(super) idle_refusal_logged: AtomicU64,
    pub(super) seq: AtomicU64,
    /// Held from sequence allocation until the record is stored and sent,
    /// so the log and fan-out always see sequences in order.
    pub(super) append_lock: StdMutex<()>,
    /// The one writer of its metadata (`meta_save.rs`): versioned changes, committed to
    /// `session.json` in version order (fuzz row g finding g2).
    pub(super) meta_writer: super::meta_save::MetaWriter,
    /// Message projection ids, loaded once from the journal on first use; only
    /// message acceptance/recovery touches this, never streamed tokens.
    /// Dedupe key is message id plus the target session for sender copies.
    pub(super) message_ids: StdMutex<Option<std::collections::HashSet<String>>>,
    /// Tool output snapshots held back from the log while a newer one may replace them
    /// (`store/deferred.rs`); taken only under `append_lock`.
    pub(super) log_deferral: StdMutex<crate::store::Deferral>,
    pub(super) loading: AtomicBool,
    /// The generations of the agents whose `session/load` (or Claude fork prime) replays
    /// history: from the load's start until the inbound loop reaches that agent's
    /// [`crate::agent::Inbound::ReplayDone`], its agent messages are history, never the chat's
    /// newest reply (`ReplayHold` in `lifecycle.rs`). A start abandoned mid-load leaves its
    /// agent's generation here, so what that agent still had queued stays out even after the
    /// next agent's load begins. None is ever dropped unended: only such an abandoned start
    /// (one past the agent start budget) leaves one behind, a few bytes for the session's life.
    pub(super) replaying: StdMutex<Vec<u64>>,
    /// The log's records past the saved `lastSeq` are counted (`Hub::catch_up`).
    /// False from a deferred daemon start until the first append or the log load.
    pub(super) caught_up: AtomicBool,
    /// Whether its log is read after a deferred daemon start (`log_load.rs`): once, by the
    /// background pass or the first request for it, under this lock. `log_loaded` mirrors it
    /// for reads that take no lock.
    pub(super) log_load: StdMutex<bool>,
    pub(super) log_loaded: AtomicBool,
    /// Claim retry recovery once per session object; imports may replace a chat with the
    /// same id and a different journal, which must get its own recovery pass.
    pub(super) auto_resume_restored: AtomicBool,
    /// What a daemon start restored here waits for the person: the chat's folder is
    /// privacy-protected, so its queue, cut turn, inbox and retries start no agent until the
    /// person opens, types into or prompts the chat (`protected_hold.rs`).
    pub(super) protected_hold: AtomicBool,
    /// A retry task may outlive an imported replacement with the same durable id. Its mark
    /// belongs to this instance, so its wake and cleanup cannot consume the replacement's.
    pub(super) auto_resume: auto_resume::Pending,
    pub(super) turn_lock: Mutex<()>,
    /// Set while a prompt holds `turn_lock` for its turn (`subsession_runs.rs` `ClaimedTurn`):
    /// from the moment it takes the lock, before `start_turn` shows its turn in `turn`, until
    /// its guard drops. A prompt that comes meanwhile queues and is accepted at once
    /// (`queue_slot`), instead of waiting unanswered for the lock (fuzz row g, g1).
    pub(super) turn_claimed: AtomicBool,
    /// Makes a new prompt's check whether it must wait and its place in the `queued` count one
    /// step (`queue.rs` `queue_slot`): two prompts that come together never both find the chat
    /// free. A leaf lock, held for no await.
    pub(super) admit: StdMutex<()>,
    /// Serializes the handoff of a turn's prompt and a session-wide cancel. A compacting Stop
    /// settles the logical turn before its cancel reaches the harness; keeping this lock until
    /// that cancel is handed to the child prevents the next turn's prompt from overtaking it.
    pub(super) input_handoff: std::sync::Arc<Mutex<()>>,
    pub(super) turn: StdMutex<Option<TurnInfo>>,
    /// The turn `finish_turn` took and has not ended yet: a shutdown settles it if its end does
    /// not land within the grace (`shutdown.rs` `settle_ends`).
    pub(super) ending: StdMutex<Option<TurnInfo>>,
    /// A detach is ending the agent it took under the child lock (`detach_child`): a shutdown
    /// that meets that lock waits for the detach rather than count the agent as kept.
    pub(super) detaching: AtomicBool,
    pub(super) queued: AtomicU64,
    pub(super) queue: StdMutex<Vec<QueuedPrompt>>,
    /// Durable team notices, indexed once per session; receiving one never queues a turn.
    pub(super) team_information: StdMutex<Option<super::team_information::State>>,
    /// Fired when the queue's head may have changed (a prompt left the queue,
    /// a turn ended): queued prompts wait on it for their turn (`queue.rs`).
    pub(super) queue_moved: Notify,
    /// Being moved to another daemon (`transfer_out.rs`): the transfer id. It takes no prompt
    /// and starts nothing queued until the move commits (it closes) or aborts.
    pub(super) moving: StdMutex<Option<String>>,
    /// Latest durable transfer event (sequence, blocked), rebuilt once from the log.
    /// None until a restored log has been read successfully.
    pub(super) transfer_authority: StdMutex<Option<(u64, bool)>>,
    /// Prompts `restore_queues` rebuilt, `(promptId, turnId)`, until their run asks for its turn.
    pub(super) restored: StdMutex<Vec<(String, String)>>,
    /// Inbox digests waiting for their turn, by prompt id: the messages each took, which its turn
    /// takes over (`digest.rs` `take_joined`, `inbox_digest.rs`).
    pub(super) inbox_digests: StdMutex<HashMap<String, Arc<super::digest::DigestTurn>>>,
    /// What the messages waiting inbox digests took out of the queue hold, charged against
    /// `queueMaxBytes` until each digest's turn takes them over or they go back in
    /// (`queue_admission.rs`). Changed and read only under the `queue` lock, in the same critical
    /// section that moves the messages, so a new prompt always sees them in one place or the
    /// other (`DigestTurn::charge`, `DigestTurn::release`).
    pub(super) digest_bytes: AtomicU64,
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
    /// Since when work the session started still runs past its own turn (a
    /// background subagent, a working sub-session), in ms; 0 while none does
    /// (`work_below.rs`).
    pub(super) work_below_since: StdMutex<u64>,
    /// A turn ended unseen while that work still ran: the chat turns unread when the work ends
    /// (manaflow-ai/cmux#25563, `work_below.rs`).
    pub(super) unread_after_work: AtomicBool,
    /// Agent permission requests read but not yet past their group
    /// (`permission_groups::AskInFlight`); `asks_landed` fires when the
    /// last one lands. A group is not shown while one is on its way.
    pub(super) asks_in_flight: std::sync::atomic::AtomicUsize,
    pub(super) asks_landed: Notify,
    pub(super) rehydrate: AtomicBool,
    /// The agent's context was emptied (`/clear`, `/compact`): its next
    /// prompt is told every forum rule again (`hub/forum.rs`).
    pub(super) forum_retell: AtomicBool,
    /// The posts already told again since the context was emptied, while a
    /// retell takes more than one prompt (agents' posts past one block's
    /// share, `hub/forum.rs`).
    pub(super) forum_retold: std::sync::Mutex<std::collections::HashSet<String>>,
    /// The forum posts the running turn's prompt tells, until it ends: an
    /// urgent retirement of their key reaches this session too.
    pub(super) forum_telling: std::sync::Mutex<Vec<String>>,
    /// Whether its running agent was launched with cmux's tools (0: not
    /// launched yet, 1: with, 2: without), so forum rules follow the launch,
    /// not a profile reloaded since (`hub/tools.rs`).
    pub(super) launched_with_tools: std::sync::atomic::AtomicU8,
    /// The profile env its running agent was started with (`Hub::ensure_child`): its family
    /// defaults, preset, session env and route included. The read-only shell probe judges a
    /// command in it (`permissions.rs`); None until this daemon starts an agent for it.
    pub(super) launch_env: StdMutex<Option<std::collections::BTreeMap<String, String>>>,
    /// The chat's route changed during a turn: restart the harness on it when
    /// the turn ends (`route_switch.rs`).
    pub(super) route_switch: AtomicBool,
    /// Its harness profile's launch changed since its agent started: the agent restarts on the
    /// new one when the turn ends (`profile_respawn.rs`). Lists say `respawn pending: profile
    /// changed` until a start runs the new profile.
    pub(super) profile_respawn: AtomicBool,
    pub(super) inbound_tx: mpsc::Sender<Inbound>,
    pub(super) inbound_rx: Mutex<Option<mpsc::Receiver<Inbound>>>,
    pub(super) steering: AtomicBool,
    /// Ctrl-B moves its work: decided by the harness kind it last started as
    /// (`processes.rs` `backgrounds_work`), or by what an adopted host runs
    /// (`hosts.rs`), never by the config read later.
    pub(super) backgrounds_work: AtomicBool,
    /// The person started this chat or wrote to it (`NewRequest::person`, a person's prompt):
    /// its agent start has no deadline while its harness works on it, and says it is still
    /// starting (`lifecycle.rs` `person_start`). Never set by an agent's or a lane's request.
    pub(super) person: AtomicBool,
    /// Steers into the running turn by prompt id (`steer_end.rs`): Send now stops the agent's
    /// step for one that waits (`queue_edit.rs`).
    pub(super) steer_now: StdMutex<SteerNow>,
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
    /// Set before a purge when the same chat, brought back under this id, replaces this copy
    /// (`transfer_in.rs`): its uploads stay, since the returning chat's prompts name them, and the
    /// purge record says `replaced` so the app keeps what it holds for the chat too.
    pub(super) replaced: AtomicBool,
    /// Set when the chat is closed (`kill`) until its agent starts again: its host may still
    /// hold its record while it ends, and it is not running (`policy_mode.rs` `follow_policy`).
    pub(super) closing: AtomicBool,
    /// How many times the chat was stopped (`kill`). A start reads it when its request came
    /// (`Hub::child_for_since`); a stop since then ends that start and keeps the chat closed.
    pub(super) stops: AtomicU64,
    /// How many times its turn was stopped (`cancel.rs`): a prompt whose model-sized copies were
    /// made meanwhile is not written (`turns.rs`).
    pub(super) cancels: AtomicU64,
    /// The turn id whose forced cancellation was already published. A second
    /// Stop for the same turn must not publish another forced answer.
    pub(super) cancel_forced_turn: StdMutex<Option<String>>,
    /// The forced `turn_result` already written for a turn, if any. This is
    /// separate from `cancel_forced_turn`: several prompt waiters can observe
    /// the same forced answer, but only one may append the result.
    pub(super) cancel_forced_result_turn: StdMutex<Option<String>>,
    /// The turn a Stop is stopping and has not ended yet (`cancel.rs`): the row reads
    /// `stopping` until it ends, never ended while its agent still works on it.
    pub(super) stopping: StdMutex<Option<String>>,
    /// The turn whose agent acpmux ended because it went on working after Stop (`cancel.rs`):
    /// that turn's prompt, failing as its process ends, answers as the forced cancel.
    pub(super) stop_restart: StdMutex<Option<String>>,
    /// The generation of the agent a Stop ended that way: what it still had in flight is
    /// not the next turn's (`permissions.rs` inbound loop). 0: none.
    pub(super) stopped_agent: AtomicU64,
    /// Start the agent again, on the same conversation, as the turn a Stop ended that way ends
    /// (`turns.rs`), before the next turn can start.
    /// The Stop count (`cancels`) plus one when it was set; 0: none.
    pub(super) stop_respawn: AtomicU64,
    /// How many taps `Hub::session_tap` made for it; each tap knows its number.
    pub(super) taps: AtomicU64,
    /// Taps numbered up to this one belong to an agent a Stop ended (`cancel.rs`): what they
    /// still log is no sign of work (no `heard`, no unstick, no tool state).
    pub(super) muted_taps: AtomicU64,
    /// A person's Stop holds other agents' queued messages until the person's next turn
    /// completes or the queue is resumed (`cancel.rs` `hold_agent_messages`).
    /// The person's Stop's hold, by its number (`Hub::stop_hold_number`); 0: none.
    pub(super) stop_hold: AtomicU64,
    /// `stop_hold` when the running turn started: only a turn started under the hold ends it
    /// (`turns.rs` `finish_turn`), never one that was ending as the Stop came.
    pub(super) turn_hold: AtomicU64,
    /// Claude Code reported that its active turn is compacting. This is kept
    /// on the session as hosted agents have their translator in the host.
    pub(super) compacting: AtomicBool,
    /// A compacting Stop fences untagged compaction metadata for this live
    /// session instance. Hosted updates can overtake the
    /// delayed cancel notification, so the controller must drop their
    /// boundary and summary records as well as the local translator.
    pub(super) compaction_metadata_fenced: AtomicBool,
    /// Status writes under way: each sets the status, then logs it (`Hub::write_status`). Log
    /// retention leaves a chat alone while one is (`retention.rs` `untouched`).
    pub(super) status_writes: AtomicU64,
    /// Counts status changes (`Hub::write_status`): a step that may or may not set the status
    /// reads it before and after, as an adoption does around its recovery (`hosts.rs`).
    pub(super) status_changes: AtomicU64,
    /// Bumps on every status, permission and turn change; waits gate on it.
    pub(super) state_seq: AtomicU64,
    /// Clients attached right now (TUI, web, CLI streams).
    pub(super) attached: std::sync::atomic::AtomicUsize,
    /// Of those, the ones that do not show the chat (`hub/seen.rs`).
    pub(super) hidden: std::sync::atomic::AtomicUsize,
    /// Last stderr lines of the current turn, quoted when the agent
    /// process dies without an answer ("Not logged in", a launcher error).
    pub(super) stderr_tail: StdMutex<std::collections::VecDeque<String>>,
    /// The agent processes' stderr as streams (`SessionStderr`): each carries a string control that
    /// runs across lines, so a payload never reaches `stderr_tail`. Kept across turns, as the
    /// process is. Not persisted: after a daemon restart, a line that continues a control opened
    /// before it reads as text.
    pub(super) stderr_stream: StdMutex<SessionStderr>,
    /// All pending client prompt ids and a bounded cache of completed outcomes,
    /// newest last: retries wait for the original prompt while it is pending.
    pub(super) prompts: StdMutex<std::collections::VecDeque<(String, PromptOutcome)>>,
    /// Bumped when a record failed to reach the store; an agent host entry
    /// is acknowledged only when its record was stored.
    pub(super) append_errors: AtomicU64,
    /// The seq of the last record that shows the agent doing work: a tool call that is not
    /// messaging, or a file write (`agent_pairs.rs` `progress_record`). 0: none since load.
    pub(super) last_progress: AtomicU64,
    /// How many signs of its model at work the agent sent (what it says or does, its
    /// requests, its harness's model lines; not its own bookkeeping, `tap.rs`
    /// `from_the_model`); a turn that hears none is silent (`silent_turn.rs`).
    pub(super) heard: AtomicU64,
    /// The hub clock's time (`Hub::clock_now`, ns) of the running turn's last sign of its model,
    /// or of its prompt going out if none since; an adopted turn's comes from its log, so it may
    /// be before this daemon started (negative). A turn that hears nothing for `stalledTurnEndMs`
    /// from it ends (`stalled_turn.rs`).
    pub(super) heard_at: std::sync::atomic::AtomicI64,
    /// The hub clock's time before which a turn held at its stalled deadline is not looked at
    /// again (`stalled_turn.rs`); 0 for none.
    pub(super) stalled_recheck: AtomicU64,
    /// The running turn's tool calls that have not ended (`stalled_turn.rs`): a turn quiet
    /// inside one gets longer before it counts as stalled.
    pub(super) open_tools: StdMutex<std::collections::HashSet<String>>,
    /// The turn whose stalled count runs: its prompt was written (`stalled_turn.rs`). None
    /// before that, so a turn whose prompt has not reached its agent is never stalled.
    pub(super) stalled_counted: StdMutex<Option<String>>,
    /// Bumps on every sign of the model and every new or held count (`stalled_turn.rs`): a
    /// stalled end decided at one value is not carried out at another.
    pub(super) stalled_gen: AtomicU64,
    /// Unix ms of the agent's last sign of its model at work (as `heard`); 0: none since load.
    /// A running turn quiet since then, with no tool call in flight, stalls (`views.rs`).
    pub(super) last_model_at: AtomicU64,
    /// The turn that logged `turn_silent` and has not heard its model since (`silent_turn.rs`).
    pub(super) silent_turn: StdMutex<Option<String>>,
    /// The turn cap's timer for the running turn (`turn_cap.rs`); the next turn aborts it.
    pub(super) turn_cap_timer: StdMutex<Option<tokio::task::AbortHandle>>,
    /// Other agents' messages to this chat, in threads (`inbox.rs`).
    pub(super) inbox: StdMutex<super::inbox::Inbox>,
    /// The hub clock's time (`Hub::clock_now`) of the last record or
    /// attach change; the idle harness exit counts from it (`idle.rs`).
    pub(super) last_active: AtomicU64,
    /// The hub clock's time (`Hub::clock_now`) at which the idle exit hibernated its harness
    /// (`idle.rs`), or 0: the next start of its agent is a wake, logged with its cause and how
    /// long it took.
    pub(super) hibernated_at: AtomicU64,
    /// What asked for the agent the next wake starts (`idle.rs` `wake_cause`): `typing`, `prompt`,
    /// else a request that needs the agent.
    pub(super) wake_cause: StdMutex<Option<&'static str>>,
    /// The agent's own requests (a file read, a terminal, a permission) whose task has not
    /// ended: the idle exit waits for none of them, it keeps the agent (`idle.rs`).
    pub(super) agent_requests: std::sync::atomic::AtomicUsize,
    /// Web control ended: the mode left the asking table (`web_control.rs`).
    pub(super) web_control_ended: AtomicBool,
    /// The remote floor's per-session marks (`remote_floor.rs`).
    pub(super) floor: remote_floor::FloorState,
    /// The subagents the agent reported, for attributing their updates.
    pub(super) subagents: StdMutex<crate::subagents::SubagentTree>,
    /// Claude Code runs a turn, from its `system/init` to its `result`: one acpmux prompted, or
    /// one it started itself for a task notification, which acpmux never prompted and
    /// `turn` does not show (`subagent_retry.rs` waits for its end).
    pub(super) harness_turn: AtomicBool,
    /// The turns Claude Code runs that the person did not start (`background_turn.rs`).
    pub(super) background_turns: StdMutex<super::background_turn::BackgroundTurns>,
    /// The commands its harness runs in the background (`processes.rs`).
    pub(super) processes: StdMutex<processes::ProcessTable>,
    /// Tool calls that run `gh pr create`, and the URL each printed so far, until they end
    /// (`pull_requests.rs`).
    pub(super) pr_creates: StdMutex<std::collections::HashMap<String, Option<String>>>,
    /// Its agent's `start_session` tool calls that run, with their input (`lineage.rs`).
    pub(super) start_calls: StdMutex<std::collections::HashMap<String, Value>>,
    /// The places typing into it, and who sent its prompts (`composers.rs`).
    pub(super) composers: StdMutex<super::composers::Composers>,
}

impl Session {
    /// The person wrote to this chat (`Session::person`): its next agent start waits as long as
    /// its harness works on it.
    pub(crate) fn person_wrote(&self) {
        self.person.store(true, Ordering::SeqCst);
    }

    /// Fence untagged compaction metadata for this live session. Claude's
    /// boundary and summary lines carry no turn id, so a forced Stop keeps
    /// them out of the controller log until this session is replaced.
    pub(super) fn fence_compaction_metadata(&self) {
        self.compaction_metadata_fenced.store(true, Ordering::SeqCst);
    }

    /// Terminal compaction metadata is untagged; message-derived usage stays valid.
    pub(super) fn fences_compaction_update(&self, update: &Value) -> bool {
        if !self.compaction_metadata_fenced.load(Ordering::SeqCst) {
            return false;
        }
        match update.get("sessionUpdate").and_then(Value::as_str) {
            Some("compaction") => update.get("state").and_then(Value::as_str) != Some("running"),
            Some("compaction_summary") => true,
            Some("usage_update") => {
                update.pointer("/_meta/acpmux/compactionDerived") == Some(&Value::Bool(true))
            }
            _ => false,
        }
    }

    /// Lifts the replay hold of the agent of this generation (`Session::replaying`).
    pub(super) fn end_replay(&self, agent: u64) {
        self.replaying.lock().unwrap_or_else(|e| e.into_inner()).retain(|g| *g != agent);
    }

    /// Notes whether the session now waits on the person: `input_since` is when it began
    /// (the lane's `input` since, cx-v9k2f), 0 while it does not.
    pub(super) fn mark_waiting(&self, waiting: bool) {
        self.input_since.store(if waiting { now_ms() } else { 0 }, Ordering::SeqCst);
    }

    pub fn meta(&self) -> SessionMeta {
        self.meta.lock().unwrap().clone()
    }
    /// Read only the needed fields without copying large metadata payloads. The
    /// callback must not acquire other session/hub locks or call back into this session.
    pub(crate) fn read_meta<T>(&self, read: impl FnOnce(&SessionMeta) -> T) -> T {
        read(&self.meta.lock().unwrap_or_else(|e| e.into_inner()))
    }
    pub fn turn(&self) -> Option<TurnInfo> {
        self.turn.lock().unwrap().clone()
    }
    /// Whether a prompt holds the turn lock for its turn (`turn_claimed`).
    pub(super) fn turn_claimed(&self) -> bool {
        self.turn_claimed.load(Ordering::SeqCst)
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
    pub(crate) fn has_pending_permissions(&self) -> bool {
        !self.permissions.lock().unwrap_or_else(|e| e.into_inner()).pending.is_empty()
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

/// [`short_text`] of `s` with its secrets masked first (`secret_scan`), so a
/// secret across the cut leaves no head: the sub-session tools' prompt
/// preview and every summary's running turn (`TurnInfo::masked_preview`).
pub(crate) fn masked_preview(s: &str, max: usize) -> String {
    short_text(&crate::secret_scan::mask(s), max)
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
    prompt_text_parts(blocks).0
}

/// The text `prompt_text` records of `blocks`, and the `{start, end}` range of each text
/// block the composer marked pasted (`_meta.cmux.pasted`) in it, in UTF-16 code units so a
/// client's `text.slice(start, end)` reads the paste. Both come from this one walk, so the
/// ranges always match the text.
pub(crate) fn prompt_text_parts(blocks: &[Value]) -> (String, Vec<Value>) {
    let (mut text, mut units, mut pasted) = (String::new(), 0usize, Vec::new());
    let parts = blocks
        .iter()
        .filter(|b| !crate::prompt_context::is_context(b))
        .filter_map(|b| b.get("text").and_then(Value::as_str).map(|t| (b, t)));
    for (i, (block, part)) in parts.enumerate() {
        if i > 0 {
            text.push('\n');
            units += 1;
        }
        let start = units;
        text.push_str(part);
        units += part.encode_utf16().count();
        if block.pointer("/_meta/cmux/pasted").and_then(Value::as_bool) == Some(true) {
            pasted.push(json!({"start": start, "end": units}));
        }
    }
    (text, pasted)
}

/// Adds `pasted` (the ranges of `blocks`' pasted text, `prompt_text_parts`) to the prompt
/// record `msg`, whose `text` is `prompt_text(blocks)`; none when nothing was pasted, or
/// when `msg` records some other text the ranges would not fit.
pub(crate) fn mark_pasted(msg: &mut Value, blocks: &[Value]) {
    let (text, pasted) = prompt_text_parts(blocks);
    if !pasted.is_empty() && msg.get("text").and_then(Value::as_str) == Some(text.as_str()) {
        msg["pasted"] = Value::Array(pasted);
    }
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
    /// Its agent was started with OpenCode asked to ask before every tool
    /// (`opencode_ask.rs`); false for an agent host reached again after a
    /// daemon restart, which a narrower policy restarts (`policy_mode.rs`).
    pub opencode_asks: bool,
    /// The mode acpmux had put the last agent in (`SessionMeta::mode_set_by_cmux`):
    /// marked again only once acpmux puts this agent in it (`restore_mode_mark`).
    pub replay_mark: Option<String>,
}

/// `sessions` newest first. Each session's `updated_at` is read once: other
/// tasks move it at any time (every logged event), and a key that is read
/// again on each comparison is not a total order, which makes Rust's sort
/// panic (the Chief daemon, 2026-10-14). Ties keep the session id order, so
/// the list is the same for the same values.
pub(crate) fn newest_first(sessions: Vec<Arc<Session>>) -> Vec<Arc<Session>> {
    let mut keyed: Vec<_> = sessions
        .into_iter()
        .map(|s| {
            let at = s.meta.lock().unwrap_or_else(|e| e.into_inner()).updated_at;
            (at, s)
        })
        .collect();
    keyed.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.id.cmp(&b.1.id)));
    keyed.into_iter().map(|(_, s)| s).collect()
}

/// A session's agent output streams, one per agent generation and pipe (`Inbound::Stderr`). Only a
/// stream inside a string control is kept (a closed one is the same as a new one), and it is kept
/// until its own terminator arrives, after its agent exited too: its reader may still be draining,
/// and a late line read as a fresh stream would show payload. Nothing is evicted: an entry is a
/// source and one control kind, left only by an agent that stopped inside a control.
#[derive(Debug, Default)]
pub(crate) struct SessionStderr {
    open: std::collections::HashMap<(u64, crate::agent::StderrPipe), crate::stderr::StderrStream>,
}

impl SessionStderr {
    /// `line` from `source` (an agent generation and its pipe), cleaned in that source's stream.
    pub(crate) fn clean_line(
        &mut self,
        source: (u64, crate::agent::StderrPipe),
        line: &str,
    ) -> String {
        let mut stream = self.open.remove(&source).unwrap_or_default();
        let clean = stream.clean_line(line);
        if stream.is_open() {
            self.open.insert(source, stream);
        }
        clean
    }
}
