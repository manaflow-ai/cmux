//! VM activity sender (plans/cmux-next/cloud-automation.md 27). The daemon owns three facts
//! for the Cloud VM agent: when a person last gave input, when an agent last acted, and how
//! many sessions are live. `subscribe-activity` gets a snapshot, then `activity-changed`
//! events pushed on change, at most one per second (leading edge plus one trailing event).
//! Times and counts only: no content and no surface ids leave the daemon.
//!
//! No polling: the worker thread blocks on a condvar until a change arrives and waits with a
//! timeout only to keep the one-second spacing. It exits when the last subscriber leaves.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::{MessageWriter, Mux};
use crate::request_origin::RequestOrigin;
use crate::resource::ResourceOperation;
use crate::{AgentState, MuxEvent};

pub(crate) const CAPABILITY: &str = "vm-activity-v1";
const MIN_INTERVAL: Duration = Duration::from_secs(1);
const MAX_SUBSCRIBERS: usize = 16;
/// `set-client-info` kinds a person drives; automation connections never count.
const PERSON_KINDS: [&str; 4] = ["tui", "web", "mac", "frontend"];

#[derive(Default)]
struct State {
    user_input_ms: Option<u64>,
    agent_action_ms: Option<u64>,
    subscribers: BTreeMap<u64, MessageWriter>,
    dirty: bool,
    last_emit: Option<Instant>,
    worker: bool,
    mux: Weak<Mux>,
}

/// The stream's state behind its lock, the worker's wake, and the two facts a person's key writes with no lock
/// (R-DAEMON-STATE stage S1).
#[derive(Default)]
struct Shared {
    state: Mutex<State>,
    wake: Condvar,
    /// A person's last input time in Unix milliseconds (0: none) on the lock-free arm; `State::user_input_ms` stays
    /// `None` there.
    user_input_ms: AtomicU64,
    /// Whether the stream has subscribers; written under `state`'s lock.
    subscribed: AtomicBool,
    /// A key already asked the worker for an event that is not out yet; cleared by the worker under the lock.
    wake_pending: AtomicBool,
}

impl Shared {
    /// A person's last input time from either arm.
    fn user_input_ms(&self, state: &State) -> Option<u64> {
        let atomic = Some(self.user_input_ms.load(Ordering::SeqCst)).filter(|ms| *ms != 0);
        match (state.user_input_ms, atomic) {
            (Some(locked), Some(atomic)) => Some(locked.max(atomic)),
            (locked, atomic) => locked.or(atomic),
        }
    }
}

#[derive(Default)]
pub(crate) struct ActivityStream {
    shared: Arc<Shared>,
    /// The mux's stage S1 switch: a person's key notes its input time with no lock.
    lock_free: AtomicBool,
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

impl ActivityStream {
    /// A stream whose person input notes take no lock when `lock_free` (the mux's stage S1 switch).
    pub(crate) fn new(lock_free: bool) -> Self {
        Self { shared: Arc::default(), lock_free: AtomicBool::new(lock_free) }
    }

    /// Turns stage S1 on or off (tests).
    #[cfg(test)]
    pub(crate) fn set_lock_free_for_test(&self, on: bool) {
        self.lock_free.store(on, Ordering::Relaxed);
    }

    /// Input from a person's attached client (callers filter unattached one-shot sends). On the lock-free arm the
    /// time is an atomic; only while a subscriber exists does a key take the lock, once per event the worker sends.
    pub(crate) fn note_user_input(&self) {
        if !self.lock_free.load(Ordering::Relaxed) {
            self.update(|state| state.user_input_ms = Some(now_ms()));
            return;
        }
        // SeqCst: either this key sees the subscriber, or the subscriber's first snapshot sees this time. A key
        // preempted after its clock read never moves the time back.
        self.shared.user_input_ms.fetch_max(now_ms(), Ordering::SeqCst);
        if self.shared.subscribed.load(Ordering::SeqCst)
            && !self.shared.wake_pending.swap(true, Ordering::SeqCst)
        {
            self.update(|_| {});
        }
    }

    /// An agent hook commit or an agent state report.
    pub(crate) fn note_agent_action(&self) {
        self.update(|state| state.agent_action_ms = Some(now_ms()));
    }

    /// The agent roster changed. Its owner folds after the request that
    /// changed it answered (mux/agent_roster_worker.rs), so an event sent in
    /// between counted the old live agents: the next event counts again.
    pub(crate) fn note_roster_changed(&self) {
        self.update(|_| {});
    }

    /// Runs `hold` while this thread holds the stream's lock (tests: a person's key must not wait for it).
    #[cfg(test)]
    pub(crate) fn hold_for_test(&self, hold: &dyn Fn()) {
        let _held = self.shared.state.lock().unwrap_or_else(PoisonError::into_inner);
        hold();
    }

    /// The last person's input time, in Unix milliseconds (tests).
    #[cfg(test)]
    pub(crate) fn user_input_ms_for_test(&self) -> Option<u64> {
        let state = self.shared.state.lock().unwrap_or_else(PoisonError::into_inner);
        self.shared.user_input_ms(&state)
    }

    /// Mux events that change the counts or mean an agent acted.
    pub(crate) fn observe(&self, event: &MuxEvent) {
        match event {
            MuxEvent::AgentChanged { .. } => self.note_agent_action(),
            MuxEvent::ClientAttached { .. } | MuxEvent::ClientDetached(_) => self.update(|_| {}),
            _ => {}
        }
    }

    fn update(&self, change: impl FnOnce(&mut State)) {
        let mut state = self.shared.state.lock().unwrap_or_else(PoisonError::into_inner);
        change(&mut state);
        if !state.subscribers.is_empty() {
            state.dirty = true;
            self.shared.wake.notify_one();
        }
    }

    pub(super) fn subscribe(
        &self,
        mux: &Arc<Mux>,
        client: u64,
        writer: &MessageWriter,
    ) -> anyhow::Result<Value> {
        let times = {
            let mut state = self.shared.state.lock().unwrap_or_else(PoisonError::into_inner);
            anyhow::ensure!(
                state.subscribers.len() < MAX_SUBSCRIBERS
                    || state.subscribers.contains_key(&client),
                "too many activity subscribers"
            );
            // Closed connections leave here or at the next send; no disconnect hook.
            state.subscribers.retain(|_, w| w.is_open());
            state.mux = Arc::downgrade(mux);
            state.subscribers.insert(client, writer.clone());
            self.shared.subscribed.store(true, Ordering::SeqCst);
            // A wake a key asked for before any subscriber existed is not pending for this one.
            self.shared.wake_pending.store(false, Ordering::SeqCst);
            if !state.worker {
                state.worker = true;
                let shared = Arc::clone(&self.shared);
                std::thread::Builder::new()
                    .name("cmux-activity".into())
                    .spawn(move || run_worker(shared))?;
            }
            (self.shared.user_input_ms(&state), state.agent_action_ms)
        };
        Ok(json!({ "activity": snapshot(mux, times) }))
    }

    fn disconnect(&self, client: u64) {
        let mut state = self.shared.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.subscribers.remove(&client).is_some() && state.subscribers.is_empty() {
            self.shared.subscribed.store(false, Ordering::SeqCst);
            self.shared.wake.notify_one();
        }
    }
}

/// A person's client: the verified app's main connection (origin `user`), or a connection
/// attached to a surface whose `set-client-info` kind is a person's client. Agents and
/// automation (no attach, or another kind) never count, so they cannot keep a machine awake.
fn is_person(mux: &Mux, client: u64) -> bool {
    let state = mux.control_clients.state.lock().unwrap_or_else(PoisonError::into_inner);
    state.clients.get(&client).is_some_and(|c| {
        c.origin.derive() == RequestOrigin::User
            || (!c.attached.is_empty()
                && c.kind.as_deref().is_some_and(|k| PERSON_KINDS.contains(&k)))
    })
}

/// Browser pointer, wheel or key input that succeeded (server/browser_input.rs).
pub(super) fn note_person_input(mux: &Mux, client: u64) {
    if is_person(mux, client) {
        mux.activity.note_user_input();
    }
}

/// A v2 `terminal.input.*` operation that succeeded counts when a person's client sent it.
pub(super) fn note_resource_input(
    mux: &Mux,
    client: u64,
    operation: ResourceOperation,
    response: &Value,
) {
    let input = matches!(
        operation,
        ResourceOperation::TerminalInputWrite
            | ResourceOperation::TerminalInputKeys
            | ResourceOperation::TerminalInputMouse
            | ResourceOperation::TerminalInputFocus
    );
    if input && response["ok"] == true {
        note_person_input(mux, client);
    }
}

/// Counts are read at emit time from their owners (client registry, agent roster).
fn snapshot(mux: &Mux, (user_input_ms, agent_action_ms): (Option<u64>, Option<u64>)) -> Value {
    let attached_clients = {
        let state = mux.control_clients.state.lock().unwrap_or_else(PoisonError::into_inner);
        state
            .clients
            .values()
            .filter(|c| {
                !c.attached.is_empty()
                    && c.kind.as_deref().is_some_and(|k| PERSON_KINDS.contains(&k))
            })
            .count()
    };
    let live_agents = mux
        .list_agents(None, None)
        .iter()
        .filter(|a| matches!(a.state, AgentState::Working | AgentState::Blocked))
        .count();
    json!({
        "attached_clients": attached_clients,
        "live_agents": live_agents,
        "last_user_input_at_ms": user_input_ms,
        "last_agent_action_at_ms": agent_action_ms,
    })
}

type Due = (Vec<(u64, MessageWriter)>, (Option<u64>, Option<u64>), Weak<Mux>);

/// Blocks until a change is due; `None` when the last subscriber left.
fn next_due(shared: &Shared) -> Option<Due> {
    let mut state = shared.state.lock().unwrap_or_else(PoisonError::into_inner);
    loop {
        if state.subscribers.is_empty() {
            state.worker = false;
            shared.subscribed.store(false, Ordering::SeqCst);
            shared.wake_pending.store(false, Ordering::SeqCst);
            return None;
        }
        if state.dirty {
            let wait = state
                .last_emit
                .map_or(Duration::ZERO, |last| MIN_INTERVAL.saturating_sub(last.elapsed()));
            if wait.is_zero() {
                break;
            }
            state = shared.wake.wait_timeout(state, wait).unwrap_or_else(PoisonError::into_inner).0;
            continue;
        }
        state = shared.wake.wait(state).unwrap_or_else(PoisonError::into_inner);
    }
    state.dirty = false;
    // Before the time is read: a key that finds this cleared asks for the next event.
    shared.wake_pending.store(false, Ordering::SeqCst);
    state.last_emit = Some(Instant::now());
    let writers = state.subscribers.iter().map(|(c, w)| (*c, w.clone())).collect();
    Some((writers, (shared.user_input_ms(&state), state.agent_action_ms), state.mux.clone()))
}

fn run_worker(shared: Arc<Shared>) {
    while let Some((writers, times, mux)) = next_due(&shared) {
        let Some(mux) = mux.upgrade() else { break };
        let event = json!({ "event": "activity-changed", "activity": snapshot(&mux, times) });
        for (client, writer) in writers {
            if !writer.is_open() || writer.send_control(&event).is_err() {
                mux.activity.disconnect(client);
            }
        }
    }
}
