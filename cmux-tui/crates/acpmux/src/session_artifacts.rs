//! What a chat is made of, per agent store, declared once: the mover (`native.rs`), the guarded
//! receive (`hub/transfer_guard.rs`) and the session-move matrix
//! (`tests/transfer_cli/move_matrix.rs`) read this table instead of each re-guessing what a
//! session holds.
//!
//! Every chat carries acpmux's own files whatever its agent ([`BUNDLE_ARTIFACTS`]); a chat
//! whose agent keeps its own store also carries that store's files ([`StoreRow::native`]).

/// acpmux's own part of every moved chat, whatever its agent: the history (events, with the
/// model, effort, mode and allow rules it records), the queue, the draft and composer, and the
/// images its prompts carry.
pub const BUNDLE_ARTIFACTS: &[&str] = &["history", "queue", "draft", "composer", "images"];

/// One kind of file an agent keeps for a session, as it travels in a bundle
/// (`native/<label>/<path under home>`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NativeFamily {
    /// The bundle label: `native/<label>/...`.
    pub label: &'static str,
    /// The folder under the home folder the agent keeps these files in; empty for a session
    /// that travels as an export rather than as a file of the home folder.
    pub root: &'static str,
    /// What the file is.
    pub what: &'static str,
}

/// One agent store: the session files it keeps.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StoreRow {
    /// The store (`native::store_kind`): the agent family whose files these are.
    pub store: &'static str,
    /// Its files a moved chat carries, in the order the mover lists them.
    pub native: &'static [NativeFamily],
}

impl StoreRow {
    /// Whether a remote (Web or app-driven) receive refuses to start this family's agent
    /// (`web_modes::REFUSED_FAMILIES`): the chat still moves, but its agent cannot start there
    /// as a remote launch.
    pub fn refused_on_web(&self) -> bool {
        crate::web_modes::REFUSED_FAMILIES.contains(&self.store)
    }

    /// The declared family labelled `label`.
    pub fn family(&self, label: &str) -> Option<&'static NativeFamily> {
        self.native.iter().find(|f| f.label == label)
    }
}

/// Claude Code's transcript of a session (`~/.claude/projects/<cwd>/<session>.jsonl`).
pub const CLAUDE_PROJECT: &str = "claude-project";
/// A Claude subagent's transcript (`<session>/subagents/*.jsonl` beside the session's).
pub const CLAUDE_SUBAGENT: &str = "claude-subagent";
/// Codex's rollout of a session (`~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl`).
pub const CODEX_ROLLOUT: &str = "codex-rollout";
/// pi's session file (`~/.pi/agent/sessions/--<cwd>--/<ts>_<id>.jsonl`).
pub const PI_SESSION: &str = "pi-session";
/// OpenCode's export of a session (`opencode export ID`): OpenCode keeps its sessions in a
/// SQLite database, so the session travels as its export and is imported on the target.
pub const OPENCODE_EXPORT: &str = "opencode-export";

/// Every agent store a moved chat carries files of. `cmux-harness` keeps its own state in the
/// bundle (`harness/`), so it has no native files.
pub const STORES: &[StoreRow] = &[
    StoreRow {
        store: "claude",
        native: &[
            NativeFamily { label: CLAUDE_PROJECT, root: ".claude/projects", what: "transcript" },
            NativeFamily {
                label: CLAUDE_SUBAGENT,
                root: ".claude/projects",
                what: "subagent transcripts",
            },
        ],
    },
    StoreRow {
        store: "codex",
        native: &[NativeFamily { label: CODEX_ROLLOUT, root: ".codex/sessions", what: "rollout" }],
    },
    StoreRow {
        store: "pi",
        native: &[NativeFamily { label: PI_SESSION, root: ".pi/agent/sessions", what: "session" }],
    },
    StoreRow {
        store: "opencode",
        native: &[NativeFamily { label: OPENCODE_EXPORT, root: "", what: "session export" }],
    },
    StoreRow { store: "cmux-harness", native: &[] },
];

/// The row of store `store`.
pub fn store(store: &str) -> Option<&'static StoreRow> {
    STORES.iter().find(|r| r.store == store)
}

/// The declared family labelled `label`, in any store.
pub fn native_family(label: &str) -> Option<&'static NativeFamily> {
    STORES.iter().find_map(|r| r.family(label))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_refused_family_has_a_row() {
        for family in crate::web_modes::REFUSED_FAMILIES {
            let row = store(family).unwrap_or_else(|| panic!("{family} has no store row"));
            assert!(row.refused_on_web(), "{family}");
        }
    }

    #[test]
    fn labels_are_unique() {
        let mut labels: Vec<_> = STORES.iter().flat_map(|r| r.native).map(|f| f.label).collect();
        let all = labels.len();
        labels.sort_unstable();
        labels.dedup();
        assert_eq!(labels.len(), all);
    }
}
