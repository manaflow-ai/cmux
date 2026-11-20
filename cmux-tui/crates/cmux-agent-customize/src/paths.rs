//! Where Claude Code and Codex keep their own configuration, resolved the way each CLI does.
//!
//! - Claude Code: `$CLAUDE_CONFIG_DIR`, else `~/.claude` (skills, commands, settings.json,
//!   plugins); `~/.claude.json` beside it; a project's `.claude/` and `.mcp.json`.
//! - Codex: `$CODEX_HOME`, else `~/.codex` (config.toml, skills, plugins); `~/.agents/skills`;
//!   a project's `.codex/` and `.agents/`.

use std::path::{Path, PathBuf};

/// The homes one read or write resolves against. Tests build one over a temporary folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Homes {
    /// The person's home folder.
    pub home: PathBuf,
    /// Claude Code's config folder (`$CLAUDE_CONFIG_DIR` or `~/.claude`).
    pub claude: PathBuf,
    /// Codex's home (`$CODEX_HOME` or `~/.codex`).
    pub codex: PathBuf,
    /// cmux's private folder for the backups and edit locks of the files it edits, outside every
    /// project ([`crate::write::Store`]): `~/Library/Application Support/cmux-tui/agent-config` on
    /// macOS, `$XDG_STATE_HOME/cmux-tui/agent-config` (`~/.local/state/...`) elsewhere,
    /// `%LOCALAPPDATA%\cmux-tui\agent-config` on Windows.
    pub state: PathBuf,
}

impl Homes {
    /// The homes this process's environment names; `None` without a home folder.
    pub fn from_env() -> Option<Self> {
        let var = |name: &str| std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from);
        let home = var("HOME")?;
        let state = if cfg!(target_os = "macos") {
            home.join("Library/Application Support")
        } else if cfg!(windows) {
            var("LOCALAPPDATA").unwrap_or_else(|| home.join("AppData/Local"))
        } else {
            var("XDG_STATE_HOME")
                .filter(|dir| dir.is_absolute())
                .unwrap_or_else(|| home.join(".local/state"))
        };
        Some(Self {
            claude: var("CLAUDE_CONFIG_DIR").unwrap_or_else(|| home.join(".claude")),
            codex: var("CODEX_HOME").unwrap_or_else(|| home.join(".codex")),
            state: state.join("cmux-tui").join("agent-config"),
            home,
        })
    }

    /// Homes under one folder, as both CLIs default them (`<home>/.claude`, `<home>/.codex`),
    /// with cmux's private folder at `<home>/.local/state/cmux-tui/agent-config`.
    pub fn under(home: impl Into<PathBuf>) -> Self {
        let home = home.into();
        Self {
            claude: home.join(".claude"),
            codex: home.join(".codex"),
            state: home.join(".local/state/cmux-tui/agent-config"),
            home,
        }
    }

    /// The backups and edit locks of the files cmux edits.
    pub fn store(&self) -> crate::write::Store {
        crate::write::Store::new(&self.state)
    }

    /// `~/.claude/settings.json`.
    pub fn claude_settings(&self) -> PathBuf {
        self.claude.join("settings.json")
    }

    /// `~/.codex/config.toml`.
    pub fn codex_config(&self) -> PathBuf {
        self.codex.join("config.toml")
    }

    /// `~/.agents/skills`, Codex's user-installed skills.
    pub fn agents_skills(&self) -> PathBuf {
        self.home.join(".agents/skills")
    }
}

/// The folders from `cwd` up to its project root, innermost first: the nearest ancestor holding
/// `.git` (both CLIs' default project marker), else up to (not including) `home`, else `cwd` alone.
pub fn project_dirs(cwd: &Path, home: &Path) -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    for dir in cwd.ancestors() {
        if dir == home {
            break;
        }
        dirs.push(dir.to_path_buf());
        if dir.join(".git").exists() {
            return dirs;
        }
    }
    // No project root: Claude Code and Codex take the folder itself.
    dirs.truncate(1);
    if dirs.is_empty() && cwd != home {
        dirs.push(cwd.to_path_buf());
    }
    dirs
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn project_dirs_stop_at_the_git_root() {
        let root = tempfile::tempdir().unwrap();
        let repo = root.path().join("repo");
        let deep = repo.join("a/b");
        std::fs::create_dir_all(&deep).unwrap();
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        assert_eq!(
            project_dirs(&deep, root.path()),
            vec![deep.clone(), repo.join("a"), repo.clone()]
        );
        // Outside any repo: the folder alone. The temp root is the home so a `.git` above the
        // machine's temp folder (a stray /tmp/.git) cannot count.
        let loose = root.path().join("loose/x");
        std::fs::create_dir_all(&loose).unwrap();
        assert_eq!(project_dirs(&loose, root.path()), vec![loose.clone()]);
        // The home folder itself is the user scope, never a project.
        assert!(project_dirs(root.path(), root.path()).is_empty());
    }
}
