//! Hosting of the local conversation owner (plans/cmux-next/home.md section
//! 1, `local-conversations-v1`). The store is its own owner with its own
//! file; the mux only opens it next to the workspace registry and publishes
//! its events after each commit.

use super::*;
use crate::conversation_store::{ConversationStore, LOCAL_USER};

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
        let _order = self.conversations.publish.lock().unwrap();
        let value = self.with_conversations(write)?;
        if let Some(event) = publish(&value) {
            self.emit(event);
        }
        Ok(value)
    }

    /// The conversation principal of control client `client`: the agent it
    /// bound with a token, else the Mac's user (`user_local`).
    pub(crate) fn conversation_principal(&self, client: u64) -> String {
        let bindings = self.conversations.bindings.lock().unwrap();
        bindings.get(&client).cloned().unwrap_or_else(|| LOCAL_USER.to_string())
    }

    /// Binds `client` to agent `participant` for the rest of the connection.
    pub(crate) fn bind_conversation_principal(&self, client: u64, participant: String) {
        self.conversations.bindings.lock().unwrap().insert(client, participant);
    }

    /// Ends `client`'s binding when its connection ends.
    pub(crate) fn unbind_conversation_principal(&self, client: u64) {
        self.conversations.bindings.lock().unwrap().remove(&client);
    }

    /// Ends every binding of `participant` (its token was replaced).
    pub(crate) fn unbind_conversation_participant(&self, participant: &str) {
        self.conversations.bindings.lock().unwrap().retain(|_, bound| bound != participant);
    }
}

