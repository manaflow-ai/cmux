//! What a connection is, decided from its first requests in order, before
//! each request runs (`serve_connection_from`): the person (`hub/person.rs`),
//! the acpmux session it runs in ((a)) and the agent tool server it is
//! (`agent_mcp.rs`).

use super::{Conn, Origin, agent_mcp};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::atomic::Ordering;

impl Conn {
    /// The person binding (`hub/person.rs`), in order before the request
    /// runs. A `personKey` in any request is stripped and never read. A
    /// local connection whose FIRST request is `initialize` is challenged;
    /// its SECOND request, `_acpmux/person_prove`, makes it the person when
    /// the proof matches its own nonce and id. Nothing else ever does.
    ///
    /// A first unix `initialize` that also names an agent tool server makes
    /// the connection that server for its proven caller (`agent_mcp.rs`);
    /// `Err` is that request's refusal when its token proves no session.
    pub(super) fn bind_person(
        &self,
        hub: &Hub,
        m: &str,
        params: &mut Option<Value>,
    ) -> Result<(), RpcError> {
        let _ = params.as_mut().and_then(crate::hub::person::take_key);
        // Stripped from every request; read from a first unix `initialize` only (person.rs (a)).
        let caller = params.as_mut().and_then(crate::hub::person::take_caller);
        let server = params.as_mut().and_then(agent_mcp::take_server);
        let n = self.requests.fetch_add(1, Ordering::SeqCst) + 1;
        if n == 1 && m == method::INITIALIZE && self.challengeable() {
            self.challenged.store(true, Ordering::SeqCst);
        }
        let first_local = n == 1 && m == method::INITIALIZE && self.origin == Origin::Local;
        if let Some((id, token)) = caller.filter(|_| first_local) {
            let proven = hub.proven_caller((id.clone(), token)).is_some();
            let _ = if proven { &self.caller } else { &self.unproven_caller }.set(id);
        }
        if let Some(server) = server.filter(|_| first_local) {
            let _ = self.agent_tools.set(agent_mcp::attach(self, &server)?);
        }
        if n == 2 && m == method::MUX_PERSON_PROVE && self.challenged.load(Ordering::SeqCst) {
            let proof = params.as_ref().and_then(|p| p.get("proof")).and_then(Value::as_str);
            let transport = match self.origin {
                Origin::LocalApp => crate::hub::person::TRANSPORT_APP,
                _ => crate::hub::person::TRANSPORT_UNIX,
            };
            if proof.is_some_and(|p| hub.person.proves(transport, &self.nonce, &self.id, p)) {
                self.person.store(true, Ordering::SeqCst);
            }
        }
        Ok(())
    }

    /// The agent tool server this connection is, once its first request attached one.
    pub(super) fn agent_tools(&self) -> Option<crate::subsession_mcp::DaemonTools> {
        self.agent_tools.get().copied()
    }
}
