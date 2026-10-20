//! What surrounds a hit's target (its workspace, group, title, folder, git
//! branch, agent), so a query word can match the place as well as the text:
//! "cmux-next migration" finds a migration error printed in a terminal of
//! the cmux-next workspace.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

use crate::fold::fold;

/// The context of one target (a terminal, tab, pane, chat session, Chief or
/// workspace). Every field is optional (empty).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct TargetContext {
    /// The workspace's id, for the same-workspace boost.
    #[serde(default)]
    pub workspace_id: String,
    #[serde(default)]
    pub workspace: String,
    /// The sidebar group the workspace is in.
    #[serde(default)]
    pub group: String,
    /// The tab or pane title (`zsh`, `claude`, a renamed tab).
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub cwd: String,
    #[serde(default)]
    pub branch: String,
    /// The agent or harness (`Claude Code`, `Codex`, a Chief's name).
    #[serde(default)]
    pub agent: String,
}

pub(crate) struct ContextEntry {
    pub context: TargetContext,
    /// Every field folded, joined by `\n` (no word spans two fields).
    pub folded: Vec<u8>,
    pub mask: u64,
}

impl ContextEntry {
    pub fn new(context: TargetContext) -> Self {
        let joined = [
            &context.workspace,
            &context.group,
            &context.title,
            &context.cwd,
            &context.branch,
            &context.agent,
        ]
        .iter()
        .filter(|field| !field.is_empty())
        .map(|field| fold(field))
        .collect::<Vec<_>>()
        .join("\n");
        let folded = joined.into_bytes();
        let mask = crate::names::letters(&folded);
        Self { context, folded, mask }
    }

    pub fn contains(&self, word: &[u8]) -> bool {
        memchr::memmem::find(&self.folded, word).is_some()
    }
}

/// Contexts by target.
#[derive(Default)]
pub(crate) struct Contexts {
    pub entries: HashMap<String, ContextEntry>,
}

impl Contexts {
    pub fn get(&self, target: &str) -> Option<&ContextEntry> {
        self.entries.get(target)
    }
}
