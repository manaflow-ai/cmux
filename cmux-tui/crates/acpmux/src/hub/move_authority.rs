//! Part of `Hub`; see `hub/mod.rs`. One authority for moves (RFD 0172 section 4): a chat the
//! AutoCloud store knows (Auto on in its record) changes machine only as a holder change in the
//! store's protocol (cmux#52931: the wish, the give, the takeover), never by `session move`.
//!
//! Before this, an enrolled machine's owner-return timer and autoEvacuate moved every chat with
//! `session move --host auto` (`transfer_begin`), and a person's `cmux move` did too. For an Auto
//! chat that is a second authority: the chat ran on another host while the store still named
//! this machine its holder, so the store's renewals, inbox and handback went to a chat that was
//! no longer here.
//!
//! - [`Hub::move_authority`]: who moves a chat.
//! - [`Hub::move_off_by_authority`]: the automatic movers' one way off this machine. A chat the
//!   store holds here moves to the Cloud through the holder loop (`auto_session/runtime/moves.rs`,
//!   the same request as `_acpmux/auto_session/move`); its give stops a running turn and the new
//!   holder continues it, so nothing is paused or killed. Any other chat moves as before.
//! - `transfer_begin` refuses an Auto chat and names the move that works (`transfer_out.rs`).

use super::auto_evacuate::Mover;
use super::*;
use cmux_auto_session::wire::MoveTo;

/// Who moves a chat off this machine.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Authority {
    /// The AutoCloud store: Auto is on. `here`: this machine holds it for the store now.
    Store { here: bool },
    /// This daemon's own `session move` (the chat is not an Auto chat).
    ThisDaemon,
}

impl Hub {
    /// Who moves chat `id`: the store for an Auto chat, else this daemon.
    pub(crate) fn move_authority(&self, session: &Session) -> Authority {
        match self.auto_record(session) {
            Some(record) if record.auto => Authority::Store { here: record.here },
            _ => Authority::ThisDaemon,
        }
    }

    /// Whether the store moves chat `session` and is moving it now (its wish is out).
    pub(crate) fn store_moving(&self, session: &Session) -> bool {
        self.auto_record(session).is_some_and(|record| record.auto && record.moving.is_some())
    }

    /// Moves chat `id` off this machine by its one authority; answers where it goes, or why it
    /// stays. `mover` is used only for a chat that is not an Auto chat.
    pub(crate) async fn move_off_by_authority(
        &self,
        id: &str,
        mover: &dyn Mover,
    ) -> Result<String, String> {
        let Some(session) = self.session_get(id) else {
            return Err(format!("no session {id}"));
        };
        match self.move_authority(&session) {
            Authority::ThisDaemon => mover.move_off(id).await,
            Authority::Store { here: false } => {
                Err("another machine runs this Auto chat for the Cloud store, so there is nothing \
                 here to move"
                    .into())
            }
            Authority::Store { here: true } => {
                let Some(holder) = self.auto_holder.get() else {
                    return Err("Auto mode is not running on this machine".into());
                };
                if holder.on_machine() {
                    return Err("a Cloud machine gives an Auto chat back only through the \
                                Cloud store's handback"
                        .into());
                }
                holder
                    .move_to(id, MoveTo::Cloud)
                    .await
                    .map(|_| "the Cloud".to_owned())
                    .map_err(|e| e.message)
            }
        }
    }
}

#[cfg(test)]
#[path = "move_authority_tests.rs"]
mod tests;
