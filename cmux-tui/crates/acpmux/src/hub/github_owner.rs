//! The lane's half of the GitHub broker (`github_broker.rs`): which connected Macs lend this
//! machine their GitHub login, and the session row each decision leaves.
//!
//! A Mac says so in its `initialize` (`_meta.acpmux.githubBroker`), and only over a link that
//! proved this machine's peer token (`peer_auth.rs`: read over ssh); a Web, app or paired-device
//! connection saying it counts for nothing (`server/requests.rs`). The newest such link still
//! open is the one asked.

use super::{Hub, Session};
use crate::server::Conn;
use serde_json::Value;
use std::sync::{Arc, Mutex, Weak};

#[derive(Default)]
pub(crate) struct Owners(Mutex<Vec<Weak<Conn>>>);

impl Hub {
    /// `conn` lends this machine its GitHub login (module docs).
    pub(crate) fn add_github_owner(&self, conn: &Arc<Conn>) {
        let mut owners = self.github_owners.0.lock().unwrap_or_else(|e| e.into_inner());
        owners.retain(|o| o.upgrade().is_some_and(|c| c.is_open()));
        owners.push(Arc::downgrade(conn));
    }

    /// The newest open link that lends its GitHub login, if any.
    pub(crate) fn github_owner_link(&self) -> Option<Arc<Conn>> {
        let owners = self.github_owners.0.lock().unwrap_or_else(|e| e.into_inner());
        owners.iter().rev().filter_map(Weak::upgrade).find(|c| c.is_open())
    }

    /// One redacted broker decision, in the session's own event stream, so the app shows it
    /// beside the work that caused it.
    pub(crate) fn append_github_audit(&self, session: &Session, payload: Value) {
        self.append(session, "mux", "github_broker_action", payload);
    }
}
