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
//! The file is trusted only as this daemon writes it: a regular file owned
//! by this user, opened without following a symlink (anything else reads as
//! an empty list); a record dated in the future is not fresh. A chat this
//! daemon begins moving away again is forgotten at once, so a stale entry
//! never revives a second copy of a chat that left.

use std::io::{Read as _, Write as _};
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
/// Clock skew a record's time may be ahead of now by.
const MAX_SKEW_MS: u64 = 60 * 1000;

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
    chat.landed_at_ms <= now.saturating_add(MAX_SKEW_MS)
        && now.saturating_sub(chat.landed_at_ms) < STALE.as_millis() as u64
}

/// Opens `path` without following a final symlink (Unix).
fn open_options() -> std::fs::OpenOptions {
    let mut options = std::fs::OpenOptions::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    options
}

/// The file's bytes when it is a regular file of this user within the size
/// bound, read through one handle (no symlink, no swap after the check).
fn read_trusted(path: &Path) -> Option<Vec<u8>> {
    let file = open_options().read(true).open(path).ok()?;
    let meta = file.metadata().ok()?;
    if !meta.is_file() || meta.len() > MAX_FILE_BYTES {
        return None;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        // SAFETY: geteuid has no preconditions.
        if meta.uid() != unsafe { libc::geteuid() } {
            return None;
        }
    }
    let mut bytes = Vec::new();
    file.take(MAX_FILE_BYTES + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() as u64 <= MAX_FILE_BYTES).then_some(bytes)
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

fn save(directory: &Path, chats: &[LandedChat]) -> std::io::Result<()> {
    let bytes = serde_json::to_vec(chats)?;
    let path = directory.join(LANDED_FILE);
    let temporary = directory.join(format!("{LANDED_FILE}.{}.tmp", std::process::id()));
    // A leftover (or planted) temporary goes first: the new one is created
    // fresh and never through a symlink.
    let _ = std::fs::remove_file(&temporary);
    let written = (|| {
        let mut options = open_options();
        options.write(true).create_new(true);
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

    /// Forgets `session` (this daemon is moving it away again).
    pub(super) fn forget_landed_agent_session(&self, session: &str) {
        let directory = self.session_state_directory();
        let mut chats = lock(&self.agent_transfers.landed.chats);
        let chats = chats.get_or_insert_with(|| load(directory.as_deref()));
        let before = chats.len();
        chats.retain(|chat| chat.session != session);
        if chats.len() != before
            && let Some(directory) = directory
            && let Err(error) = save(&directory, chats)
        {
            eprintln!("cmux-tui: landed chat record not written: {error}");
        }
    }
}
