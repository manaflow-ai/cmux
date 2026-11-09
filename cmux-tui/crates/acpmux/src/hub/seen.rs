//! What the person has seen (cx-n8ou). A client attached to a chat says
//! whether it shows it (`_acpmux/attach` `visible`, `_acpmux/view`); one that
//! never says counts as showing it (the TUI, `acpmux attach`). A turn that
//! ends while no attached client shows the chat leaves it `unread`, and
//! showing it is seeing it, so every client draws the same dot.
//!
//! Where the person left off (Leo, 2026-11-08: "go think of things/look at things, esp valuable
//! things that people would think \"wow this is awesome\""): when the last client showing the
//! chat stops, its log seq is kept as `seen_seq`, and each turn that ends unseen counts in
//! `unread_turns`. Showing it again logs the `read` status with both (`since`, `turns`), so a
//! client draws "New since you looked" above the first record after `since`. That return is kept
//! as `last_return` while the person stays (the summary's `lastReturn`), so a client whose attach
//! answers before its list read still draws it. All are kept in `session.json` and change once
//! per hide, show or turn, never per record.

use super::*;

impl Hub {
    /// A client attached (`delta` > 0) or detached; `visible` says whether
    /// it shows the chat. Attaching to show it is seeing it.
    pub fn attach_count(&self, session: &Session, delta: i32, visible: bool) {
        // A client letting go starts the idle period; one arriving resets it.
        self.touch(session);
        let was_shown = self.shown(session);
        let seen = session.seq.load(Ordering::SeqCst);
        let n = delta.unsigned_abs() as usize;
        if delta > 0 {
            session.attached.fetch_add(n, Ordering::SeqCst);
            if visible {
                self.mark_seen(session);
            } else {
                session.hidden.fetch_add(n, Ordering::SeqCst);
            }
        } else {
            let less = |v: usize| Some(v.saturating_sub(n));
            let _ = session.attached.fetch_update(Ordering::SeqCst, Ordering::SeqCst, less);
            if !visible {
                let _ = session.hidden.fetch_update(Ordering::SeqCst, Ordering::SeqCst, less);
            }
        }
        self.left_off(session, was_shown, seen);
        // Leaving the chat or coming back to it (`away_recap.rs`).
        self.recap_visibility(session);
        // The git watch follows the chats clients hold (`git_watch.rs`).
        self.git_watch_wake();
        // Its `attached` and `shown` change no event carries (`list_guard.rs`).
        self.events.changed();
    }

    /// An attached client starts or stops showing the chat.
    pub fn set_visible(&self, session: &Session, visible: bool) {
        let was_shown = self.shown(session);
        let seen = session.seq.load(Ordering::SeqCst);
        let less = |v: usize| Some(v.saturating_sub(1));
        if visible {
            let _ = session.hidden.fetch_update(Ordering::SeqCst, Ordering::SeqCst, less);
            self.mark_seen(session);
        } else {
            session.hidden.fetch_add(1, Ordering::SeqCst);
        }
        self.left_off(session, was_shown, seen);
        self.recap_visibility(session);
        self.events.changed();
    }

    /// The last client showing the chat stopped: the person has seen it up to `seq`, read before
    /// the counters changed, so a record that lands while they change is left under the line.
    fn left_off(&self, session: &Session, was_shown: bool, seq: u64) {
        if !was_shown || self.shown(session) {
            return;
        }
        let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let returned = meta.last_return.take().is_some();
        let changed = meta.seen_seq.replace(seq) != Some(seq) || returned;
        drop(meta);
        if changed {
            self.save_meta(session);
        }
    }

    /// A turn ended while no client showed the chat: one more for the sidebar's count.
    pub(super) fn count_unread_turn(meta: &mut crate::store::SessionMeta) {
        meta.unread_turns = meta.unread_turns.saturating_add(1);
    }

    /// Some attached client shows the chat, so a turn ending now is seen.
    pub(super) fn shown(&self, session: &Session) -> bool {
        session.attached.load(Ordering::SeqCst) > session.hidden.load(Ordering::SeqCst)
    }

    /// The person marked the chat unread (`_acpmux/markUnread`): sets `unread` and tells every
    /// client. A client that shows it keeps it unread until it hides and shows it again.
    pub fn mark_unread(&self, session: &Session) {
        // No request waits for this one: a failed save is logged there.
        let _ = self.mark_unread_as(session, false);
    }

    /// [`Hub::mark_unread`] for the person's `_acpmux/markUnread`: answered only once the mark is
    /// on disk, also when the chat was unread already (an earlier change may not be yet;
    /// `meta_save.rs`).
    pub(crate) fn mark_unread_answered(&self, session: &Session) -> Result<(), RpcError> {
        self.mark_unread_as(session, true)
    }

    fn mark_unread_as(&self, session: &Session, answered: bool) -> Result<(), RpcError> {
        let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let was_read = !std::mem::replace(&mut meta.unread, true);
        drop(meta);
        if !was_read {
            return if answered { self.meta_barrier(session) } else { Ok(()) };
        }
        let saved = if answered {
            self.save_meta_answered(session)
        } else {
            self.save_meta(session);
            Ok(())
        };
        self.append(
            session,
            "mux",
            "status",
            json!({"status": session.status().to_string(), "read": false}),
        );
        saved
    }

    /// The person saw the chat: clears `unread` and its count, and tells every client where they
    /// left off (`since`, none when no person left it before) and how many turns ended since.
    fn mark_seen(&self, session: &Session) {
        let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let was_unread = std::mem::replace(&mut meta.unread, false);
        let turns = std::mem::take(&mut meta.unread_turns);
        let since = meta.seen_seq;
        // Kept until the person leaves again, so every client opening it now draws the divider.
        if let Some(since) = since.filter(|_| turns > 0) {
            meta.last_return = Some(crate::store::LastReturn { since, turns });
        }
        drop(meta);
        // A turn can end while background work holds the dot back, so a count alone is
        // published too: other clients would keep drawing it otherwise.
        if !was_unread && turns == 0 {
            return;
        }
        self.save_meta(session);
        self.append(
            session,
            "mux",
            "status",
            json!({
                "status": session.status().to_string(),
                "read": true,
                "since": since,
                "turns": turns,
            }),
        );
    }
}

#[cfg(test)]
#[path = "seen_tests.rs"]
mod tests;
