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
//!
//! Showing is not seeing (Leo, 2026-11-11: "if someone steps away from the computer for a bit,
//! that doesn't mean they're necessarily watching it ... if they didn't move the mouse at all,
//! then it's like, well, they didn't see it"). A client that shows the chat also says whether its
//! person attends (`_acpmux/view` `attending`): the pane is on screen, its window is key, and the
//! person moved the pointer, typed or scrolled within the client's idle window. A shown client
//! whose person does not attend is `idle`: the chat stays shown (its process, its recap and
//! presence follow `shown`), but read state follows `attended`, so turns that end while the
//! person is away from a chat left on screen are unread, and coming back is a return with
//! "New since you looked" where they stopped attending (`seenSeq`, which may be earlier than the
//! moment the client noticed: the seq it had at the person's last input).
//!
//! What the person has seen, row by row (Leo, 2026-11-12: "it doesn't actually keep track of,
//! like, when the things ... when you restart the update, all of a sudden it's just, like, you
//! know, it's there and it's noisy"): one cursor per chat per person, `read_through`, the newest
//! log seq that was on their screen while they attended it. Only `_acpmux/seen` moves it, and
//! only forward, never past the chat's own seq. A restart, an update, a reconnect, an attach, a
//! re-subscribe, `_acpmux/view`, a notice and every `mux` record leave it where it is, so a chat
//! with nothing new after a restart has nothing unseen. `_acpmux/markUnread` with `readThrough`
//! may move it back. Kept in `session.json` (`SessionMeta::read_through`); it changes once per
//! advance the pane sends (throttled there), never per record. The dot above (`unread`) is apart.

use super::*;

/// The owner's key in `SessionMeta::read_through`: a request with no `_meta.acpmux.author` is the
/// owner's. No author id is this (they are `tailnet:…`, `user_…` or `guest:…`, `author.rs`).
pub const OWNER_READER: &str = "owner";

/// Whose seen cursor a request moves: its author's, the owner's when it names none.
pub fn reader_of(author: Option<&crate::author::Author>) -> &str {
    author.map_or(OWNER_READER, |a| a.id.as_str())
}

/// How one client holds a chat: not showing it, showing it while its person is away, or showing it
/// to a person who attends (`server/view.rs`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Look {
    Hidden,
    Idle,
    Attending,
}

impl Look {
    pub fn of(hidden: bool, idle: bool) -> Self {
        match (hidden, idle) {
            (true, _) => Look::Hidden,
            (false, true) => Look::Idle,
            (false, false) => Look::Attending,
        }
    }
}

impl Hub {
    /// A client attached (`delta` > 0) or detached; `visible` says whether
    /// it shows the chat. Attaching to show it is seeing it.
    pub fn attach_count(&self, session: &Session, delta: i32, visible: bool) {
        // A client letting go starts the idle period; one arriving resets it.
        self.touch(session);
        let was_attended = self.attended(session);
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
        self.left_off(session, was_attended, seen);
        // Leaving the chat or coming back to it (`away_recap.rs`).
        self.recap_visibility(session);
        // The git watch follows the chats clients hold (`git_watch.rs`).
        self.git_watch_wake();
        // Its `attached` and `shown` change no event carries (`list_guard.rs`): its row only.
        self.events.row_changed(session);
    }

    /// An attached client starts or stops showing the chat (to a person who attends).
    pub fn set_visible(&self, session: &Session, visible: bool) {
        let (before, after) =
            if visible { (Look::Hidden, Look::Attending) } else { (Look::Attending, Look::Hidden) };
        self.look_changed(session, before, after, None);
    }

    /// One attached client's look changed from `before` to `after`. Coming to attend is seeing
    /// the chat; the last attending client going idle or hidden leaves it where the person was:
    /// `seen_through`, the seq its client had at the person's last input, when it says one.
    /// Returns the person's return the chat now keeps (`last_return`), for the client to draw
    /// "New since you looked" without waiting for its list.
    pub(crate) fn look_changed(
        &self,
        session: &Session,
        before: Look,
        after: Look,
        seen_through: Option<u64>,
    ) -> Option<crate::store::LastReturn> {
        if before == after {
            return None;
        }
        let was_attended = self.attended(session);
        let seq = session.seq.load(Ordering::SeqCst);
        let less = |v: usize| Some(v.saturating_sub(1));
        match before {
            Look::Hidden => {
                let _ = session.hidden.fetch_update(Ordering::SeqCst, Ordering::SeqCst, less);
            }
            Look::Idle => {
                let _ = session.idle.fetch_update(Ordering::SeqCst, Ordering::SeqCst, less);
            }
            Look::Attending => {}
        }
        match after {
            Look::Hidden => {
                session.hidden.fetch_add(1, Ordering::SeqCst);
            }
            Look::Idle => {
                session.idle.fetch_add(1, Ordering::SeqCst);
            }
            Look::Attending => {
                if before == Look::Idle && !was_attended {
                    self.count_running_turn(session, seq);
                }
                self.mark_seen(session)
            }
        }
        self.left_off(session, was_attended, seen_through.map_or(seq, |t| t.min(seq)));
        self.recap_visibility(session);
        self.events.row_changed(session);
        session.meta().last_return.filter(|_| after == Look::Attending)
    }

    /// The last client showing the chat to a person who attends stopped: the person has seen it
    /// up to `seq`, read before the counters changed, so a record that lands while they change is
    /// left under the line. A turn that ended after `seq` (the client's seq at the person's last
    /// input) ended while they had stopped looking: it counts unread as if it ended now.
    fn left_off(&self, session: &Session, was_attended: bool, seq: u64) {
        if !was_attended || self.attended(session) {
            return;
        }
        let missed_turn = session.turn_ended_seq.load(Ordering::SeqCst) > seq;
        let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let returned = meta.last_return.take().is_some();
        let changed = meta.seen_seq.replace(seq) != Some(seq) || returned;
        drop(meta);
        if missed_turn {
            self.mark_unread_unless_work_below(session);
            let unread = session.meta().unread;
            self.save_meta(session);
            if unread {
                let status = session.status().to_string();
                self.append(session, "mux", "status", json!({"status": status, "read": false}));
            }
        } else if changed {
            self.save_meta(session);
        }
    }

    /// The person comes back from idle while a turn still runs that wrote after where they left
    /// off: what it wrote is new to them, so the return counts it, and "New since you looked" goes
    /// over it as over a turn that ended.
    fn count_running_turn(&self, session: &Session, seq: u64) {
        if session.status() != SessionStatus::Running {
            return;
        }
        let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        if meta.unread_turns == 0 && meta.seen_seq.is_some_and(|since| since < seq) {
            Self::count_unread_turn(&mut meta);
        }
    }

    /// A person's turn ended: unread unless a client shows the chat to a person who attends.
    /// Its seq is kept, so a person found idle later, whose last input came before it, missed it.
    pub(super) fn note_turn_end(&self, session: &Session) {
        session.turn_ended_seq.store(session.seq.load(Ordering::SeqCst), Ordering::SeqCst);
        if !self.attended(session) {
            self.mark_unread_unless_work_below(session);
        }
    }

    /// A turn ended while no client showed the chat: one more for the sidebar's count.
    pub(super) fn count_unread_turn(meta: &mut crate::store::SessionMeta) {
        meta.unread_turns = meta.unread_turns.saturating_add(1);
    }

    /// Some attached client shows the chat: its process, recap and presence follow this.
    pub(super) fn shown(&self, session: &Session) -> bool {
        session.attached.load(Ordering::SeqCst) > session.hidden.load(Ordering::SeqCst)
    }

    /// Some attached client shows the chat to a person who attends, so a turn ending now is seen.
    pub(super) fn attended(&self, session: &Session) -> bool {
        let away = session.hidden.load(Ordering::SeqCst) + session.idle.load(Ordering::SeqCst);
        session.attached.load(Ordering::SeqCst) > away
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

    /// The person marked the chat read without showing it (`_acpmux/markRead`, cmux's
    /// `chat.mark_read`): clears `unread` and its count and tells every client, as seeing it
    /// does, but moves no "where they left off" mark (nobody looked). Answered once the change
    /// is on disk, also when the chat was read already.
    pub(crate) fn mark_read_answered(&self, session: &Session) -> Result<(), RpcError> {
        let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let was_unread = std::mem::replace(&mut meta.unread, false);
        let turns = std::mem::take(&mut meta.unread_turns);
        drop(meta);
        if !was_unread && turns == 0 {
            return self.meta_barrier(session);
        }
        let saved = self.save_meta_answered(session);
        self.append(
            session,
            "mux",
            "status",
            json!({"status": session.status().to_string(), "read": true, "since": null, "turns": turns}),
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

impl Hub {
    /// `reader`'s seen cursor on the chat: the newest log seq they saw. None until they first
    /// saw a row (or on a chat from before it was kept).
    pub fn read_through(&self, session: &Session, reader: &str) -> Option<u64> {
        session.read_meta(|m| m.read_through.get(reader).copied())
    }

    /// `_acpmux/seen`: `reader` saw the chat through `seq`. Moves their cursor forward only, never
    /// past the chat's newest record; saved only when it moved. Returns the cursor after.
    pub fn mark_read_through(&self, session: &Session, reader: &str, seq: u64) -> u64 {
        let seq = seq.min(session.seq.load(Ordering::SeqCst));
        let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let before = meta.read_through.get(reader).copied();
        if before.is_some_and(|b| b >= seq) {
            return before.unwrap_or(seq);
        }
        meta.read_through.insert(reader.to_owned(), seq);
        drop(meta);
        self.save_meta(session);
        seq
    }

    /// `_acpmux/markUnread` with `readThrough`: the person marks the rows after `seq` unseen
    /// again. Moves their cursor back only; returns it after.
    pub fn mark_read_back(&self, session: &Session, reader: &str, seq: u64) -> u64 {
        let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        let before = meta.read_through.get(reader).copied();
        if before.is_some_and(|b| b <= seq) {
            return before.unwrap_or(seq);
        }
        meta.read_through.insert(reader.to_owned(), seq);
        drop(meta);
        self.save_meta(session);
        seq
    }
}

#[cfg(test)]
#[path = "seen_tests.rs"]
mod tests;
