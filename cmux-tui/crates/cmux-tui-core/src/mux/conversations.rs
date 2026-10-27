//! Hosting of the local conversation owner (plans/cmux-next/home.md section
//! 1, `local-conversations-v1`). The store is its own owner with its own
//! file; the mux only opens it next to the workspace registry and publishes
//! its events after each commit.

use super::*;
use crate::conversation_store::ConversationStore;
use crate::remote_relay_state::{RelayLock, RelayStateError, lock_checked};

/// The binding of a connection whose agent token was replaced.
pub(crate) const REVOKED_BINDING_PREFIX: &str = "revoked:";

impl Mux {
    /// `conversation.draft`'s replay and rate gate (memory only).
    pub(crate) fn admit_conversation_draft(
        &self,
        draft: crate::conversation_drafts::DraftAdmission<'_>,
        now: Instant,
    ) -> Result<bool, crate::conversation_drafts::DraftRefusal> {
        let mut gate = self.conversations.drafts.lock().unwrap_or_else(PoisonError::into_inner);
        gate.admit(draft, now)
    }

    /// Run `operation` on the conversation store, opening
    /// `conversations.sqlite3` in the session state directory on first use
    /// (in memory for an in-memory session).
    #[track_caller]
    pub(crate) fn with_conversations<T>(
        &self,
        operation: impl FnOnce(&mut ConversationStore) -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        let mut store = self.conversations.lock_store_for_sqlite().unwrap();
        if store.is_none() {
            let directory = self.session_state_directory();
            *store = Some(ConversationStore::open(directory.as_deref())?);
        }
        operation(store.as_mut().expect("conversation store opened above"))
    }

    /// Commit one conversation write, then publish the event `publish`
    /// derives from its result, after the store lock is released. Writes
    /// and their events are serialized, so subscribers see each
    /// conversation's `rev` in commit order.
    #[track_caller]
    pub(crate) fn conversation_write<T>(
        &self,
        write: impl FnOnce(&mut ConversationStore) -> anyhow::Result<T>,
        publish: impl FnOnce(&T) -> Option<MuxEvent>,
    ) -> anyhow::Result<T> {
        self.conversation_write_many(write, |value| publish(value).into_iter().collect())
    }

    /// [`Self::conversation_write`] for a write that commits several changes
    /// in one transaction: every event is published after the commit, in
    /// order.
    #[track_caller]
    pub(crate) fn conversation_write_many<T>(
        &self,
        write: impl FnOnce(&mut ConversationStore) -> anyhow::Result<T>,
        publish: impl FnOnce(&T) -> Vec<MuxEvent>,
    ) -> anyhow::Result<T> {
        let _order = self.conversations.publish.lock().unwrap();
        let value = self.with_conversations(write)?;
        for event in publish(&value) {
            // A participant's posted message ends its typing (every client
            // drops it on the message; the owner's state follows, so the Home
            // rows never show a Chief working after it answered).
            if let MuxEvent::Conversation(change) = &event
                && let crate::conversation_store::ConversationEvent::Changed {
                    conversation,
                    change,
                    ..
                } = change.as_ref()
                && change["kind"] == "message"
                && let Some(author) = change["message"]["author"].as_str()
            {
                self.set_conversation_typing(conversation, author, false);
            }
            self.emit(event);
        }
        Ok(value)
    }

    /// Publishes one live frame of `actor`'s running run (`chief-live-v1`):
    /// checked against the run, kept in the live buffer and sent to the
    /// connections that asked, with the run's agent. A step that starts again
    /// (`seq` 0) sends the conversation's `run.live` instead. Under the publish
    /// lock, so no frame of a run goes out after the run's end.
    pub(crate) fn conversation_live_publish(
        &self,
        conversation: &str,
        actor: &str,
        frame: &crate::conversation_live::LiveFrame,
    ) -> anyhow::Result<()> {
        let _order = self.conversations.publish.lock().unwrap_or_else(PoisonError::into_inner);
        self.with_conversations(|store| store.live_run(conversation, actor, frame.run()))?;
        let applied = self
            .conversations
            .live
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .apply(conversation, actor, frame, Instant::now())?;
        let wire = match applied {
            crate::conversation_live::Applied::Frame => frame.wire(actor),
            crate::conversation_live::Applied::Reset => self.live_snapshot(conversation)?,
        };
        self.emit(MuxEvent::Conversation(Arc::new(
            crate::conversation_store::ConversationEvent::Live {
                conversation: conversation.to_owned(),
                frame: wire,
            },
        )));
        Ok(())
    }

    /// The `run.live` snapshot of `conversation`: the text so far of its
    /// running runs. Under the publish lock, so a run that starts meanwhile
    /// keeps its text.
    pub(crate) fn conversation_live(&self, conversation: &str) -> anyhow::Result<Value> {
        let _order = self.conversations.publish.lock().unwrap_or_else(PoisonError::into_inner);
        self.live_snapshot(conversation)
    }

    /// The snapshot; the caller holds the publish lock.
    fn live_snapshot(&self, conversation: &str) -> anyhow::Result<Value> {
        let runs = self
            .conversations
            .live
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .runs_of(conversation);
        let running = self.with_conversations(|store| store.running_of(conversation, &runs))?;
        Ok(self.conversations.live.lock().unwrap_or_else(PoisonError::into_inner).snapshot(
            conversation,
            &runs,
            &running,
        ))
    }

    /// A run's rows were written: an ended run's live text goes, and so does
    /// each talk or thought step's whose stream ended (`steps`).
    pub(crate) fn conversation_live_rows(
        &self,
        conversation: &str,
        run: &str,
        ended: bool,
        steps: &[String],
    ) {
        let mut live = self.conversations.live.lock().unwrap_or_else(PoisonError::into_inner);
        if ended {
            live.end(conversation, run);
        } else {
            live.rows_written(conversation, run, steps);
        }
    }

    /// The Chief registry (chief_registry.rs).
    pub(crate) fn chiefs(&self) -> &crate::chief_registry::ChiefHost {
        &self.chiefs
    }

    /// The remote-relay state (peers, pairing records, revocation limits).
    pub(crate) fn remote_relay(&self) -> &crate::remote_relay_state::RemoteRelayState {
        &self.conversations.remote
    }

    /// The agent or person participant `client` bound with a token, if any. The
    /// principal itself (`conversation_principal`) lives with the relay
    /// policy (server/remote_relay), which fails closed for remote
    /// connections.
    /// A poisoned bindings lock is an error: the caller cannot tell an
    /// agent connection from the local user, so it gives no principal.
    pub(crate) fn bound_conversation_participant(
        &self,
        client: u64,
    ) -> Result<Option<String>, RelayStateError> {
        Ok(lock_checked(&self.conversations.bindings, RelayLock::Bindings)?.get(&client).cloned())
    }

    /// Binds `client` to `participant` for the rest of the connection. A
    /// poisoned bindings lock binds nothing.
    pub(crate) fn bind_conversation_principal(
        &self,
        client: u64,
        participant: String,
    ) -> Result<(), RelayStateError> {
        lock_checked(&self.conversations.bindings, RelayLock::Bindings)?
            .insert(client, participant);
        Ok(())
    }

    /// Binds `client` to `participant` when `check` (the credential check)
    /// passes, holding the bindings lock across both, so a credential revoked
    /// by [`Mux::claim_unbound_participant`] never binds after it. Lock order:
    /// bindings, then the conversation store.
    pub(crate) fn bind_conversation_principal_if(
        &self,
        client: u64,
        participant: String,
        check: impl FnOnce() -> anyhow::Result<bool>,
    ) -> anyhow::Result<bool> {
        let mut bindings = lock_checked(&self.conversations.bindings, RelayLock::Bindings)?;
        if !check()? {
            return Ok(false);
        }
        bindings.insert(client, participant);
        Ok(true)
    }

    /// For `chief.profile.adopt`: when no connection is bound to
    /// `participant`, revokes every credential issued for it and answers
    /// true; a bound participant answers false and nothing changes. Under the
    /// bindings lock, so no bind lands between the check and the revoke.
    pub(crate) fn claim_unbound_participant(&self, participant: &str) -> anyhow::Result<bool> {
        let bindings = lock_checked(&self.conversations.bindings, RelayLock::Bindings)?;
        if bindings.values().any(|bound| bound == participant) {
            return Ok(false);
        }
        self.with_conversations(|store| store.revoke_agent_token(participant))?;
        drop(bindings);
        Ok(true)
    }

    /// The bindings lock (tests poison it).
    #[cfg(test)]
    pub(crate) fn conversation_bindings(
        &self,
    ) -> &std::sync::Mutex<std::collections::BTreeMap<u64, String>> {
        &self.conversations.bindings
    }

    /// Records that `participant` types (or stopped) in `conversation`.
    pub(crate) fn set_conversation_typing(&self, conversation: &str, participant: &str, on: bool) {
        let mut typing = self.conversations.typing.lock().unwrap_or_else(PoisonError::into_inner);
        if on {
            typing.entry(conversation.to_owned()).or_default().insert(participant.to_owned());
        } else if let Some(set) = typing.get_mut(conversation) {
            set.remove(participant);
            if set.is_empty() {
                typing.remove(conversation);
            }
        }
    }

    /// Everyone typing now, by conversation (one lock for the Home rows).
    pub(crate) fn conversation_typing_all(&self) -> HashMap<String, Vec<String>> {
        let typing = self.conversations.typing.lock().unwrap_or_else(PoisonError::into_inner);
        typing
            .iter()
            .map(|(conversation, set)| (conversation.clone(), set.iter().cloned().collect()))
            .collect()
    }

    /// The participants typing in `conversation` now, sorted.
    pub(crate) fn conversation_typing(&self, conversation: &str) -> Vec<String> {
        let typing = self.conversations.typing.lock().unwrap_or_else(PoisonError::into_inner);
        typing.get(conversation).map(|set| set.iter().cloned().collect()).unwrap_or_default()
    }

    /// An agent or person whose last bound connection ended (or whose token
    /// was replaced) types nowhere any more:
    /// clear its typing and tell subscribers, so no client waits on a
    /// typing indicator nobody will turn off.
    fn end_agent_typing(&self, participant: &str) {
        let still_bound = self
            .conversations
            .bindings
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .any(|bound| bound == participant);
        if still_bound {
            return;
        }
        let ended: Vec<String> = {
            let mut typing =
                self.conversations.typing.lock().unwrap_or_else(PoisonError::into_inner);
            let ended = typing
                .iter_mut()
                .filter_map(|(conversation, set)| {
                    set.remove(participant).then(|| conversation.clone())
                })
                .collect();
            typing.retain(|_, set| !set.is_empty());
            ended
        };
        for conversation in ended {
            self.emit(MuxEvent::Conversation(Arc::new(
                crate::conversation_store::ConversationEvent::Typing {
                    conversation,
                    participant: participant.to_owned(),
                    on: false,
                },
            )));
        }
    }

    /// Ends `client`'s binding when its connection ends.
    pub(crate) fn unbind_conversation_principal(&self, client: u64) {
        // Poison recovery: a removal never grants access, so a poisoned bindings lock
        // still drops the binding.
        let bound = self
            .conversations
            .bindings
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&client);
        // A bound agent or person: its typing ends with its last connection.
        if let Some(participant) =
            bound.filter(|p| p.starts_with("agent_") || p.starts_with("user_"))
        {
            self.end_agent_typing(&participant);
        }
        // Poison recovery: a removal never grants access, so a poisoned peers lock
        // still drops the record.
        self.conversations
            .remote
            .peers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&client);
        // Its attachment uploads end with it (never opens the store); their
        // partial files are removed after the store lock is released.
        let closed = self
            .conversations
            .lock_store()
            .unwrap_or_else(PoisonError::into_inner)
            .as_mut()
            .map(|store| store.attachments_client_closed(client));
        if let Some(closed) = closed {
            closed.remove_partial_files();
        }
    }

    /// Ends every binding of `participant` (its token was replaced). The
    /// connection keeps a revoked marker instead of losing its binding: an
    /// unbound trusted connection is `user_local`, so removing the binding
    /// would make the old agent connection the person. The marker names no
    /// participant (`:` is not allowed in a participant id), so it fails
    /// closed until the connection binds again with the new token. Its
    /// typing ends with the old binding.
    pub(crate) fn unbind_conversation_participant(&self, participant: &str) {
        let revoked = format!("{REVOKED_BINDING_PREFIX}{participant}");
        {
            let mut bindings =
                self.conversations.bindings.lock().unwrap_or_else(PoisonError::into_inner);
            for bound in bindings.values_mut() {
                if bound == participant {
                    bound.clone_from(&revoked);
                }
            }
        }
        self.end_agent_typing(participant);
    }
}
