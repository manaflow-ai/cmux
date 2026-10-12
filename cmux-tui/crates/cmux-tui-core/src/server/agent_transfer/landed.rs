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

use std::io::Write as _;
use std::path::Path;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use super::{STALE, is_plain_id, lock};
use crate::mux::Mux;

/// The landed chats file in the session state directory.
pub(super) const LANDED_FILE: &str = "agent-transfer-landed.json";
/// Landed chats remembered (the oldest goes first).
const MAX_LANDED: usize = 16;
/// The largest file read back (16 short records are far below it).
const MAX_FILE_BYTES: u64 = 64 * 1024;

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

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

fn fresh(chat: &LandedChat, now: u64) -> bool {
    now.saturating_sub(chat.landed_at_ms) < STALE.as_millis() as u64
}

/// The file's fresh, well formed records, oldest first; none when it is
/// missing, too large or damaged (the next landing replaces it).
fn load(directory: Option<&Path>) -> Vec<LandedChat> {
    let Some(path) = directory.map(|directory| directory.join(LANDED_FILE)) else {
        return Vec::new();
    };
    let small = std::fs::metadata(&path).is_ok_and(|meta| meta.len() <= MAX_FILE_BYTES);
    let read = small.then(|| std::fs::read(&path).ok()).flatten();
    let chats: Vec<LandedChat> =
        read.and_then(|bytes| serde_json::from_slice(&bytes).ok()).unwrap_or_default();
    let now = now_ms();
    let mut chats: Vec<_> =
        chats.into_iter().filter(|chat| is_plain_id(&chat.session) && fresh(chat, now)).collect();
    let extra = chats.len().saturating_sub(MAX_LANDED);
    chats.drain(..extra);
    chats
}

fn save(directory: &Path, chats: &[LandedChat]) -> std::io::Result<()> {
    let bytes = serde_json::to_vec(chats)?;
    let path = directory.join(LANDED_FILE);
    let temporary = directory.join(format!("{LANDED_FILE}.{}.tmp", std::process::id()));
    let written = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(&bytes)?;
        file.sync_data()?;
        drop(file);
        std::fs::rename(&temporary, &path)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    written
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
            && let Err(error) = save(&directory, chats)
        {
            // Still landed for this daemon's life; only a restart forgets it.
            eprintln!("cmux-tui: landed chat record not written: {error}");
        }
    }
}
