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
    }

    /// Some attached client shows the chat, so a turn ending now is seen.
    pub(super) fn shown(&self, session: &Session) -> bool {
        session.attached.load(Ordering::SeqCst) > session.hidden.load(Ordering::SeqCst)
    }

    /// The person marked the chat unread (`_acpmux/markUnread`): sets `unread` and tells every
    /// client. A client that shows it keeps it unread until it hides and shows it again.
    pub fn mark_unread(&self, session: &Session) {
        // Changed and logged in one step: a restart rebuilds the mark from this record
        // (`meta_replay.rs`). The status is read from `m`: the meta lock is held here.
        // The person's change: `_acpmux/markUnread` answers once this record is on disk
        // (`request_writes.rs`: the append notes it).
        let logged = self.change_logged(session, "status", |m| {
            (!std::mem::replace(&mut m.unread, true))
                .then(|| json!({"status": m.status.to_string(), "read": false}))
        });
        if logged.is_some() {
            self.save_meta(session);
        }
    }

    /// The person saw the chat: clears `unread` and tells every client.
    fn mark_seen(&self, session: &Session) {
        // A chat switch to a read chat changes nothing: no append lock on that path. Only once
        // caught up: before, a replay may still bring back an unread mark this must clear.
        if session.caught_up.load(Ordering::SeqCst)
            && !session.meta.lock().unwrap_or_else(|e| e.into_inner()).unread
        {
            return;
        }
        // It tells the clients, and the chat switch does not wait for it: a lost read mark
        // only shows the dot again (`request_writes.rs`: unnoted).
        let logged = request_writes::unnoted(|| {
            self.change_logged(session, "status", |m| {
                std::mem::replace(&mut m.unread, false)
                    .then(|| json!({"status": m.status.to_string(), "read": true}))
            })
        });
        if logged.is_some() {
            self.save_meta(session);
        }
    }
}
