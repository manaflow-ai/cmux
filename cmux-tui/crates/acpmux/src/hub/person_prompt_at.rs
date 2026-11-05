//! Part of `Hub`; see `hub/mod.rs`. When a person last sent a prompt into one of this daemon's
//! chats (Unix ms), for the Cloud activity report (`daemon/cloud_activity.rs`): the Cloud keeps a
//! machine running for a while after a person's chat (cmux-platform `IdlePolicy.ts`, the
//! post-chat warm window, `last_person_prompt_at`), and a chat's prompt is the only person's
//! input a Cloud chat makes (the terminal daemon sees keys, mouse and paste, never a prompt).
//!
//! Only `server/agent_messages.rs` `person_prompt` moves it: a `session/prompt` with no agent's
//! provenance, from a connection that is no trigger and runs in no session. An agent's message,
//! a trigger's (automation) delivery, and whatever the daemon sends on its own (a queued prompt, an
//! auto-resume, an inbox digest) never do. It never moves backwards, and like the rest of the
//! activity report it lives in memory only: a restarted daemon has none until the next prompt.

use super::*;

impl Hub {
    /// A person's prompt reached this daemon at `at_ms`. Never moves the time backwards.
    pub(crate) fn person_prompted(&self, at_ms: u64) {
        self.person_prompts.send_if_modified(|last| {
            if at_ms > *last {
                *last = at_ms;
                true
            } else {
                false
            }
        });
    }

    /// When a person last prompted a chat here (Unix ms), if one did since this daemon started.
    pub fn last_person_prompt_at(&self) -> Option<u64> {
        Some(*self.person_prompts.borrow()).filter(|at| *at > 0)
    }

    /// Changes each time [`Self::person_prompted`] moves the time.
    pub(crate) fn subscribe_person_prompts(&self) -> tokio::sync::watch::Receiver<u64> {
        self.person_prompts.subscribe()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_hub() -> Arc<Hub> {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut cfg: crate::config::Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        Hub::new(cfg, store)
    }

    #[test]
    fn the_time_only_moves_forward() {
        let hub = test_hub();
        assert_eq!(hub.last_person_prompt_at(), None);
        let mut rx = hub.subscribe_person_prompts();
        hub.person_prompted(5_000);
        assert_eq!(hub.last_person_prompt_at(), Some(5_000));
        assert!(rx.has_changed().unwrap());
        rx.borrow_and_update();
        hub.person_prompted(4_000);
        assert_eq!(hub.last_person_prompt_at(), Some(5_000), "an older time never moves it back");
        assert!(!rx.has_changed().unwrap(), "nor wakes the report");
        hub.person_prompted(6_000);
        assert_eq!(hub.last_person_prompt_at(), Some(6_000));
    }
}
