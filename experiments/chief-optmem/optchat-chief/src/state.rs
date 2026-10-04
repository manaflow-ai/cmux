//! The host's durable state (`$MUX_HOME/optchat/host.json`), its only writer
//! being the host. Each entry is a to-do whose effect an owner dedupes (the
//! conversation owner by idempotency key), so a lost write costs a replay,
//! never a duplicate reply.

use std::collections::BTreeMap;
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use cmux_conversation::Op;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct HostState {
    /// The Chief conversation (from conversation-create).
    #[serde(default)]
    pub conversation: Option<String>,
    /// Highest conversation seq whose waking message is in the OptChat log
    /// (or which needed none). The read cursor follows it, so a message is
    /// logged once even across restarts.
    #[serde(default)]
    pub logged_seq: u64,
    /// Conversation ops not yet confirmed by the owner, in order.
    #[serde(default)]
    pub outbox: Vec<OutboxEntry>,
    /// The turn whose messages are logged but whose reply is not posted yet.
    #[serde(default)]
    pub turn: Option<PendingTurn>,
    /// Child sessions (acpmux session id) the Chief started.
    #[serde(default)]
    pub children: BTreeMap<String, ChildRecord>,
    /// Turn sessions whose connection was lost mid-turn: folded and removed
    /// at the next acpmux connect.
    #[serde(default)]
    pub orphans: Vec<crate::turn::Orphan>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct OutboxEntry {
    pub conversation: String,
    pub idempotency_key: String,
    pub op: Op,
    /// Set after one retry of an `agent_rate` reject.
    #[serde(default)]
    pub rate_retried: bool,
    /// Not sent before this time (ms since the epoch); set with `rate_retried`.
    #[serde(default)]
    pub not_before: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingTurn {
    /// The reply's idempotency key and client_msg_id. Empty while the turn's
    /// messages are being logged (the key needs the first one's stamp).
    pub key: String,
    pub conversation: Option<String>,
    /// The turn's acpmux session name.
    pub session: String,
    /// The log length before the turn's messages were appended. Saved before
    /// the first append, so a restart can tell which of them reached the log
    /// and never logs one twice.
    #[serde(default)]
    pub first_id: Option<u64>,
    /// The conversation seq of each queued item, in log order (None for a
    /// child's report or a note).
    #[serde(default)]
    pub seqs: Vec<Option<u64>>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ChildStatus {
    /// A turn runs, or ended and its report is not in the log yet.
    Running,
    /// Its last report is in the log.
    Reported,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChildRecord {
    pub name: String,
    pub status: ChildStatus,
    /// The session's event seq at its previous turn end: the next report is
    /// folded from the events after it.
    #[serde(default)]
    pub floor: u64,
}

/// The file behind `HostState`.
#[derive(Clone, Debug)]
pub struct StateFile {
    path: PathBuf,
}

impl StateFile {
    pub fn new(path: &Path) -> StateFile {
        StateFile {
            path: path.to_owned(),
        }
    }

    /// The saved state; a missing file is the empty state, an unreadable one
    /// is reported and replaced (every entry is replayable).
    pub fn load(&self) -> HostState {
        match std::fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes).unwrap_or_else(|e| {
                crate::log::log(format!(
                    "{} is unreadable ({e}); starting from an empty state",
                    self.path.display()
                ));
                HostState::default()
            }),
            Err(e) if e.kind() == io::ErrorKind::NotFound => HostState::default(),
            Err(e) => {
                crate::log::log(format!(
                    "reading {}: {e}; starting from an empty state",
                    self.path.display()
                ));
                HostState::default()
            }
        }
    }

    /// Writes through a temporary file (mode 0600: it holds the outbox,
    /// replies included), fsyncs it, renames it into place, then fsyncs the
    /// directory so the rename itself survives a power loss.
    pub fn save(&self, state: &HostState) -> io::Result<()> {
        let tmp = self
            .path
            .with_extension(format!("json.{}.tmp", std::process::id()));
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(&serde_json::to_vec(state).map_err(io::Error::other)?)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        std::fs::rename(&tmp, &self.path)?;
        if let Some(dir) = self.path.parent() {
            std::fs::File::open(dir)?.sync_all()?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_conversation::Part;

    #[test]
    fn state_round_trips() {
        let dir = tempfile::tempdir().unwrap();
        let file = StateFile::new(&dir.path().join("host.json"));
        assert_eq!(file.load(), HostState::default());
        let mut state = HostState {
            conversation: Some("conv_a".into()),
            logged_seq: 4,
            ..Default::default()
        };
        state.outbox.push(OutboxEntry {
            conversation: "conv_a".into(),
            idempotency_key: "turn:optchat:3".into(),
            op: Op::MessageSend {
                client_msg_id: "turn:optchat:3".into(),
                parts: vec![Part::Text {
                    text: "hi".into(),
                    runs: None,
                }],
                reply_to: None,
            },
            rate_retried: false,
            not_before: None,
        });
        file.save(&state).unwrap();
        assert_eq!(file.load(), state);
        std::fs::write(dir.path().join("host.json"), b"{torn").unwrap();
        assert_eq!(file.load(), HostState::default());
    }
}
