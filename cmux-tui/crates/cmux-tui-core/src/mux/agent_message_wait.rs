//! `agent.message.wait` (issue 36496): the blocking claim a native terminal
//! agent's hook makes for the messages queued to its terminal.
//!
//! Native interactive Claude Code wakes from an idle prompt only through an
//! `asyncRewake` hook: a background command that exits 2 hands its stderr to
//! the model as a system reminder, and the prompt box (any draft in it) is
//! never touched. The hook asks the daemon here, on one connection, and the
//! daemon answers when there is something to hand over. Nothing polls: the
//! wait sleeps on one wake that a send, a release, the agent's state change,
//! the terminal's close, a newer poller or a lease's expiry sets, and its
//! deadline is the caller's bounded timeout.
//!
//! Claims are leases kept in memory. A claim leases the oldest queued
//! deliveries that fit one batch (`agent_message_prompt::batch`) to the
//! claimer for [`LEASE`]; another claim of the same recipient skips them, so
//! the wake hook and the prompt-submit drain never hand over the same message
//! at once. The claimer shows the messages and then marks them `delivered`
//! (`agent.message.mark`), which ends the lease. A claimer that dies before
//! that, a lost response, or a daemon restart leaves the deliveries `queued`,
//! and they are offered again once the lease is over: delivery is at least
//! once, never exactly once. `delivered` records that the hook handed the
//! text to the agent's process, not that the model read or acted on it.
//!
//! A wait holds back (claims nothing) while the agent waits on the person (its
//! state is `blocked`: a permission, question or plan prompt is open), while
//! the agent session it names has ended on that terminal, and while the
//! agent's process is gone. Each recipient has one poller: a newer one
//! supersedes the older, which then answers `superseded`, so repeated
//! `Stop` hooks or a replaced session never leave two wake hooks claiming.
//!
//! A wait that names its agent session is bound to it before it registers
//! or claims anything: the terminal's hook fence must name that session. A
//! wait for another session (a replaced one, or the old session of a Claude
//! process that resumed another, which keeps its process id) neither
//! registers nor claims; it answers `stale` once [`SESSION_GRACE`] passes,
//! which also lets a new session's start reach the fence first.
//!
//! The binding, the poller check, the person hold and the lease are one
//! critical section under the hook-fence lock, the lock under which every
//! fence move and agent state change commits (`agent_message_attempt`). A
//! session change therefore lands wholly before a claim (the claim sees it)
//! or wholly after its lease. After the lease it cannot be taken back: those
//! messages went to the session that was live when they were leased, and
//! its hook shows them to that session's process.

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::Mux;
use super::ResourceWaitWake;
use crate::mux::AgentState;
use crate::resource::{ResourceError, TerminalPublicId};
use crate::state::agent_message_store::{self as messages, AgentMessageFilter};

/// The setting that turns idle wakes off (Settings > Agents > Agent Messages;
/// schemas/settings/source/agent-messages.json). A wait with a poller is a
/// wake hook's; prompt hooks (no poller) hand messages over either way.
pub(crate) const WAKE_SETTING: &str = "agents.messages.claudeWake";

/// How long a claim keeps its messages from other claimers.
pub(crate) const LEASE: Duration = Duration::from_secs(30);
/// The longest one wait may block; a hook re-arms after it.
pub(crate) const WAIT_TIMEOUT_MAX: Duration = Duration::from_secs(15 * 60);
/// Queued deliveries one claim reads, oldest first, before the batch cut.
const CLAIM_PAGE: usize = 50;
/// How long a wait whose session the terminal's hooks have not confirmed
/// holds (a new session's start may still be on its way into the fence)
/// before it answers `stale`.
pub(crate) const SESSION_GRACE: Duration = Duration::from_secs(30);

/// One claim's messages, kept from other claimers until it ends.
#[derive(Debug, Clone)]
struct Lease {
    messages: Vec<String>,
    expires: Instant,
}

#[derive(Default)]
struct WaitState {
    next_waiter: u64,
    next_lease: u64,
    /// Recipient -> the waits sleeping on it.
    waiters: HashMap<String, HashMap<u64, Weak<ResourceWaitWake>>>,
    /// Recipient -> its current poller key.
    pollers: HashMap<String, String>,
    /// Recipient -> its open claims.
    leases: HashMap<String, Vec<Lease>>,
}

/// The waits, pollers and claims of every recipient. Memory only: a restart
/// forgets them, which returns every claimed delivery to the queue.
#[derive(Default)]
pub(crate) struct AgentMessageWaits {
    state: Mutex<WaitState>,
    /// Runs inside a claim's critical section, after its checks and before
    /// its lease (tests: a deterministic interleaving point).
    #[cfg(test)]
    pause_for_test: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
}

/// A wait's registration; dropping it unregisters the wake.
pub(crate) struct AgentMessageWaitSubscription<'a> {
    owner: &'a AgentMessageWaits,
    recipient: String,
    id: u64,
    wake: Arc<ResourceWaitWake>,
}

impl AgentMessageWaitSubscription<'_> {
    pub(crate) fn wake(&self) -> Arc<ResourceWaitWake> {
        self.wake.clone()
    }

    /// True for an explicit wake, false when `deadline` passed first.
    pub(crate) fn wait_until(&self, deadline: Option<Instant>) -> bool {
        self.wake.wait_until(deadline)
    }
}

impl Drop for AgentMessageWaitSubscription<'_> {
    fn drop(&mut self) {
        let mut state = self.owner.lock();
        let empty = state.waiters.get_mut(&self.recipient).is_some_and(|waiters| {
            waiters.remove(&self.id);
            waiters.is_empty()
        });
        if empty {
            state.waiters.remove(&self.recipient);
        }
    }
}

impl AgentMessageWaits {
    fn lock(&self) -> std::sync::MutexGuard<'_, WaitState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Registers a wake for `recipient`. Register before reading the queue:
    /// a change after the read then still wakes the wait.
    pub(crate) fn subscribe(&self, recipient: &str) -> AgentMessageWaitSubscription<'_> {
        let wake = Arc::new(ResourceWaitWake::default());
        let mut state = self.lock();
        let id = state.next_waiter;
        state.next_waiter = state.next_waiter.wrapping_add(1);
        state.waiters.entry(recipient.to_owned()).or_default().insert(id, Arc::downgrade(&wake));
        drop(state);
        AgentMessageWaitSubscription { owner: self, recipient: recipient.to_owned(), id, wake }
    }

    /// Wakes every wait on `recipient`.
    pub(crate) fn notify(&self, recipient: &str) {
        let waiters = self.lock().waiters.get(recipient).cloned().unwrap_or_default();
        for wake in waiters.into_values().filter_map(|wake| wake.upgrade()) {
            wake.notify();
        }
    }

    /// Wakes every wait (a release or a reply whose recipient the caller does
    /// not know).
    pub(crate) fn notify_all(&self) {
        let waiters: Vec<_> = self
            .lock()
            .waiters
            .values()
            .flat_map(|waiters| waiters.values().cloned().collect::<Vec<_>>())
            .collect();
        for wake in waiters.into_iter().filter_map(|wake| wake.upgrade()) {
            wake.notify();
        }
    }

    /// Makes `poller` the recipient's poller and wakes the waits there, so
    /// the poller it replaces sees that and ends. Without `replace`, only a
    /// recipient that has none takes it (a re-arming poller after a daemon
    /// restart), so a superseded poller never takes its place back.
    pub(crate) fn register_poller(&self, recipient: &str, poller: &str, replace: bool) {
        let mut state = self.lock();
        let current = state.pollers.get(recipient);
        if current.is_some_and(|current| current == poller) || (!replace && current.is_some()) {
            return;
        }
        state.pollers.insert(recipient.to_owned(), poller.to_owned());
        drop(state);
        self.notify(recipient);
    }

    pub(crate) fn is_current_poller(&self, recipient: &str, poller: &str) -> bool {
        self.lock().pollers.get(recipient).is_some_and(|current| current == poller)
    }

    /// Forgets the poller of a closed terminal.
    pub(crate) fn forget_recipient(&self, recipient: &str) {
        let mut state = self.lock();
        state.pollers.remove(recipient);
        state.leases.remove(recipient);
    }

    /// The message ids leased to claimers of `recipient` at `now`; expired
    /// claims are dropped.
    fn leased(&self, recipient: &str, now: Instant) -> HashSet<String> {
        let mut state = self.lock();
        let Some(leases) = state.leases.get_mut(recipient) else { return HashSet::new() };
        leases.retain(|lease| lease.expires > now);
        let leased = leases.iter().flat_map(|lease| lease.messages.iter().cloned()).collect();
        if leases.is_empty() {
            state.leases.remove(recipient);
        }
        leased
    }

    fn lease(&self, recipient: &str, ids: Vec<String>, now: Instant) -> String {
        let mut state = self.lock();
        let number = state.next_lease;
        state.next_lease = state.next_lease.wrapping_add(1);
        let id = format!("lease_{number}");
        state
            .leases
            .entry(recipient.to_owned())
            .or_default()
            .push(Lease { messages: ids, expires: now + LEASE });
        id
    }

    /// Ends the claims of `ids` (marked delivered, acknowledged or failed).
    pub(crate) fn release(&self, recipient: &str, ids: &[String]) {
        let mut state = self.lock();
        let Some(leases) = state.leases.get_mut(recipient) else { return };
        for lease in leases.iter_mut() {
            lease.messages.retain(|id| !ids.contains(id));
        }
        leases.retain(|lease| !lease.messages.is_empty());
        if leases.is_empty() {
            state.leases.remove(recipient);
        }
    }

    /// When the recipient's next claim expires: its messages are offered
    /// again then, so a wait wakes for it (a one-shot deadline, not a poll).
    fn next_expiry(&self, recipient: &str) -> Option<Instant> {
        self.lock().leases.get(recipient)?.iter().map(|lease| lease.expires).min()
    }

    #[cfg(test)]
    pub(crate) fn lease_count_for_test(&self, recipient: &str) -> usize {
        self.lock().leases.get(recipient).map(Vec::len).unwrap_or_default()
    }

    /// Ends every claim of `recipient` now, as if its lease time passed.
    #[cfg(test)]
    pub(crate) fn expire_for_test(&self, recipient: &str) {
        let now = Instant::now();
        for lease in self.lock().leases.get_mut(recipient).into_iter().flatten() {
            lease.expires = now;
        }
    }

    /// Runs `pause` inside every claim's critical section from now on.
    #[cfg(test)]
    pub(crate) fn set_pause_for_test(&self, pause: Option<Arc<dyn Fn() + Send + Sync>>) {
        *self.pause_for_test.lock().unwrap_or_else(PoisonError::into_inner) = pause;
    }

    #[cfg(test)]
    fn pause_point_for_test(&self) {
        let pause = self.pause_for_test.lock().unwrap_or_else(PoisonError::into_inner).clone();
        if let Some(pause) = pause {
            pause();
        }
    }

    #[cfg(test)]
    pub(crate) fn waiter_count_for_test(&self, recipient: &str) -> usize {
        self.lock().waiters.get(recipient).map(HashMap::len).unwrap_or_default()
    }
}

/// One `agent.message.wait` request.
#[derive(Debug, Clone, Default)]
pub(crate) struct AgentMessageWait {
    /// The terminal (`term_...`) whose queued messages the caller claims.
    pub(crate) recipient: String,
    /// The caller's poller key: a wake hook names one, a one-shot claim (a
    /// prompt hook) none. The recipient's current poller alone claims; a
    /// newer registration supersedes it.
    pub(crate) poller: Option<String>,
    /// Make `poller` the current one (a hook's first request). Without it the
    /// poller only takes a vacant place (the daemon restarted).
    pub(crate) register: bool,
    /// The agent session the caller runs in. While the terminal's agent hooks
    /// report that session ended, nothing is claimed.
    pub(crate) agent_session_id: Option<String>,
    /// The agent's process. Once it is gone the wait answers `stale`.
    pub(crate) agent_pid: Option<u32>,
    /// Claim nothing while the agent waits on the person (`blocked`).
    pub(crate) respect_hold: bool,
    pub(crate) timeout: Duration,
}

impl AgentMessageWait {
    /// The request's catalog-validated fields.
    pub(crate) fn from_fields(
        fields: &serde_json::Map<String, Value>,
    ) -> Result<Self, ResourceError> {
        let string = |name: &str| fields.get(name).and_then(Value::as_str).map(str::to_owned);
        let timeout = match fields.get("timeout_ms") {
            None => Duration::ZERO,
            Some(value) => serde_json::from_value::<crate::resource::WireDecimal>(value.clone())
                .map(|millis| Duration::from_millis(millis.get()))
                .map_err(|_| {
                    ResourceError::validation_invalid(
                        Some("timeout_ms"),
                        "timeout_ms must be a decimal millisecond count",
                    )
                })?,
        };
        let agent_pid =
            fields.get("agent_pid").and_then(Value::as_u64).and_then(|pid| u32::try_from(pid).ok());
        Ok(Self {
            recipient: string("recipient").unwrap_or_default(),
            poller: string("poller"),
            register: fields.get("register").and_then(Value::as_bool).unwrap_or(false),
            agent_session_id: string("agent_session_id"),
            agent_pid,
            respect_hold: fields.get("respect_hold").and_then(Value::as_bool).unwrap_or(true),
            timeout,
        })
    }
}

/// What one claim attempt found.
#[derive(Debug)]
enum Attempt {
    /// Answer the wait with this.
    Answer(Value),
    /// The terminal's hooks name another session, or none yet.
    Unconfirmed,
    /// Nothing to hand over now; why, when it is held back.
    Nothing(Option<Holdback>),
}

/// Why a wait claims nothing now, if it does not.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Holdback {
    /// A permission, question or plan prompt is open.
    WaitingOnPerson,
    /// The named agent session ended on this terminal.
    SessionEnded,
}

impl Holdback {
    fn as_str(self) -> &'static str {
        match self {
            Self::WaitingOnPerson => "waiting_on_person",
            Self::SessionEnded => "session_ended",
        }
    }
}

impl Mux {
    pub(crate) fn agent_message_waits(&self) -> &AgentMessageWaits {
        &self.agent_message_waits
    }

    /// `agent.message.wait`. `stopped` says the caller went away (connection
    /// closed or request canceled); `register` hands each wake to those
    /// sources so they end the sleep. `Ok(None)`: stopped, no answer.
    pub(crate) fn agent_message_wait(
        &self,
        selectors: &crate::ResourceSelectors,
        request: &AgentMessageWait,
        stopped: &dyn Fn() -> bool,
        register: &dyn Fn(&Arc<ResourceWaitWake>),
    ) -> Result<Option<Value>, ResourceError> {
        self.resolve_resource_path(crate::ResourceTarget::Session, selectors)?;
        let recipient = request.recipient.as_str();
        let terminal = TerminalPublicId::parse(recipient)
            .ok()
            .filter(|_| messages::is_recipient_address(recipient))
            .ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some("recipient"),
                    "agent.message.wait claims for a terminal agent (term_...); acpmux sessions \
                     receive their messages from the daemon's delivery pump",
                )
            })?;
        if request.timeout > WAIT_TIMEOUT_MAX {
            return Err(ResourceError::validation_invalid(
                Some("timeout_ms"),
                "agent.message.wait blocks for at most 900000 ms; wait again after it answers",
            ));
        }
        let started = Instant::now();
        let deadline = started + request.timeout;
        let unconfirmed_until = (started + SESSION_GRACE).min(deadline);
        let waits = self.agent_message_waits();
        let mut registered = request.poller.is_none();
        loop {
            if stopped() {
                return Ok(None);
            }
            let subscription = waits.subscribe(recipient);
            register(&subscription.wake());
            if stopped() {
                return Ok(None);
            }
            if self.resource_surface_for_terminal(&terminal).is_none() {
                return Ok(Some(json!({"status":"gone"})));
            }
            if request.agent_pid.is_some_and(|pid| !process_alive(pid)) {
                return Ok(Some(json!({"status":"stale","reason":"agent_exited"})));
            }
            let holdback = match self.agent_message_attempt(&terminal, request, &mut registered)? {
                Attempt::Answer(answer) => return Ok(Some(answer)),
                Attempt::Unconfirmed => {
                    if Instant::now() >= unconfirmed_until {
                        return Ok(Some(json!({"status":"stale","reason":"session_replaced"})));
                    }
                    // The fence's change wakes this (agent_roster_fold.rs).
                    subscription.wait_until(Some(unconfirmed_until));
                    continue;
                }
                Attempt::Nothing(holdback) => holdback,
            };
            let now = Instant::now();
            if now >= deadline {
                let answer = match holdback {
                    Some(holdback) => json!({"status":"timeout", "held": holdback.as_str()}),
                    None => json!({"status":"timeout"}),
                };
                return Ok(Some(answer));
            }
            // Only a claim still running can end later; one already over is
            // pruned by the next claim, so it never makes this wake at once.
            let wake_at = waits
                .next_expiry(recipient)
                .filter(|at| *at > now)
                .map_or(deadline, |at| at.min(deadline));
            subscription.wait_until(Some(wake_at));
        }
    }

    /// One claim attempt, as one critical section under the hook-fence lock.
    ///
    /// Every change that decides eligibility commits under that lock: the
    /// roster fold moves a terminal's fence and commits its agent state
    /// (`blocked` included) while holding it, a direct report takes it before
    /// the registry, and a poller registers only here. So the session
    /// binding, the poller registration and check, the person hold, the queue
    /// read and the lease all see one state; a transition commits wholly
    /// before or wholly after the attempt, never between its check and its
    /// lease. Lock order as the report path: fences, registry, agent records,
    /// then this module's leaf state.
    fn agent_message_attempt(
        &self,
        terminal: &TerminalPublicId,
        request: &AgentMessageWait,
        registered: &mut bool,
    ) -> Result<Attempt, ResourceError> {
        let recipient = terminal.as_str();
        let waits = self.agent_message_waits();
        let fences = self.agent_hook_fences.lock().unwrap_or_else(PoisonError::into_inner);
        // The effective setting, read from the settings owner inside this
        // section (fences, then the settings store; a settings change takes
        // the store, then only the waits' leaf state to wake them). Managed
        // (MDM, team) values outrank the person's file, so a policy that
        // forces it off holds whatever the file says. Absent: on.
        if request.poller.is_some()
            && self.effective_setting(WAKE_SETTING).and_then(|value| value.as_bool()) == Some(false)
        {
            return Ok(Attempt::Answer(json!({"status":"disabled","reason":"setting_off"})));
        }
        let fence = fences.get(terminal);
        if let Some(session) = request.agent_session_id.as_deref()
            && fence.is_none_or(|fence| fence.session_id != session)
        {
            return Ok(Attempt::Unconfirmed);
        }
        // A poller registers only once its session is bound: a stale wait
        // never supersedes the live session's poller.
        if !*registered && let Some(poller) = &request.poller {
            waits.register_poller(recipient, poller, request.register);
            *registered = true;
        }
        if let Some(poller) = &request.poller
            && !waits.is_current_poller(recipient, poller)
        {
            return Ok(Attempt::Answer(json!({"status":"superseded"})));
        }
        if request.respect_hold
            && self
                .agent_records
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .get(terminal)
                .is_some_and(|record| record.state == AgentState::Blocked)
        {
            return Ok(Attempt::Nothing(Some(Holdback::WaitingOnPerson)));
        }
        // A session that ended here may resume (its next SessionStart lifts
        // the fence), so this holds back instead of answering `stale`.
        if request.agent_session_id.is_some() && fence.is_some_and(|fence| fence.ended) {
            return Ok(Attempt::Nothing(Some(Holdback::SessionEnded)));
        }
        #[cfg(test)]
        waits.pause_point_for_test();
        let claim = self.claim_agent_messages(recipient)?;
        drop(fences);
        Ok(claim.map_or(Attempt::Nothing(None), Attempt::Answer))
    }

    /// Leases the oldest queued messages of `recipient` that no other claim
    /// holds and that fit one batch, and returns them; `None` when there are
    /// none. Only [`Self::agent_message_attempt`] calls it, under the
    /// hook-fence lock, which also keeps two claimers from leasing one message.
    fn claim_agent_messages(&self, recipient: &str) -> Result<Option<Value>, ResourceError> {
        let waits = self.agent_message_waits();
        let filter = AgentMessageFilter {
            recipient: Some(recipient.to_owned()),
            state: Some("queued".to_owned()),
            oldest_first: true,
            ..AgentMessageFilter::default()
        };
        let session_id = self.session_public_id.as_str().to_owned();
        let now_ms = crate::state::agent_message_policy::now_ms();
        let queued = self
            .read_registry_state(|connection| {
                messages::list(connection, &session_id, &filter, CLAIM_PAGE, now_ms)
            })
            .map_err(crate::resource_api::operation_failed)?;
        let now = Instant::now();
        let leased = waits.leased(recipient, now);
        let free: Vec<Value> = queued
            .into_iter()
            .filter(|message| message_id(message).is_some_and(|id| !leased.contains(id)))
            .collect();
        if free.is_empty() {
            return Ok(None);
        }
        let batch = crate::agent_message_prompt::batch(free);
        let ids: Vec<String> =
            batch.iter().filter_map(|message| message_id(message).map(str::to_owned)).collect();
        let lease = waits.lease(recipient, ids, now);
        Ok(Some(json!({
            "status": "claimed",
            "lease_id": lease,
            "lease_ms": LEASE.as_millis().to_string(),
            "messages": batch,
        })))
    }

    /// After a send commits: wake the waits of its recipients.
    pub(crate) fn notify_agent_message_waits(&self, recipients: &[String]) {
        let waits = self.agent_message_waits();
        if recipients.is_empty() {
            waits.notify_all();
        }
        for recipient in recipients.iter().filter(|recipient| recipient.starts_with("term_")) {
            waits.notify(recipient);
        }
    }
}

/// A stored message snapshot's id; a snapshot without one is never leased.
fn message_id(message: &Value) -> Option<&str> {
    message.get("id").and_then(Value::as_str)
}

#[cfg(unix)]
fn process_alive(pid: u32) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    if pid <= 1 {
        return false;
    }
    // SAFETY: signal 0 only checks that the process exists.
    let result = unsafe { libc::kill(pid, 0) };
    result == 0 || std::io::Error::last_os_error().raw_os_error() != Some(libc::ESRCH)
}

#[cfg(not(unix))]
fn process_alive(_pid: u32) -> bool {
    true
}
