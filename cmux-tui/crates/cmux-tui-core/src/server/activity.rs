//! VM activity sender (plans/cmux-next/cloud-automation.md 27). The daemon owns three facts
//! for the Cloud VM agent: when a person last gave input, when an agent last acted, and how
//! many sessions are live. `subscribe-activity` gets a snapshot, then `activity-changed`
//! events pushed on change, at most one per second (leading edge plus one trailing event).
//! Times and counts only: no content and no surface ids leave the daemon.
//!
//! No polling: the worker thread blocks on a condvar until a change arrives and waits with a
//! timeout only to keep the one-second spacing. It exits when the last subscriber leaves.

use std::collections::BTreeMap;
use std::sync::{Arc, Condvar, Mutex, PoisonError, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::{MessageWriter, Mux};
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

#[derive(Default)]
pub(crate) struct ActivityStream {
    shared: Arc<(Mutex<State>, Condvar)>,
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

impl ActivityStream {
    /// Input from a person's attached client (callers filter unattached one-shot sends).
    pub(crate) fn note_user_input(&self) {
        self.update(|state| state.user_input_ms = Some(now_ms()));
    }

    /// An agent hook commit or an agent state report.
    pub(crate) fn note_agent_action(&self) {
        self.update(|state| state.agent_action_ms = Some(now_ms()));
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
        let (lock, wake) = &*self.shared;
        let mut state = lock.lock().unwrap_or_else(PoisonError::into_inner);
        change(&mut state);
        if !state.subscribers.is_empty() {
            state.dirty = true;
            wake.notify_one();
        }
    }

    pub(super) fn subscribe(
        &self,
        mux: &Arc<Mux>,
        client: u64,
        writer: &MessageWriter,
    ) -> anyhow::Result<Value> {
        let times = {
            let (lock, _) = &*self.shared;
            let mut state = lock.lock().unwrap_or_else(PoisonError::into_inner);
            anyhow::ensure!(
                state.subscribers.len() < MAX_SUBSCRIBERS
                    || state.subscribers.contains_key(&client),
                "too many activity subscribers"
            );
            // Closed connections leave here or at the next send; no disconnect hook.
            state.subscribers.retain(|_, w| w.is_open());
            state.mux = Arc::downgrade(mux);
            state.subscribers.insert(client, writer.clone());
            if !state.worker {
                state.worker = true;
                let shared = Arc::clone(&self.shared);
                std::thread::Builder::new()
                    .name("cmux-activity".into())
                    .spawn(move || run_worker(shared))?;
            }
            (state.user_input_ms, state.agent_action_ms)
        };
        Ok(json!({ "activity": snapshot(mux, times) }))
    }

    fn disconnect(&self, client: u64) {
        let (lock, wake) = &*self.shared;
        let mut state = lock.lock().unwrap_or_else(PoisonError::into_inner);
        if state.subscribers.remove(&client).is_some() && state.subscribers.is_empty() {
            wake.notify_one();
        }
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
fn next_due(shared: &(Mutex<State>, Condvar)) -> Option<Due> {
    let (lock, wake) = shared;
    let mut state = lock.lock().unwrap_or_else(PoisonError::into_inner);
    loop {
        if state.subscribers.is_empty() {
            state.worker = false;
            return None;
        }
        if state.dirty {
            let wait = state
                .last_emit
                .map_or(Duration::ZERO, |last| MIN_INTERVAL.saturating_sub(last.elapsed()));
            if wait.is_zero() {
                break;
            }
            state = wake.wait_timeout(state, wait).unwrap_or_else(PoisonError::into_inner).0;
            continue;
        }
        state = wake.wait(state).unwrap_or_else(PoisonError::into_inner);
    }
    state.dirty = false;
    state.last_emit = Some(Instant::now());
    let writers = state.subscribers.iter().map(|(c, w)| (*c, w.clone())).collect();
    Some((writers, (state.user_input_ms, state.agent_action_ms), state.mux.clone()))
}

fn run_worker(shared: Arc<(Mutex<State>, Condvar)>) {
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
