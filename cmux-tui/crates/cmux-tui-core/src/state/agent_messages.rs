//! `agent.message.*`: durable messages between agents
//! (plans/feat-agent-rooms/DESIGN.md). Each send and receipt change commits
//! through the state path, so an idempotent retry returns the first result
//! and the rows survive a restart. Messages are not published as resource
//! changes: bodies stay with the sender and the recipients.
//!
//! The sender of a send is the request's verified actor
//! (agent_message_policy.rs). The workspace of an acpmux session comes from
//! acpmux before the commit takes its locks; a terminal's comes from the
//! session state inside the commit.

use std::collections::HashMap;

use crate::mux::*;
use crate::state::agent_message_policy::{self as policy, CrossWorkspace};
use crate::state::agent_message_store::{
    self as messages, AgentMessageFilter, NewAgentMessage, SendContext,
};
use crate::state::agent_message_unsend::{self as unsend, WithdrawError, Withdrawn};
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::store::{StateChanges, StateCommit};

impl Mux {
    /// `agent.message.send`.
    pub(crate) fn agent_message_send(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        selectors: &crate::ResourceSelectors,
        message: NewAgentMessage,
    ) -> anyhow::Result<StateCommit> {
        let agent = policy::sender_address(&mutation.actor);
        let fingerprint = serde_json::json!({
            "operation": "agent.message.send",
            "selectors": selectors,
            "message": message,
        });
        // Minted before the commit; a replay returns the first id instead.
        let message_id = messages::new_message_id()?;
        let session_id = self.session_public_id.as_str().to_owned();
        // Refuse what the fields and the limits already refuse before
        // waiting on acpmux; the commit checks every rule again.
        let now = policy::now_ms();
        self.read_registry_state(|connection| {
            messages::precheck(connection, &mutation.id, &message, agent.as_deref(), now)
        })?;
        let acp_keys = self.acp_workspace_keys(agent.as_deref(), &message);
        let rule = CrossWorkspace::configured();
        self.commit_state(
            mutation,
            "agent.message.send",
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, state| {
                self.resolve_in_state(state, crate::ResourceTarget::Session, selectors)?;
                let terminal_slots = |terminal: &str| {
                    let mut lookup = selectors.clone();
                    lookup.terminal = Some(terminal.to_owned());
                    self.resolve_in_state(state, crate::ResourceTarget::Terminal, &lookup)
                };
                let terminal_exists = |terminal: &str| -> anyhow::Result<bool> {
                    Ok(terminal_slots(terminal).is_ok())
                };
                let workspace_of = |address: &str| -> Option<String> {
                    if address.starts_with("term_") {
                        let slots = terminal_slots(address).ok()?;
                        return slots.path.workspace.map(|id| id.as_str().to_owned());
                    }
                    let key = acp_keys.get(address.strip_prefix("acp:")?)?.as_ref()?;
                    state
                        .workspaces
                        .iter()
                        .find(|workspace| policy::workspace_key(&workspace.key) == *key)
                        .map(|workspace| workspace.public_id.as_str().to_owned())
                };
                let context = SendContext {
                    agent: agent.as_deref(),
                    terminal_exists: &terminal_exists,
                    workspace_of: &workspace_of,
                    rule,
                };
                let value = messages::send(
                    transaction,
                    &session_id,
                    &message_id,
                    &message,
                    &context,
                    policy::now_ms(),
                )?;
                Ok(StateChanges::new(value, Vec::new()))
            },
        )
        .inspect(|_| self.wake_agent_message_pump())
    }

    /// The workspace keys of the acpmux sessions a send involves: the
    /// sender, the recipients, and the parent's sender of a reply without
    /// recipients. Read before the commit: it waits on acpmux.
    fn acp_workspace_keys(
        &self,
        agent: Option<&str>,
        message: &NewAgentMessage,
    ) -> HashMap<String, Option<String>> {
        let mut addresses: Vec<String> = agent.into_iter().map(str::to_owned).collect();
        addresses.extend(message.recipients.iter().cloned());
        if message.recipients.is_empty()
            && let Some(parent) = &message.in_reply_to
            && let Ok(Some(sender)) =
                self.read_registry_state(|connection| messages::sender_of(connection, parent))
        {
            addresses.push(sender);
        }
        let mut sessions: Vec<String> = Vec::new();
        for address in &addresses {
            if let Some(session) = address.strip_prefix("acp:")
                && !sessions.iter().any(|known| known == session)
            {
                sessions.push(session.to_owned());
            }
        }
        self.acp_session_workspace_keys(&sessions)
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
                    policy::now_ms(),
                )?;
                Ok(StateChanges::new(Value::Array(values), Vec::new()))
            },
        )
    }

    /// `agent.message.release`: the person, in the verified cmux app,
    /// approves or declines one held delivery. Any local connection may be
    /// an agent that left out its launch credential, so every other actor,
    /// the plain local user included, is refused (as pairing approval is).
    pub(crate) fn agent_message_release(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        selectors: &crate::ResourceSelectors,
        message_id: &str,
        recipient: &str,
        decision: &str,
    ) -> anyhow::Result<StateCommit> {
        if !matches!(mutation.actor, crate::workspace_registry::Actor::Frontend { .. }) {
            return Err(policy::refused_by(
                "agent.message.release",
                "release_needs_app",
                "only the person, in the cmux app, approves or declines a held message",
                serde_json::json!({}),
            ));
        }
        let fingerprint = serde_json::json!({
            "operation": "agent.message.release",
            "selectors": selectors,
            "message_id": message_id,
            "recipient": recipient,
            "decision": decision,
        });
        let session_id = self.session_public_id.as_str().to_owned();
        self.commit_state(
            mutation,
            "agent.message.release",
            &fingerprint,
            expected_revision,
            StateEffects::EVENTS_ONLY,
            |transaction, state| {
                self.resolve_in_state(state, crate::ResourceTarget::Session, selectors)?;
                let value = crate::state::agent_message_release::release(
                    transaction,
                    &session_id,
                    message_id,
                    recipient,
                    decision,
                    policy::now_ms(),
                )?;
                Ok(StateChanges::new(value, Vec::new()))
            },
        )
        .inspect(|_| self.wake_agent_message_pump())
    }

    /// `agent.message.unsend` (agent_message_unsend.rs): the verified sender,
    /// or the person in the verified cmux app, takes a message back. Any
    /// local connection may be an agent that left out its launch credential,
    /// so the plain local user is refused (as `agent.message.release`
    /// refuses it). A retry replays, and a reused key or a
    /// stale revision is refused, before acpmux is asked anything; then
    /// acpmux decides each acpmux recipient's outcome, and every answer
    /// commits (a refusal is that recipient's `failed` outcome) whatever
    /// else committed while acpmux answered: acpmux already acted on it.
    /// The pump claims no hand-over and records no outcome meanwhile; one
    /// already out counts as tried, so acpmux decides it.
    pub(crate) fn agent_message_unsend(
        &self,
        mutation: &WorkspaceMutation,
        expected_revision: Option<u64>,
        selectors: &crate::ResourceSelectors,
        message_id: &str,
        recipient: Option<&str>,
    ) -> anyhow::Result<StateCommit> {
        const OPERATION: &str = "agent.message.unsend";
        let fingerprint = serde_json::json!({
            "operation": OPERATION,
            "selectors": selectors,
            "message_id": message_id,
            "recipient": recipient,
        });
        let session_id = self.session_public_id.as_str().to_owned();
        let _delivering = self.agent_message_delivery_lock();
        if let Some(replayed) =
            self.state_commit_replay(mutation, OPERATION, &fingerprint, expected_revision)?
        {
            return Ok(replayed);
        }
        let (sender, targets) = self
            .read_registry_state(|connection| unsend::targets(connection, message_id, recipient))?;
        let app = matches!(mutation.actor, crate::workspace_registry::Actor::Frontend { .. });
        match policy::sender_address(&mutation.actor) {
            _ if app => {}
            Some(agent) if agent == sender => {}
            Some(agent) => {
                return Err(policy::refused_by(
                    OPERATION,
                    "unsend_not_sender",
                    format!(
                        "{agent} did not send message {message_id}; only its sender or the person, in the cmux app, takes it back"
                    ),
                    serde_json::json!({}),
                ));
            }
            None => {
                return Err(policy::refused_by(
                    OPERATION,
                    "unsend_needs_app",
                    format!(
                        "an unverified caller cannot take back message {message_id}; its sender's own session, or the cmux app, can"
                    ),
                    serde_json::json!({}),
                ));
            }
        }
        let (mut answers, mut failures) = (HashMap::new(), HashMap::new());
        for target in targets.iter().filter(|target| target.asks_acpmux()) {
            let session = target.recipient.trim_start_matches("acp:");
            let to = target.recipient.clone();
            // A hand-over went out (or one whose attempt could not be noted).
            let tried = !target.never_tried()
                || self.agent_message_attempt_unnoted(message_id, &target.recipient);
            match self.acp_withdraw_message(session, message_id) {
                // acpmux holds no such prompt yet, but the hand-over may
                // still reach it and run: not unsent, try again. A session
                // acpmux no longer knows (`NoSession`: deleted, and no peer
                // runs it) takes nothing late.
                Ok(Withdrawn::NotFound) if tried && target.state == "queued" => {
                    failures.insert(to, unsend::in_flight(&target.recipient));
                }
                Ok(answer) => {
                    answers.insert(to, answer);
                }
                // Not running, and no hand-over was ever tried: still ours.
                Err(WithdrawError::Unavailable) if !tried => {}
                Err(WithdrawError::Unavailable) => {
                    failures.insert(to, unsend::unavailable(&target.recipient));
                }
                Err(WithdrawError::Refused(reason)) => {
                    failures.insert(to, unsend::refused(&target.recipient, &reason));
                }
            }
        }
        // The revision was checked above, before acpmux acted; the replay
        // and key checks run again inside the commit.
        self.commit_state(
            mutation,
            OPERATION,
            &fingerprint,
            None,
            StateEffects::EVENTS_ONLY,
            |transaction, state| {
                self.resolve_in_state(state, crate::ResourceTarget::Session, selectors)?;
                let value = unsend::unsend(
                    transaction,
                    &session_id,
                    message_id,
                    recipient,
                    &answers,
                    &failures,
                    policy::now_ms(),
                )?;
                Ok(StateChanges::new(value, Vec::new()))
            },
        )
    }

    /// `agent.message.list`, newest first. A held delivery whose wait is
    /// over reads as declined (`expired`) even before a mutation stores it.
    pub(crate) fn agent_message_list(
        &self,
        selectors: &crate::ResourceSelectors,
        filter: &AgentMessageFilter,
        limit: usize,
    ) -> Result<Vec<Value>, ResourceError> {
        self.resolve_resource_path(crate::ResourceTarget::Session, selectors)?;
        let session_id = self.session_public_id.as_str().to_owned();
        let now = policy::now_ms();
        self.read_registry_state(|connection| {
            messages::list(connection, &session_id, filter, limit, now)
        })
        .map_err(crate::resource_api::operation_failed)
    }
}

/// No acpmux off unix: no session's workspace is known, so a message to or
/// from one is held.
#[cfg(not(unix))]
impl Mux {
    fn acp_session_workspace_keys(&self, sessions: &[String]) -> HashMap<String, Option<String>> {
        sessions.iter().map(|session| (session.clone(), None)).collect()
    }
}
