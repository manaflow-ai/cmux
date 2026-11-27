//! Per-client watch leases and their cancellation/acknowledgement fence.
use super::*;
use crate::panic_free::JsonFields;
use crate::server::{Response, send_response};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Mutex, Weak};

const MAX_WATCHES: usize = 8;

#[derive(Default)]
pub(in crate::server) struct Watches(Mutex<HashMap<u64, Arc<Watch>>>);

impl Watches {
    /// Emits absence proof atomically with observing no lease for this exact control client.
    pub(super) fn refuse(
        &self,
        client: u64,
        owner: &MachinePublicId,
        writer: &MessageWriter,
        id: Option<Value>,
        error: Failure,
    ) -> bool {
        let live = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if live.contains_key(&client) {
            return agent_inventory::reply(writer, id, Err(error));
        }
        send_response(
            writer,
            Response {
                id,
                ok: false,
                data: Some(json!({"machine":owner,"admission":"not_admitted"})),
                error: Some(error.code().into()),
                error_code: Some(error.code().into()),
                error_delivery: None,
            },
        )
    }

    pub(super) fn get(&self, client: u64) -> Option<Arc<Watch>> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).get(&client).cloned()
    }
    pub(super) fn insert(&self, watch: Arc<Watch>) -> Result<(), Failure> {
        let mut live = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if live.len() >= MAX_WATCHES || live.contains_key(&watch.client) {
            return Err(Failure::Busy);
        }
        live.insert(watch.client, watch);
        Ok(())
    }
    fn remove(&self, watch: &Watch) {
        let mut live = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if live.get(&watch.client).is_some_and(|v| v.id == watch.id) {
            live.remove(&watch.client);
        }
    }
    pub(in crate::server) fn disconnect(&self, client: u64) {
        self.disconnect_matching(client, None);
    }
    /// The expected ID is a condition on this client's lease, never a selector.
    pub(super) fn disconnect_matching(&self, client: u64, expected: Option<&str>) {
        let gone = {
            let mut live = self.0.lock().unwrap_or_else(|e| e.into_inner());
            if expected.is_some_and(|id| live.get(&client).is_none_or(|watch| watch.id != id)) {
                return;
            }
            live.remove(&client)
        };
        if let Some(watch) = gone {
            watch.stop(Failure::Unavailable, false);
        }
    }
    pub(in crate::server) fn take_all(&self) -> Retired {
        Retired(self.0.lock().unwrap_or_else(|e| e.into_inner()).drain().map(|(_, v)| v).collect())
    }
}

impl Drop for Watches {
    fn drop(&mut self) {
        self.take_all().close();
    }
}

/// Detached under the socket write guard, closed after releasing it.
pub(in crate::server) struct Retired(Vec<Arc<Watch>>);
impl Retired {
    pub(in crate::server) fn close(self) {
        for watch in self.0 {
            watch.stop(Failure::Unavailable, true);
        }
    }
}

#[derive(Clone, Copy, PartialEq)]
enum Phase {
    Pending,
    Active,
    Closed,
}
struct State {
    phase: Phase,
    negotiated: bool,
    revision: Option<u64>,
    link: Option<Arc<AcpmuxLink>>,
    failure: Failure,
}

pub(super) struct Watch {
    id: String,
    client: u64,
    owner: MachinePublicId,
    mux: Weak<Mux>,
    pub(super) socket: PathBuf,
    generation: u64,
    pub(super) writer: MessageWriter,
    state: Mutex<State>,
}

impl Watch {
    pub(super) fn new(
        mux: &Arc<Mux>,
        client: u64,
        socket: PathBuf,
        generation: u64,
        writer: MessageWriter,
    ) -> Result<Arc<Self>, Failure> {
        let mut bytes = [0u8; 16];
        getrandom::fill(&mut bytes).map_err(|_| Failure::Unavailable)?;
        let nonce = bytes.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        Ok(Arc::new(Self {
            id: format!("inventory_watch_{nonce}"),
            client,
            owner: mux.machine_public_id.clone(),
            mux: Arc::downgrade(mux),
            socket,
            generation,
            writer,
            state: Mutex::new(State {
                phase: Phase::Pending,
                negotiated: false,
                revision: None,
                link: None,
                failure: Failure::Unavailable,
            }),
        }))
    }
    pub(super) fn current_socket(&self) -> bool {
        self.mux.upgrade().is_some_and(|mux| {
            mux.control_clients
                .agent_sessions
                .with_inventory_socket(&self.socket, self.generation, || ())
                .is_some()
        })
    }
    pub(super) fn respond(&self, id: Option<Value>) -> Result<bool, Failure> {
        let mux = self.mux.upgrade().ok_or(Failure::Unavailable)?;
        mux.control_clients
            .agent_sessions
            .with_inventory_socket(&self.socket, self.generation, || {
                let state = self.state.lock().unwrap_or_else(|e| e.into_inner());
                match state.phase {
                    Phase::Active => Ok(agent_inventory::reply(
                        &self.writer,
                        id,
                        Ok(self.value(state.revision.ok_or(Failure::InvalidResponse)?)),
                    )),
                    Phase::Pending => Err(Failure::Busy),
                    Phase::Closed => Err(state.failure),
                }
            })
            .ok_or(Failure::Unavailable)?
    }
    fn value(&self, revision: u64) -> Value {
        json!({"machine":self.owner,"watch_id":self.id,"revision":revision})
    }
    pub(super) fn set_link(&self, link: Arc<AcpmuxLink>) -> Result<(), Failure> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.phase == Phase::Closed {
            link.close();
            return Err(state.failure);
        }
        state.link = Some(link);
        Ok(())
    }
    pub(super) fn negotiated(&self) -> Result<(), Failure> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if state.phase == Phase::Closed {
            return Err(state.failure);
        }
        state.negotiated = true;
        Ok(())
    }
    pub(super) fn activate(&self, id: Option<Value>, initial: &Value) -> Result<bool, Failure> {
        let revision = revision(initial)?;
        let mux = self.mux.upgrade().ok_or(Failure::Unavailable)?;
        mux.control_clients
            .agent_sessions
            .with_inventory_socket(&self.socket, self.generation, || {
                let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
                if state.phase == Phase::Closed {
                    return Err(state.failure);
                }
                let revision = state.revision.map_or(revision, |old| old.max(revision));
                state.revision = Some(revision);
                // The same lock serializes ACKs, notifications and disable; the
                // socket guard also orders this ACK before route replacement.
                state.phase = Phase::Active;
                Ok(agent_inventory::reply(&self.writer, id, Ok(self.value(revision))))
            })
            .ok_or(Failure::Unavailable)?
    }
    pub(super) fn inbound(&self, inbound: Inbound) {
        match inbound {
            Inbound::Closed(_) => self.stop(Failure::Unavailable, true),
            Inbound::Notification(method, value) if method == "_acpmux/harness_inventory" => {
                let result = self
                    .mux
                    .upgrade()
                    .and_then(|mux| {
                        mux.control_clients.agent_sessions.with_inventory_socket(
                            &self.socket,
                            self.generation,
                            || self.observe(&value),
                        )
                    })
                    .unwrap_or(Err(Failure::Unavailable));
                if let Err(error) = result {
                    self.stop(error, true);
                }
            }
            _ => {}
        }
    }

    fn observe(&self, value: &Value) -> Result<(), Failure> {
        let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if !state.negotiated || state.phase == Phase::Closed {
            return Ok(());
        }
        let revision = revision(value)?;
        if state.revision.is_some_and(|old| revision <= old) {
            return Ok(());
        }
        state.revision = Some(revision);
        if state.phase == Phase::Active {
            let mut event = self.value(revision);
            event.insert("event", json!("agent-inventory-changed"));
            self.writer.send_control(&event).map_err(|_| Failure::Unavailable)?;
        }
        Ok(())
    }
    pub(super) fn stop(&self, failure: Failure, notify: bool) {
        let link = {
            let mut state = self.state.lock().unwrap_or_else(|e| e.into_inner());
            if state.phase == Phase::Closed {
                return;
            }
            let active = state.phase == Phase::Active;
            state.phase = Phase::Closed;
            state.failure = failure;
            if active && notify {
                let _ = self.writer.send_control(&json!({"event":"agent-inventory-watch-ended",
                    "machine":self.owner,"watch_id":self.id,"reason":failure.code()}));
            }
            state.link.take()
        };
        if let Some(link) = link {
            link.close();
        }
        if let Some(mux) = self.mux.upgrade() {
            mux.control_clients.agent_sessions.inventory_watches.remove(self);
        }
    }
}

impl Drop for Watch {
    fn drop(&mut self) {
        if let Some(link) = self.state.get_mut().unwrap_or_else(|e| e.into_inner()).link.take() {
            link.close();
        }
    }
}
