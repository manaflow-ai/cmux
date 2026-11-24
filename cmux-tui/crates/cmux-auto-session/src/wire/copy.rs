//! The chat's copy in the Cloud: its events and its snapshot manifest.

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::Holder;

/// One log record of the chat (what `acpmux.transfer.v2` carries), at its place in the log.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SeqRecord {
    /// From 1, with no gap.
    pub seq: u64,
    pub record: Value,
}

/// `POST /:id/events`: at most 256 events and 1 MiB.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventsAppend {
    pub holder: Holder,
    pub epoch: u64,
    pub events: Vec<SeqRecord>,
}

/// `{lastSeq}`: the last seq the store has after an append.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventsAppended {
    pub last_seq: u64,
}

/// `GET /:id/events`: the events after a seq, in order.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventsPage {
    pub events: Vec<SeqRecord>,
    pub last_seq: u64,
}

/// What a new holder needs besides the events. A snapshot is whole or absent: the store accepts
/// a manifest only when every chunk it names is stored.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    /// [`crate::consts::MANIFEST_VERSION`].
    pub v: u32,
    /// When it was taken (epoch ms).
    pub at: u64,
    /// The last event the snapshot includes.
    pub last_seq: u64,
    pub harness: String,
    pub harness_session_id: String,
    pub cwd: Cwd,
    /// The prompts waiting behind the turn.
    #[serde(default)]
    pub queue: Vec<QueuedPrompt>,
    /// What the person had typed and not sent.
    #[serde(default)]
    pub draft: String,
    /// The turn that was running; a takeover runs it again from its last user message.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open_turn: Option<OpenTurn>,
    /// The agent's own session files (Claude Code's project file, Codex's rollout), so the new
    /// holder's agent resumes `harness_session_id` with its whole memory. Empty in a manifest
    /// from a build that did not carry them, and for an agent that keeps none.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub native: Vec<NativeFile>,
}

impl Manifest {
    /// Every chunk the manifest names, in order: the folder's, then the agent's files'.
    pub fn chunks(&self) -> impl Iterator<Item = &str> {
        let native = self.native.iter().flat_map(|file| file.chunks.iter().map(String::as_str));
        self.cwd.chunks().chain(native)
    }
}

/// One file of the agent's own session store, as a manual move carries it
/// (`acpmux.bundle.v1`'s `native` list).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NativeFile {
    /// Which store the file is of: `claude-project`, `codex-rollout`, `pi-session`,
    /// `opencode-export`, `cmux-harness`.
    pub label: String,
    /// Where the file sits in a moved chat's bundle, under its `native` folder (its `harness`
    /// folder for `cmux-harness`). The holder that imports it works out where its own agent
    /// looks.
    pub path: String,
    /// The file's chunks, in order. None: the file is empty.
    pub chunks: Vec<String>,
}

/// The chat's folder, as chunk lists.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Cwd {
    /// A repository (`session_move_carry`'s form): the base the remote already has, a bundle of
    /// local commits past it, and one binary patch of uncommitted work.
    Git { remote: String, branch: String, base: String, bundle: Vec<String>, patch: Vec<String> },
    /// A folder that is no repository: one tar.
    Folder { tar: Vec<String> },
}

impl Cwd {
    /// Every chunk the folder's lists name, in order.
    pub fn chunks(&self) -> impl Iterator<Item = &str> {
        let (first, second): (&[String], &[String]) = match self {
            Cwd::Git { bundle, patch, .. } => (bundle.as_slice(), patch.as_slice()),
            Cwd::Folder { tar } => (tar.as_slice(), &[]),
        };
        first.iter().chain(second).map(String::as_str)
    }
}

/// A prompt waiting in the chat's queue.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct QueuedPrompt {
    pub id: String,
    pub text: String,
}

/// The turn that was running when the snapshot was taken.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenTurn {
    pub turn_id: String,
    pub prompt_id: String,
    /// The tool call in flight, which the continuation names so no harness repeats it blindly.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<OpenTool>,
}

/// A tool call in flight.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct OpenTool {
    pub name: String,
    pub args: String,
}

/// `POST /:id/snapshot`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SnapshotPost {
    pub holder: Holder,
    pub epoch: u64,
    pub manifest: Manifest,
}

/// `{snapshot}`: the number the store gave an accepted snapshot.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnapshotPosted {
    pub snapshot: u64,
}

/// `GET /:id/snapshot`: the newest snapshot.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SnapshotAnswer {
    pub snapshot: u64,
    pub manifest: Manifest,
}
