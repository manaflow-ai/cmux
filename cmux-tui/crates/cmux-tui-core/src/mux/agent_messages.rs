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
    /// Apply `agents.messages.enabled`. Turning messages off fails every
    /// queued receipt, so no sender waits on a delivery that will not come.
    pub fn configure_agent_messages(&self, enabled: bool) {
        let was_enabled = self.agent_messages_enabled.swap(enabled, Ordering::SeqCst);
        // Nothing is queued while messages stay off.
        if enabled || !was_enabled {
            return;
        }
        // A start with messages off has usually nothing queued: skip the
        // revision bump.
        let queued = self.read_registry_state(|connection| {
            Ok(connection.query_row(
                "SELECT EXISTS(SELECT 1 FROM agent_message_deliveries WHERE state = 'queued')",
                [],
                |row| row.get::<_, bool>(0),
            )?)
        });
        if matches!(queued, Ok(false)) {
            return;
        }
        let commit = self.commit_state(
            &WorkspaceMutation::local("cmux-tui"),
            "agent.message.turn_off",
            &serde_json::json!({"operation": "agent.message.turn_off"}),
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, _| {
                let failed =
                    messages::fail_queued(transaction, None, messages::TURNED_OFF, now_ms())?;
                Ok(StateChanges::new(serde_json::json!(failed), Vec::new()))
            },
        );
        if let Err(error) = commit {
            eprintln!("cmux-tui: could not fail queued agent messages: {error:#}");
        }
    }

    fn ensure_agent_messages_enabled(&self) -> anyhow::Result<()> {
        if self.agent_messages_enabled.load(Ordering::SeqCst) {
            Ok(())
        } else {
            Err(anyhow::anyhow!("bad request: {}", messages::TURNED_OFF))
        }
    }

    /// `agent.message.receiving.set`.
    pub(crate) fn agent_message_receiving_set(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        selectors: &crate::ResourceSelectors,
        recipient: &str,
        enabled: bool,
    ) -> anyhow::Result<StateCommit> {
        let fingerprint = serde_json::json!({
            "operation": "agent.message.receiving.set",
            "selectors": selectors,
            "recipient": recipient,
            "enabled": enabled,
        });
        self.commit_state(
            mutation,
            "agent.message.receiving.set",
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
                let value = messages::set_receiving(
                    transaction,
                    recipient,
                    enabled,
                    &terminal_exists,
                    now_ms(),
                )?;
                Ok(StateChanges::new(value, Vec::new()))
            },
        )
    }

    /// `agent.message.receiving.get`: the global switch and the recipients
    /// that turned messages off.
    pub(crate) fn agent_message_receiving_get(
        &self,
        selectors: &crate::ResourceSelectors,
    ) -> Result<Value, ResourceError> {
        self.resolve_resource_path(crate::ResourceTarget::Session, selectors)?;
        let disabled = self
            .read_registry_state(messages::disabled_recipients)
            .map_err(crate::resource_api::operation_failed)?;
        Ok(serde_json::json!({
            "enabled": self.agent_messages_enabled.load(Ordering::SeqCst),
            "disabled_recipients": disabled,
        }))
    }

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
                // Checked under the registry lock, which turning messages off
                // also takes, so no message is queued after its receipts failed.
                self.ensure_agent_messages_enabled()?;
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
                if state_name == "delivered" {
                    self.ensure_agent_messages_enabled()?;
                }
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
