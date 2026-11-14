//! Part of `Hub`; see `hub/mod.rs`. The first start of a machine that began as a copy of another.
//!
//! A person's second Cloud machine starts from a capture of their first (cmux-platform
//! `Seed.ts`), so it is signed in already and nothing of their login passes through our servers
//! (Leo, 2026-11-02: "cuz man i dont wanna be liable for peoples' subscription tokns"). The copy
//! carries the first machine's acpmux home: its chats' logs, a turn that was running there and
//! the prompts that waited behind it. A restart goes on with those (`restart_resume.rs`); on a
//! copy that would run them twice, once on each machine. So on its first start a copy settles
//! them as stopped instead:
//!
//! - a turn the logs show open ends `cancelled` with `detail: clone_boot`, and no continuation
//!   is queued for it;
//! - every prompt its queue held is removed (`queue_removed`, `reason: clone_boot`);
//! - a restored auto-resume wait is skipped for good (`auto_resume_skipped`, `skipped:
//!   clone_boot`), so no later start of the copy restores it;
//! - every message its agent pairs held for it is dropped (`agent_pair_dropped`, `reason:
//!   clone_boot`), so no restored or later resume delivers it;
//! - its outbox is set aside unread (`daemon.rs`), and no held agent message goes in again.
//!
//! The chats stay, with their history, and the person can go on in any of them by hand.
//!
//! The marker is `clone-boot` in the acpmux home. cmux-host writes it (`cmux host cloud
//! clone-mark`) while the copy still runs in quarantine, before the cold boot that starts this
//! daemon, when the machine its new `bind.json` names differs from the one `bound.json` recorded.
//! It holds `{"from": <first machine>, "to": <this one>}`. The daemon reads it before any log,
//! and renames it to `clone-boot.done` once every log is read: a start cut short before then
//! settles the rest the same way on the next start (each settle is idempotent: a settled turn
//! is no longer open and a removed prompt is no longer queued).
use super::*;

/// The marker's name in the acpmux home.
pub const MARKER: &str = "clone-boot";
/// What the marker becomes once every log was read.
pub const DONE: &str = "clone-boot.done";

impl Hub {
    /// At daemon start, before any log is read: this start is a copy's first when `home` holds
    /// the marker. Returns the machine it was copied from ("" when the marker does not say).
    pub(crate) fn take_clone_marker(&self, home: &std::path::Path) -> Option<String> {
        let text = match std::fs::read_to_string(home.join(MARKER)) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return None,
            // Present but unreadable still says this is a copy.
            Err(e) => {
                tracing::warn!("clone marker unreadable, settling as a copy anyway: {e}");
                String::new()
            }
        };
        let from = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| v.get("from").and_then(Value::as_str).map(str::to_owned))
            .unwrap_or_default();
        self.set_clone_boot(from.clone());
        tracing::warn!(from = %from, "first start of a copied machine: open turns and queued prompts settle as stopped");
        Some(from)
    }

    /// This daemon settles what the logs left open as a copy does (tests set it directly).
    pub(crate) fn set_clone_boot(&self, from: String) {
        let _ = self.clone_boot.set(from);
    }

    /// The machine this one was copied from, when this start is a copy's first.
    pub(super) fn clone_of(&self) -> Option<&str> {
        self.clone_boot.get().map(String::as_str)
    }

    /// Every log was read: the marker is spent. Kept beside as `clone-boot.done`, so the copy
    /// shows what its first start did.
    pub(crate) fn finish_clone_boot(&self, home: &std::path::Path) {
        if self.clone_of().is_none() {
            return;
        }
        if let Err(e) = crate::home_fs::rename(home.join(MARKER), home.join(DONE))
            && e.kind() != std::io::ErrorKind::NotFound
        {
            tracing::warn!("clone marker not retired: {e}");
        }
    }

    /// A copy's first start: the turn the logs show open ends stopped, with no continuation.
    pub(super) fn settle_cloned_turn(
        &self,
        session: &Arc<Session>,
        from: &str,
        open: (u64, Value, Value, bool),
    ) {
        let (seq, turn_id, prompt_id, trigger) = open;
        let error = "this machine started as a copy of another; the turn running there was stopped here, not continued";
        if trigger {
            self.append(session, "mux", super::background_turn::RECORD_KIND, json!({
                "state":"ended", "id":format!("bg-trigger-{}", turn_id.as_str().unwrap_or_default()),
                "trigger":"system", "quiet":false, "reason":"exit"
            }));
        }
        self.append_unknown_outcome(session, json!({"status": "cancelled", "stopReason": "cancelled", "detail": "clone_boot", "cloneOf": from, "turnSeq": seq, "turnId": turn_id, "promptId": prompt_id, "trigger": trigger, "error": error, "errorText": error}));
        self.save_meta(session);
    }

    /// A copy's first start: every prompt the restored queue holds is removed, so none runs on
    /// this machine as well as on the one it was copied from.
    pub(super) fn drop_cloned_queue(&self, session: &Arc<Session>) {
        let Some(from) = self.clone_of() else { return };
        // And what its agent pairs held for it (`agent_pairs.rs`).
        self.drop_cloned_pair_holds(session, from);
        let ids: Vec<String> = session
            .queue
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .iter()
            .map(|q| q.prompt_id.clone())
            .collect();
        for id in ids {
            self.remove_queued_because(session, &id, Some("clone_boot"));
        }
    }
}

#[cfg(test)]
mod tests;
