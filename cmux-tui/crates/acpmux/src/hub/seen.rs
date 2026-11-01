//! What the person has seen (cx-n8ou). A client attached to a chat says
//! whether it shows it (`_acpmux/attach` `visible`, `_acpmux/view`); one that
//! never says counts as showing it (the TUI, `acpmux attach`). A turn that
//! ends while no attached client shows the chat leaves it `unread`, and
//! showing it is seeing it, so every client draws the same dot.

use super::*;

impl Hub {
    /// A client attached (`delta` > 0) or detached; `visible` says whether
    /// it shows the chat. Attaching to show it is seeing it.
    pub fn attach_count(&self, session: &Session, delta: i32, visible: bool) {
        // A client letting go starts the idle period; one arriving resets it.
        self.touch(session);
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
        // The git watch follows the chats clients hold (`git_watch.rs`).
        self.git_watch_wake();
        // Its `attached` and `shown` change no event carries (`list_guard.rs`).
        self.events.changed();
    }

    /// An attached client starts or stops showing the chat.
    pub fn set_visible(&self, session: &Session, visible: bool) {
        let less = |v: usize| Some(v.saturating_sub(1));
        if visible {
            let _ = session.hidden.fetch_update(Ordering::SeqCst, Ordering::SeqCst, less);
            self.mark_seen(session);
        } else {
            session.hidden.fetch_add(1, Ordering::SeqCst);
        }
        self.events.changed();
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

    /// The person saw the chat: clears `unread` and tells every client.
    fn mark_seen(&self, session: &Session) {
        let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let was_unread = std::mem::replace(&mut meta.unread, false);
        drop(meta);
        if was_unread {
            self.save_meta(session);
            self.append(
                session,
                "mux",
                "status",
                json!({"status": session.status().to_string(), "read": true}),
            );
        }
    }
}
