//! Chats are linked by path, never copied. Conductor ran Claude Code in each
//! workspace's folder, so its transcripts sit in Claude Code's own store
//! (`~/.claude/projects/<slug>/*.jsonl`), where cmux's project scan and
//! `claude --resume` already find them. Codex keeps its sessions by `cwd`
//! under `~/.codex/sessions`, which the same scan reads.

use std::path::{Path, PathBuf};

use serde::Serialize;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct ChatLink {
    /// The Claude Code project folder for the workspace's path.
    pub claude_folder: PathBuf,
    /// Transcripts in it.
    pub transcripts: usize,
}

/// Claude Code's folder name for `path`: every character that is not an
/// ASCII letter or digit becomes `-`.
pub fn claude_slug(path: &Path) -> String {
    path.to_string_lossy()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// The workspace's Claude Code transcripts, if any.
pub fn claude_chats(home: &Path, workspace: &Path) -> Option<ChatLink> {
    let folder = home.join(".claude").join("projects").join(claude_slug(workspace));
    let transcripts = std::fs::read_dir(&folder)
        .ok()?
        .filter_map(Result::ok)
        .filter(|entry| entry.path().extension().is_some_and(|ext| ext == "jsonl"))
        .count();
    (transcripts > 0).then_some(ChatLink { claude_folder: folder, transcripts })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_matches_claude_code() {
        assert_eq!(
            claude_slug(Path::new("/Users/me/conductor/workspaces/app/lima.v2")),
            "-Users-me-conductor-workspaces-app-lima-v2"
        );
    }
}
