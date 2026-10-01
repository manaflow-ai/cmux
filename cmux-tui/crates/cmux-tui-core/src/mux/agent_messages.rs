//! `agent.message.*`: durable messages between agents
//! (plans/feat-agent-rooms/DESIGN.md). Each send and receipt change commits
//! through the state path, so an idempotent retry returns the first result
//! and the rows survive a restart. Messages are not published as resource
//! changes: bodies stay with the sender and the recipients.

use super::state_commit::StateEffects;
use super::*;
use crate::workspace_registry::agent_message_store::{
    self as messages, AgentMessageFilter, NewAgentMessage,
};
use crate::workspace_registry::state_store::{StateChanges, StateCommit};

impl Mux {
    /// `agent.message.send`.
    pub(crate) fn agent_message_send(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        selectors: &crate::ResourceSelectors,
        message: NewAgentMessage,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint = serde_json::json!({
            "operation": "agent.message.send",
            "selectors": selectors,
            "message": message,
        });
        // Minted before the commit; a replay returns the first id instead.
        let message_id = messages::new_message_id()?;
        let session_id = self.session_public_id.as_str().to_owned();
        self.commit_state(
            mutation,
            "agent.message.send",
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, state| {
                self.resolve_in_state(state, crate::ResourceTarget::Session, selectors)?;
                let terminal_exists = |terminal: &str| -> anyhow::Result<bool> {
                    let mut lookup = selectors.clone();
                    lookup.terminal = Some(terminal.to_owned());
                    Ok(self
                        .resolve_in_state(state, crate::ResourceTarget::Terminal, &lookup)
                        .is_ok())
                };
                let value = messages::send(
                    transaction,
                    &session_id,
                    &message_id,
                    &message,
                    &terminal_exists,
                    now_ms(),
                )?;
                Ok(StateChanges::new(value, Vec::new()))
            },
        )
    }

    /// `agent.message.mark`.
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn agent_message_mark(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        selectors: &crate::ResourceSelectors,
        ids: &[String],
        recipient: &str,
        state_name: &str,
        via: Option<&str>,
        error: Option<&str>,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint = serde_json::json!({
            "operation": "agent.message.mark",
            "selectors": selectors,
            "ids": ids,
            "recipient": recipient,
            "state": state_name,
            "via": via,
            "error": error,
        });
        let session_id = self.session_public_id.as_str().to_owned();
        self.commit_state(
            mutation,
            "agent.message.mark",
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, state| {
                self.resolve_in_state(state, crate::ResourceTarget::Session, selectors)?;
                let values = messages::mark(
                    transaction,
                    &session_id,
                    ids,
                    recipient,
                    state_name,
                    via,
                    error,
                    now_ms(),
                )?;
                Ok(StateChanges::new(Value::Array(values), Vec::new()))
            },
        )
    }

    /// `agent.message.list`, newest first.
    pub(crate) fn agent_message_list(
        &self,
        selectors: &crate::ResourceSelectors,
        filter: &AgentMessageFilter,
        limit: usize,
    ) -> Result<Vec<Value>, ResourceError> {
        self.resolve_resource_path(crate::ResourceTarget::Session, selectors)?;
        let session_id = self.session_public_id.as_str().to_owned();
        self.read_registry_state(|connection| {
            messages::list(connection, &session_id, filter, limit)
        })
        .map_err(crate::resource_api::operation_failed)
    }
}
