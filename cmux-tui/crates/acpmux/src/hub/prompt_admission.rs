//! Prompt admission, bounded (Leo, 2026-11-25: "no prompt holds `prompt_admission` across an
//! unbounded await ... A delivery always gets an answer within seconds").
//!
//! `Session::prompt_admission` orders each prompt's setup up to its acceptance, so a later prompt
//! never claims the chat while an earlier one still resolves its uploads. It used to be a plain
//! lock held across every await of that setup (the agent's lock, the inbox, the cold check, the
//! queue's own waits): one of them that never came back kept every later prompt of the chat
//! waiting with no answer, while the chat read "ready" (one chat: 66 restored agent
//! notices, none ran, every new delivery retried unanswered).
//!
//! Now every bound is here, and there is no other way in:
//! - [`admit`] waits at most [`ADMISSION_BOUND`] for the lock. Past that the prompt goes on
//!   without it: the order yields, the prompt is never stranded.
//! - A holder keeps the lock at most [`ADMISSION_BOUND`] (its lease): a timer lets it go and logs
//!   the step it was in, so the daemon log names the await that held it.
//! - A prompt someone waits on that has no answer [`ANSWER_BOUND`] after it came (`Hub::
//!   run_prompt_joined`) is put in the queue durably (its `queued` record) and accepted as
//!   queued; it then runs from the queue as a restored prompt does (`queue.rs`
//!   `start_restored`), and the request's final answer is that run's.
//! - A prompt the queue already holds (restored, or deferred here) takes no admission: it has
//!   its place.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::sync::OwnedMutexGuard;
use tokio::time::Instant;

use super::queue::Slot;
use super::queue_admission::QueueLimits;
use super::{Control, Hub, PromptOptions, Session};
use crate::rpc::RpcError;

/// How long a prompt waits for admission, and how long it may hold it.
pub(crate) const ADMISSION_BOUND: Duration = Duration::from_secs(3);
/// How long after it came a prompt someone waits on goes without an answer before it is queued.
pub(crate) const ANSWER_BOUND: Duration = Duration::from_secs(5);
/// How long a prompt someone waits on waits in `queue_slot` for a turn lock held with no turn
/// shown (or a restore) before it joins the queue, which answers it (#55502's bound).
pub(crate) const TURN_LOCK_WAIT: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug)]
pub(super) enum Stage {
    Setup(&'static str),
    DirectDispatch,
}

impl Stage {
    pub(super) fn name(self) -> &'static str {
        match self {
            Self::Setup(name) => name,
            Self::DirectDispatch => "direct dispatch",
        }
    }
}

/// One prompt's admission: the lock while it holds it, the step it is in, and whether it reached
/// a step it must finish (then it is never deferred).
pub struct Admission {
    guard: StdMutex<Option<OwnedMutexGuard<()>>>,
    stage: StdMutex<Stage>,
    committed: AtomicBool,
    acquired: AtomicBool,
    queue_owned: AtomicBool,
    defer_requested: AtomicBool,
    came: Instant,
    /// Someone waits on its acceptance or refusal.
    listened: AtomicBool,
    session: String,
}

impl std::fmt::Debug for Admission {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Admission").field("stage", &self.stage_now()).finish_non_exhaustive()
    }
}

impl Admission {
    /// A prompt's admission as it comes, before it waits for the lock ([`Self::acquire`]).
    pub(crate) fn new(session: &Session) -> Arc<Self> {
        Self::arrived(session, Instant::now())
    }

    fn arrived(session: &Session, came: Instant) -> Arc<Self> {
        Arc::new(Self {
            guard: StdMutex::new(None),
            stage: StdMutex::new(Stage::Setup("admission")),
            committed: AtomicBool::new(false),
            acquired: AtomicBool::new(false),
            queue_owned: AtomicBool::new(false),
            defer_requested: AtomicBool::new(false),
            came,
            listened: AtomicBool::new(false),
            session: session.id.clone(),
        })
    }

    /// No lock, nothing to wait for: a prompt the queue holds already.
    pub(super) fn none(session: &Session) -> Arc<Self> {
        let admission = Self::new(session);
        admission.acquired.store(true, Ordering::SeqCst);
        admission.queue_owned.store(true, Ordering::SeqCst);
        admission
    }

    /// Takes the session's admission, waiting at most [`ADMISSION_BOUND`], and holds it at most
    /// that long (its lease). Once: a prompt the RPC layer admitted does not wait again.
    pub(crate) async fn acquire(
        self: &Arc<Self>,
        session: &Arc<Session>,
        scope: &cmux_scope::Scope,
    ) {
        if self.acquired.swap(true, Ordering::SeqCst) {
            return;
        }
        let lock = session.prompt_admission.clone().lock_owned();
        let due = self.answer_due().min(Instant::now() + ADMISSION_BOUND);
        let Ok(guard) = tokio::time::timeout_at(due, lock).await else {
            tracing::warn!(session = %session.id, "prompt admission wait lapsed: the prompt goes on unordered");
            return;
        };
        *self.guard.lock().unwrap_or_else(|e| e.into_inner()) = Some(guard);
        self.enter("setup");
        let lease = Arc::downgrade(self);
        scope.spawn_named("prompt-admission-lease", async move {
            tokio::time::sleep(ADMISSION_BOUND).await;
            let Some(admission) = lease.upgrade() else { return };
            let lapsed = admission.guard.lock().unwrap_or_else(|e| e.into_inner()).take();
            if lapsed.is_some() {
                let stage = admission.stage_now().name();
                tracing::warn!(session = %admission.session, stage, "prompt admission lease lapsed: let go");
            }
        });
    }

    /// Lets the lock go: the prompt was accepted, or it left.
    pub(crate) fn release(&self) {
        drop(self.guard.lock().unwrap_or_else(|e| e.into_inner()).take());
    }

    /// The step it is in now, named when its lease lapses.
    pub(crate) fn enter(&self, stage: &'static str) {
        *self.stage.lock().unwrap_or_else(|e| e.into_inner()) = Stage::Setup(stage);
    }

    /// This setup owns the next turn until it starts or hands its place to the queue.
    pub(super) fn claimed_direct_turn(&self) {
        *self.stage.lock().unwrap_or_else(|e| e.into_inner()) = Stage::DirectDispatch;
    }

    /// The step it is in.
    pub(super) fn stage_now(&self) -> Stage {
        *self.stage.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// It reached a step it must finish (its acceptance, the inbox, a steer, the queue): it is
    /// not deferred from here on.
    pub(super) fn commit(&self) {
        self.committed.store(true, Ordering::SeqCst);
    }

    pub(super) fn committed(&self) -> bool {
        self.committed.load(Ordering::SeqCst)
    }

    /// A bounded setup probe found a lock that did not return in time. The caller can durably
    /// queue this prompt instead of returning a late "started" answer.
    pub(super) fn request_defer(&self) {
        self.defer_requested.store(true, Ordering::SeqCst);
    }

    pub(super) fn defer_requested(&self) -> bool {
        self.defer_requested.load(Ordering::SeqCst)
    }

    /// A prompt already owned by the durable queue: it may wait for the child outside admission.
    pub(super) fn queue_owned(&self) -> bool {
        self.queue_owned.load(Ordering::SeqCst)
    }

    pub(super) fn listened(&self) -> bool {
        self.listened.load(Ordering::SeqCst)
    }

    /// When an unanswered prompt is queued instead.
    pub(crate) fn answer_due(&self) -> Instant {
        self.came + ANSWER_BOUND
    }

    /// Someone waits on its acceptance or refusal.
    pub(super) fn listen(&self) {
        self.listened.store(true, Ordering::SeqCst);
    }

    /// The due time `queue_slot` keeps to for the turn lock: None when no one waits on it.
    pub(super) fn queue_due(&self) -> Option<Instant> {
        self.listened.load(Ordering::SeqCst).then(|| self.answer_due())
    }
}

/// Takes `session`'s prompt admission for a prompt that came now ([`Admission::acquire`]). The
/// only way a prompt takes it.
pub(crate) async fn admit(
    session: &Arc<Session>,
    scope: &cmux_scope::Scope,
    came: Instant,
) -> Arc<Admission> {
    let admission = Admission::arrived(session, came);
    admission.acquire(session, scope).await;
    admission
}

/// What an unanswered prompt needs to go into the queue on its own, copied before its setup
/// takes its options.
pub(super) struct Deferral {
    blocks: Vec<Value>,
    client: String,
    prompt_id: String,
    control: Control,
    cloud_mobile: bool,
    trust_gate: bool,
    display_parts: Option<Value>,
    provenance: Option<Value>,
    agent: Option<String>,
    class: Option<crate::prompt_class::PromptClass>,
    supersede: Option<String>,
    full_access_device: Option<String>,
    admitted: bool,
    on_accepted: Arc<StdMutex<Option<Box<dyn FnOnce(Value) + Send>>>>,
}

/// How a prompt with no answer by its due time ends.
#[allow(clippy::large_enum_variant)] // one per unanswered prompt, matched at once; boxing buys nothing
pub(super) enum Unanswered {
    /// Queued durably; its run from the queue answers it.
    Defer(Deferral),
    /// It may not queue (`no_queue`, an automatic continuation): busy, as a full chat is.
    Busy,
    /// A process-local race fence cannot be reconstructed by a deferred runner.
    Guarded(Arc<dyn Fn() -> Result<(), RpcError> + Send + Sync>),
    /// A steer that only steers: unavailable.
    SteerUnavailable,
}

impl Unanswered {
    /// Reads `opts` before the prompt's setup takes them. `opts.on_accepted` is routed through
    /// the deferral, so only one of the two ever answers. None when nobody waits on its
    /// acceptance (the daemon's own prompts), or for a Cloud turn whose fence must see it run in
    /// place: it waits on.
    pub(super) fn of(blocks: &[Value], client: &str, opts: &mut PromptOptions) -> Option<Self> {
        if opts.on_accepted.is_none() || opts.cloud_turn.is_some() {
            return None;
        }
        if opts.steer_only {
            return Some(Self::SteerUnavailable);
        }
        if opts.no_queue || opts.after_turn.is_some() {
            return Some(Self::Busy);
        }
        if let Some(guard) = &opts.race_guard {
            return Some(Self::Guarded(guard.clone()));
        }
        // Queue replay carries the durable prompt fields. A live routing or reply contract
        // must be handled on the original request, or refused while it is still retryable.
        if opts.interrupt
            || opts.interrupt_turn.is_some()
            || opts.steer_now
            || opts.send_now
            || opts.thread.is_some()
            || opts.reply_reader.is_some()
            || opts.wake_or_fail
            || opts.inbox
                && super::digest::agent_sender(opts.provenance.as_ref(), opts.agent.as_deref())
                    .is_some()
        {
            return Some(Self::Busy);
        }
        let prompt_id =
            opts.prompt_id.get_or_insert_with(|| uuid::Uuid::now_v7().to_string()).clone();
        let on_accepted = Arc::new(StdMutex::new(opts.on_accepted.take()));
        let routed = on_accepted.clone();
        opts.on_accepted = Some(Box::new(move |v| {
            if let Some(f) = routed.lock().unwrap_or_else(|e| e.into_inner()).take() {
                f(v);
            }
        }));
        let notice = super::inbox::is_notice(opts.provenance.as_ref())
            .then_some(crate::prompt_class::PromptClass::Fyi);
        let agent = super::digest::agent_sender(opts.provenance.as_ref(), opts.agent.as_deref());
        let class = crate::prompt_class::of_message(opts.class.or(notice), agent.is_some());
        Some(Self::Defer(Deferral {
            blocks: blocks.to_vec(),
            client: client.to_owned(),
            prompt_id,
            control: opts.control,
            cloud_mobile: opts.cloud_mobile,
            trust_gate: opts.trust_gate,
            display_parts: opts.display_parts.clone(),
            provenance: opts.provenance.clone(),
            agent,
            class,
            supersede: opts.supersede.clone(),
            full_access_device: opts.full_access_device.clone(),
            admitted: opts.admitted,
            on_accepted,
        }))
    }
}

pub(super) fn restore_deadline() -> RpcError {
    RpcError::deadline_exceeded("prompt waiting for journal restore", ANSWER_BOUND)
}

impl Hub {
    /// Whether the queue holds `prompt_id` already (restored after a restart or a move, or
    /// deferred here): it has its place and takes no admission.
    pub(super) fn queue_holds(session: &Session, prompt_id: Option<&str>) -> bool {
        let Some(prompt_id) = prompt_id else { return false };
        let restored = session.restored.lock().unwrap_or_else(|e| e.into_inner());
        restored.iter().any(|(id, _)| id == prompt_id)
    }

    /// Puts a prompt that got no answer in time into the queue, durably, and accepts it as queued.
    /// Keep any provisional turn up to the journal write, then release it before acceptance.
    pub(super) fn queue_unanswered(
        self: &Arc<Self>,
        session: &Arc<Session>,
        d: Deferral,
        stage: Stage,
        release_claim: impl FnOnce(),
    ) -> Result<super::PromptOutcome, RpcError> {
        let text = super::session::prompt_text(&d.blocks);
        let replaced = std::sync::OnceLock::new();
        let slot = Slot {
            text: &text,
            blocks: &d.blocks,
            display_parts: d.display_parts.as_ref(),
            client: &d.client,
            prompt_id: &d.prompt_id,
            control: d.control,
            cloud_mobile: d.cloud_mobile,
            trust_gate: d.trust_gate,
            interrupt: false,
            interrupt_turn: None,
            provenance: d.provenance.as_ref(),
            agent: d.agent.as_deref(),
            class: d.class,
            supersede: d.supersede.as_deref(),
            full_access_device: d.full_access_device.as_deref(),
            replaced: &replaced,
            no_queue: false,
            admitted: d.admitted,
            after_turn: false,
            steer_on_start: false,
            answer_due: None,
        };
        if let Some(refused) = self.takes_no_prompt(session, &slot) {
            return Err(refused);
        }
        // At the answer deadline, respect the configured limits and any hold a restored
        // runner could skip. A retry can use normal admission once configuration is available.
        let limits = {
            let cfg = self.config.try_read().map_err(|_| super::auto_resume::retry_turn::busy())?;
            if super::person_hold::holds(&slot)
                && super::person_hold::hold_ms(&cfg, &session.meta().name).is_some()
            {
                return Err(super::auto_resume::retry_turn::busy());
            }
            QueueLimits::of(&cfg)
        };
        let turn_id = uuid::Uuid::now_v7().to_string();
        let claimed = matches!(stage, Stage::DirectDispatch);
        let (outcome, position) = {
            // A restore must not start between our check and the queued journal entry.
            // Its writer can still be finishing the last page after releasing its lease.
            let _admit = session.admit.lock().unwrap_or_else(|e| e.into_inner());
            if session.restoring.load(Ordering::SeqCst)
                || session.restore_token.load(Ordering::SeqCst) != 0
            {
                return Err(restore_deadline());
            }
            session.queued.fetch_add(1, Ordering::SeqCst);
            self.enqueue_admitted(session, &slot, &turn_id, limits, claimed, |row, _| {
                let outcome = super::prompt_ledger::recover(session, &row.prompt_id);
                row.restored = true;
                row.resume = true;
                session
                    .restored
                    .lock()
                    .unwrap_or_else(|e| e.into_inner())
                    .push((row.prompt_id.clone(), row.turn_id.clone()));
                outcome
            })?
        };
        // The queue's own from now on, as `restore_queues` makes a prompt it read back: the
        // queue runs it, and a resend of its id waits on its ledger entry.
        let stage = stage.name();
        release_claim();
        tracing::warn!(session = %session.id, prompt = %d.prompt_id, stage, position, "prompt unanswered in time: queued");
        let accepted = json!({"sessionId": session.id, "promptId": d.prompt_id, "turnId": turn_id, "queued": true, "state": "queued", "position": position, "deferred": true});
        if let Some(f) = d.on_accepted.lock().unwrap_or_else(|e| e.into_inner()).take() {
            f(accepted);
        }
        Ok(outcome)
    }
}
