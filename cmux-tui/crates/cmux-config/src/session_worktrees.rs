//! `agentPane.sessionWorktrees`: where the worktrees cmux makes for local
//! chats and forks (`git.worktree.create`) live. Off, the default, keeps
//! them where they always were, `~/.cmux/worktrees/<project>/<name>`;
//! Shared names that folder outright; Project keeps them inside the
//! project, at `<project>/.claude/worktrees/<name>`, where Claude Code keeps
//! its own.

use serde_json::Value;

/// The setting's dotted key.
pub const KEY: &str = "agentPane.sessionWorktrees";

/// The project-relative folder [`SessionWorktrees::Project`] keeps worktrees in.
pub const PROJECT_FOLDER: [&str; 2] = [".claude", "worktrees"];

/// The setting's value. Anything else, or no value, reads as [`Self::Off`].
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SessionWorktrees {
    #[default]
    Off,
    Shared,
    Project,
}

impl SessionWorktrees {
    /// The value a stored setting names; [`Self::Off`] for none or one
    /// this version does not know.
    pub fn parse(value: Option<&Value>) -> Self {
        match value.and_then(Value::as_str) {
            Some("shared") => Self::Shared,
            Some("project") => Self::Project,
            _ => Self::Off,
        }
    }

    /// Whether worktrees go inside the project instead of `~/.cmux/worktrees`.
    pub fn in_project(self) -> bool {
        self == Self::Project
    }
}
