//! Chats this daemon landed through a guarded `agent-transfer-finish`: the
//! one exception to cx-k21v's rule that a `registry:` tab never gets its
//! session from a client. A chat acpmux imported here through a finish this
//! daemon ran no longer exists on the machine it came from; it is this
//! machine's own chat, so `new-conversation-tab` may file it under this
//! store's `registry:` host (Move to Cloud opens the moved chat that way).
//!
//! The record is the session id acpmux's finish answered, never one a client
//! sent: the 16 most recent, each for 24 h, kept in [`LANDED_FILE`] next to
//! the session's registry (owner-only, rewritten atomically), so a show
//! retried after a daemon restart still opens the chat. An in-memory session
//! keeps them in memory only.
//!
//! The file is trusted only as this daemon writes it (`state_file.rs`;
//! anything else reads as an empty list). A chat this daemon begins moving
//! away again is forgotten at once, so a stale entry never revives a second
//! copy of a chat that left.

use cmux_threads::sync::Mutex;
use std::path::Path;

use serde::{Deserialize, Serialize};

use super::state_file::{self, now_ms, read_trusted, save};
use super::{is_plain_id, lock};
use crate::mux::Mux;

/// The landed chats file in the session state directory.
pub(super) const LANDED_FILE: &str = "agent-transfer-landed.json";
/// Landed chats remembered (the oldest goes first).
const MAX_LANDED: usize = 16;

#[derive(Clone, Serialize, Deserialize)]
struct LandedChat {
    session: String,
    landed_at_ms: u64,
}

/// The landed chats, read from the file on first use (`None` until then).
#[derive(Default)]
pub(super) struct Landed {
    chats: Mutex<Option<Vec<LandedChat>>>,
}

fn fresh(chat: &LandedChat, now: u64) -> bool {
    state_file::fresh(chat.landed_at_ms, now)
}

/// The file's fresh, well formed records, oldest first; none when it is
/// missing, too large, damaged or not this daemon's own file (the next
/// landing replaces it).
fn load(directory: Option<&Path>) -> Vec<LandedChat> {
    let Some(path) = directory.map(|directory| directory.join(LANDED_FILE)) else {
        return Vec::new();
    };
    let chats: Vec<LandedChat> = read_trusted(&path)
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or_default();
    let now = now_ms();
    let mut chats: Vec<_> =
        chats.into_iter().filter(|chat| is_plain_id(&chat.session) && fresh(chat, now)).collect();
    let extra = chats.len().saturating_sub(MAX_LANDED);
    chats.drain(..extra);
    chats
}

impl Mux {
    /// True when this daemon itself landed acpmux chat `session` through a
    /// guarded `agent-transfer-finish` (within the last 24 h, the 16 most
    /// recent).
    pub(crate) fn landed_agent_session(&self, session: &str) -> bool {
        let directory = self.session_state_directory();
        let mut chats = lock(&self.agent_transfers.landed.chats);
        let chats = chats.get_or_insert_with(|| load(directory.as_deref()));
        let now = now_ms();
        chats.iter().any(|chat| chat.session == session && fresh(chat, now))
    }

    /// Remembers `session`, the id acpmux's finish answered, as landed here.
    pub(super) fn remember_landed_agent_session(&self, session: &str) {
        if !is_plain_id(session) {
            return;
        }
        let directory = self.session_state_directory();
        let mut chats = lock(&self.agent_transfers.landed.chats);
        let chats = chats.get_or_insert_with(|| load(directory.as_deref()));
        let now = now_ms();
        chats.retain(|chat| chat.session != session && fresh(chat, now));
        let extra = (chats.len() + 1).saturating_sub(MAX_LANDED);
        chats.drain(..extra);
        chats.push(LandedChat { session: session.to_owned(), landed_at_ms: now });
        if let Some(directory) = directory
            && let Err(error) = save(&directory, LANDED_FILE, chats)
        {
            // Still landed for this daemon's life; only a restart forgets it.
            eprintln!("cmux-tui: landed chat record not written: {error}");
        }
    }

    /// Forgets `session` (this daemon is moving it away again).
    pub(super) fn forget_landed_agent_session(&self, session: &str) {
        let directory = self.session_state_directory();
        let mut chats = lock(&self.agent_transfers.landed.chats);
        let chats = chats.get_or_insert_with(|| load(directory.as_deref()));
        let before = chats.len();
        chats.retain(|chat| chat.session != session);
        if chats.len() != before
            && let Some(directory) = directory
            && let Err(error) = save(&directory, LANDED_FILE, chats)
        {
            eprintln!("cmux-tui: landed chat record not written: {error}");
        }
    }
}
