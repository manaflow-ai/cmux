//! The hub's supervised work (`crate::supervised`): every task on the hub's shared state
//! (sessions, turns, queues, peers, the pool) runs under the process's supervisor as
//! `Fatal`, since a panic there may leave that state half-changed. They are `Skip` on
//! shutdown: the daemon stops the supervisor after its own shutdown sequence
//! (`crate::daemon::run`), and none of them is a write that must land.

use std::future::Future;
use std::sync::Arc;

use super::{Hub, Session};
use crate::agent::Inbound;
use crate::config::Config;
use crate::mailbox::Mailbox;
use crate::store::Store;
use crate::supervised::{Fatal, ShutdownBehavior, Supervisor};

impl Hub {
    /// A hub whose tasks run under `supervisor` (tests pass a recording one).
    pub fn new_supervised(
        config: Config,
        store: Box<dyn Store>,
        mailbox: Mailbox,
        supervisor: Supervisor,
    ) -> Arc<Self> {
        Self::build(config, store, mailbox, false, supervisor)
    }

    /// Starts `work`, a task on the hub's shared state, under the process's supervisor
    /// with `policy` and `shutdown` (`crate::supervised::task`).
    pub(crate) fn supervise(
        &self,
        name: &str,
        policy: Fatal,
        shutdown: ShutdownBehavior,
        work: impl Future<Output = ()> + Send + 'static,
    ) {
        crate::supervised::task(&self.supervisor, name, policy, shutdown, work);
    }

    /// Starts `session`'s inbound loop: its agent's requests and notifications, in order.
    pub(super) fn start_inbound_loop(
        self: &Arc<Self>,
        session: &Arc<Session>,
        rx: tokio::sync::mpsc::Receiver<Inbound>,
    ) {
        let (hub, session) = (self.clone(), session.clone());
        self.supervise("hub.inbound", Fatal, ShutdownBehavior::Skip, async move {
            hub.inbound_loop(session, rx).await
        });
    }

    /// The process's supervisor.
    pub fn supervisor(&self) -> &Supervisor {
        &self.supervisor
    }
}

#[cfg(test)]
#[path = "supervision_tests.rs"]
mod tests;
