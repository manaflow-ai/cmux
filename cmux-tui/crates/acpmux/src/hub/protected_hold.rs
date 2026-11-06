//! LAUNCH-NO-TCC-PROMPTS: a daemon start never starts an agent in a privacy-protected folder
//! by itself. `resume_restored` goes on with what the last daemon left (queued prompts, a cut
//! turn, the inbox, held agent messages, auto-resume retries) in each chat's own folder; an
//! agent started in ~/Downloads reads it at once and macOS asks for Downloads in cmux's name at
//! launch (Lawrence, 2026-10-30). A chat whose folder is guarded (`protected_folders.rs`) keeps
//! all of that waiting, in place, until the person shows it (`_acpmux/attach` or `_acpmux/view`
//! visible), types into it, or sends it a prompt. A hidden attach (a restored tab the app holds)
//! asks for nothing. Only the start is held: a prompt a person or an agent sends now queues
//! behind what waits, as it would behind a running turn.

use super::*;

impl Hub {
    /// Whether `session`'s restored work waits for the person: its folder is protected and no
    /// client shows it now. Marks the hold, which `release_protected_hold` lifts.
    pub(super) fn hold_in_protected_folder(&self, session: &Session) -> bool {
        if self.shown(session) {
            return false;
        }
        let cwd = session.meta().cwd.clone();
        let Some(reason) = crate::protected_folders::unasked_refusal(&cwd) else {
            return false;
        };
        if !session.protected_hold.swap(true, Ordering::SeqCst) {
            tracing::info!(session = %session.id, "restored work waits for the person: {reason}");
        }
        true
    }

    /// The person asked for `session` (showed it, typed into it, prompted it): what a daemon
    /// start held there (`hold_in_protected_folder`) goes on now. Nothing when nothing was held.
    pub(crate) fn release_protected_hold(self: &Arc<Self>, session: &Arc<Session>) {
        if session.protected_hold.swap(false, Ordering::SeqCst) {
            tracing::info!(session = %session.id, "the person opened the chat: restored work goes on");
            self.resume_restored_as(std::slice::from_ref(session), true);
        }
    }
}
