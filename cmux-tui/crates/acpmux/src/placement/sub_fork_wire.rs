//! The wire between a parent and its fork's job (`sub_fork_run.rs`): the [`Job`] the parent
//! sends, the [`Frame`] lines the fork answers, and [`B64`], raw bytes as base64 text.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

use super::run_vm_tree::TreeDelta;

/// Raw bytes on the wire as a base64 string: output, environment and paths carried exactly,
/// whatever they hold (no UTF-8 needed).
#[derive(Debug, Clone, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct B64(pub Vec<u8>);

impl Serialize for B64 {
    fn serialize<S: serde::Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        use base64::Engine as _;
        s.serialize_str(&base64::engine::general_purpose::STANDARD.encode(&self.0))
    }
}

impl<'de> Deserialize<'de> for B64 {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        use base64::Engine as _;
        let text = String::deserialize(d)?;
        base64::engine::general_purpose::STANDARD
            .decode(text.as_bytes())
            .map(B64)
            .map_err(serde::de::Error::custom)
    }
}

/// What the fork is asked to do, one JSON object on the stream's input.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    /// The checkout on the fork (the parent's path: the fork is a copy of its disk).
    pub checkout: PathBuf,
    /// A patch that brings the fork's files to the parent's now ([`super::sub_fork::capture`]
    /// against the tree the fork was taken at), base64; empty for a fork taken for this task.
    #[serde(default)]
    pub sync_patch: String,
    pub prompt: String,
    /// The sub-agent's session name on the fork.
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    /// A shell command to run instead of a sub-agent (a run VM, RFD 0144 piece 3,
    /// [`super::run_vm`]): `sh -c` in `cwd`, its output streamed as [`Frame::Bytes`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    /// Where the command runs (the agent's working directory, inside `checkout`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<PathBuf>,
    /// The agent's `PATH` (a job from before `env`; `env` wins when it has one).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// The caller's environment, raw `KEY=VALUE`, all but what `run_vm_env::DROPPED` holds back.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub env: Vec<B64>,
    /// The names the caller had that were held back: each takes the fork's own value.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub env_held: Vec<String>,
    /// The caller's stdout and stderr are one file: the command's two go into one pipe on the
    /// fork too, so their order is the order it wrote them.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub merged: bool,
}

/// One line the fork writes back.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub enum Frame {
    /// The fork's checkout is synced and snapshotted: the patch's base on the fork.
    Base(String),
    /// A line of the sub-agent's output, as it came.
    Out(String),
    /// A command's output, raw, as it came: `fd` 1 (stdout) or 2 (stderr).
    Bytes { fd: u8, data: B64 },
    /// The end: the harness's exit code, the fork's changes (base64 `capture` patch), and what
    /// the patch cannot carry (empty folders, exact modes).
    Done {
        exit: i32,
        patch: String,
        #[serde(default, skip_serializing_if = "TreeDelta::is_empty")]
        tree: TreeDelta,
    },
    /// The job could not run (a sync patch that did not apply, no git, no harness).
    Error(String),
}

impl Frame {
    pub fn line(&self) -> String {
        let mut line = serde_json::to_string(self).unwrap_or_default();
        line.push('\n');
        line
    }
}
