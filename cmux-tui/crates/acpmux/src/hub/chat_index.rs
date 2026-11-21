//! Part of `Hub`; see `hub/mod.rs`. The hub's chat index (`chats/mod.rs`): starting it once,
//! its settings before and after it runs, and work waiting for it. Moved from `chats/mod.rs`:
//! it is the hub's, and `chats` (a lower module) does not reach the hub.

use std::sync::Arc;

use super::Hub;
use crate::chats::{ChatService, ChatSettings, ChatSources, ChatsWaiter};
use crate::no_panic::LockExt;

impl Hub {
    /// Starts the chat index once (later calls do nothing). Waits for the
    /// first scan; `_acpmux/chats` answers `ready: false` until then.
    pub async fn start_chats(self: &Arc<Self>, sources: ChatSources) -> Result<(), String> {
        if self.chats.get().is_some() {
            return Ok(());
        }
        let service = tokio::task::spawn_blocking(move || ChatService::start(sources))
            .await
            .map_err(|e| format!("chat index start: {e}"))?;
        let _ = self.chats.set(service.clone());
        // Taken under the waiters' lock after the set: a later waiter sees the index.
        let waiters = std::mem::take(&mut *self.chats_waiters.lock_or_recover());
        for waiter in waiters {
            waiter(&service);
        }
        // Settings sent during the first scan went only to the file.
        tokio::task::spawn_blocking(move || service.reload_settings())
            .await
            .map_err(|e| format!("chat settings: {e}"))?;
        Ok(())
    }

    /// Applies the app's chat settings; before the index runs, saves them
    /// for its start. Blocking.
    pub fn apply_chat_settings(&self, settings: ChatSettings) -> Result<bool, String> {
        if let Some(service) = self.chats.get() {
            return service.apply_settings(settings).map(|()| true);
        }
        settings
            .save(&crate::config::home().join("chat-settings.json"))
            .map_err(|e| format!("save the chat settings: {e}"))?;
        // The index may have started between the check and the save.
        match self.chats.get() {
            Some(service) => {
                service.reload_settings();
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Runs `waiter` once the chat index has started: now when it runs.
    pub fn when_chats_ready(&self, waiter: ChatsWaiter) {
        let mut waiters = self.chats_waiters.lock_or_recover();
        match self.chats.get() {
            Some(service) => {
                drop(waiters);
                waiter(service);
            }
            None => waiters.push(waiter),
        }
    }

    pub fn chat_index(&self) -> Option<&Arc<ChatService>> {
        self.chats.get()
    }
}
