//! Hosting of the local conversation owner (plans/cmux-next/home.md section
//! 1, `local-conversations-v1`). The store is its own owner with its own
//! file; the mux only opens it next to the workspace registry and publishes
//! its events after each commit.

use super::*;
use crate::conversation_store::ConversationStore;
use crate::remote_relay_state::{RelayLock, RelayStateError, lock_checked};

impl Mux {
    /// Run `operation` on the conversation store, opening
    /// `conversations.sqlite3` in the session state directory on first use
    /// (in memory for an in-memory session).
    pub(crate) fn with_conversations<T>(
        &self,
        operation: impl FnOnce(&mut ConversationStore) -> anyhow::Result<T>,
    ) -> anyhow::Result<T> {
        let mut store = self.conversations.store.lock().unwrap();
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
    pub(crate) fn conversation_write_many<T>(
        &self,
        write: impl FnOnce(&mut ConversationStore) -> anyhow::Result<T>,
        publish: impl FnOnce(&T) -> Vec<MuxEvent>,
    ) -> anyhow::Result<T> {
        let _order = self.conversations.publish.lock().unwrap();
        let value = self.with_conversations(write)?;
        for event in publish(&value) {
            self.emit(event);
        }
        Ok(value)
    }

    /// The remote-relay state (peers, pairing records, revocation limits).
    pub(crate) fn remote_relay(&self) -> &crate::remote_relay_state::RemoteRelayState {
        &self.conversations.remote
    }

    /// The agent participant `client` bound with a token, if any. The
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

    /// The bindings lock (tests poison it).
    #[cfg(test)]
    pub(crate) fn conversation_bindings(&self) -> &Mutex<std::collections::BTreeMap<u64, String>> {
        &self.conversations.bindings
    }

    /// Ends `client`'s binding when its connection ends.
    pub(crate) fn unbind_conversation_principal(&self, client: u64) {
        // Safety: a removal never grants access, so a poisoned bindings lock
        // still drops the binding.
        self.conversations.bindings.lock().unwrap_or_else(PoisonError::into_inner).remove(&client);
        // Safety: a removal never grants access, so a poisoned peers lock
        // still drops the record.
        self.conversations
            .remote
            .peers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&client);
        // Its attachment uploads end with it (never opens the store).
        if let Some(store) =
            self.conversations.store.lock().unwrap_or_else(PoisonError::into_inner).as_mut()
        {
            store.attachments_client_closed(client);
        }
    }

    /// Ends every binding of `participant` (its token was replaced).
    pub(crate) fn unbind_conversation_participant(&self, participant: &str) {
        // Safety: a removal never grants access.
        self.conversations
            .bindings
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .retain(|_, bound| bound != participant);
    }
}
