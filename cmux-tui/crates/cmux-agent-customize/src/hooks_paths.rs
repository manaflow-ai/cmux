//! Where Claude Code and Codex keep their hooks, resolved the way each CLI
//! resolves it. Every edit of an agent's file goes through [`crate::write::Store`],
//! the one the settings part uses, so a hooks edit and a settings edit of the same
//! file take the same lock and leave the same backups.

use std::ffi::OsString;
use std::path::{Path, PathBuf};

use anyhow::Context as _;

use crate::write::Store;

/// cmux's own folder for the Claude Code hooks it turned off (the disabled-hook
/// store). Overridable for tests and side copies.
pub const STORE_ENV: &str = "CMUX_AGENT_CUSTOMIZE_HOME";

/// The config roots for one listing or edit.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AgentPaths {
    /// `$CLAUDE_CONFIG_DIR`, else `~/.claude`.
    pub claude_dir: PathBuf,
    /// `$CODEX_HOME`, else `~/.codex`.
    pub codex_home: PathBuf,
    /// Codex canonicalizes `CODEX_HOME` when it comes from the environment
    /// (codex-rs/utils/home-dir `find_codex_home`), and its hook-state keys
    /// embed the resolved path.
    pub codex_home_from_env: bool,
    /// The project folder whose `.claude/` and `.codex/` are read.
    pub project: Option<PathBuf>,
    /// `CLAUDE_CODE_PLUGIN_DIRS` folders.
    pub claude_plugin_dirs: Vec<PathBuf>,
    /// cmux's store (`$CMUX_AGENT_CUSTOMIZE_HOME`, else `~/.cmux/agent-customize`).
    pub store_dir: PathBuf,
    /// The edit locks and backups of every file a hooks edit writes: the settings part's
    /// [`state_dir`], cmux's private folder outside every project.
    pub edits: Store,
}

impl AgentPaths {
    /// Roots from this process's environment.
    pub fn from_env(project: Option<PathBuf>) -> anyhow::Result<Self> {
        let home = std::env::var_os("HOME").map(PathBuf::from).context("HOME is not set")?;
        let mut paths = Self::from_vars(&home, project, |name| std::env::var_os(name));
        paths.edits = Store::new(state_dir(&home, |name| std::env::var_os(name)));
        Ok(paths)
    }

    /// Roots from `home` and a variable lookup (tests pass their own).
    pub fn from_vars(
        home: &Path,
        project: Option<PathBuf>,
        var: impl Fn(&str) -> Option<OsString>,
    ) -> Self {
        let set = |name: &str| var(name).filter(|value| !value.is_empty()).map(PathBuf::from);
        let codex_env = set("CODEX_HOME");
        Self {
            claude_dir: set("CLAUDE_CONFIG_DIR").unwrap_or_else(|| home.join(".claude")),
            codex_home_from_env: codex_env.is_some(),
            codex_home: codex_env.unwrap_or_else(|| home.join(".codex")),
            project,
            claude_plugin_dirs: var("CLAUDE_CODE_PLUGIN_DIRS")
                .map(|value| {
                    std::env::split_paths(&value).filter(|path| path.is_absolute()).collect()
                })
                .unwrap_or_default(),
            store_dir: set(STORE_ENV).unwrap_or_else(|| home.join(".cmux/agent-customize")),
            edits: Store::new(home.join(".local/state/cmux-tui/agent-config")),
        }
    }

    /// `path` as it appears in Codex's `hooks.state` keys.
    pub fn codex_state_key_path(&self, path: &Path) -> PathBuf {
        if path.starts_with(&self.codex_home) {
            cmux_tui_hooks::codex_hook_state_key_path(path, self.codex_home_from_env)
        } else {
            path.to_path_buf()
        }
    }
}

/// cmux's private folder for the backups and edit locks of the agent files it edits, outside
/// every project: `~/Library/Application Support/cmux-tui/agent-config` on macOS,
/// `$XDG_STATE_HOME/cmux-tui/agent-config` (`~/.local/state/...`) elsewhere,
/// `%LOCALAPPDATA%\cmux-tui\agent-config` on Windows.
pub fn state_dir(home: &Path, var: impl Fn(&str) -> Option<OsString>) -> PathBuf {
    let set = |name: &str| var(name).filter(|value| !value.is_empty()).map(PathBuf::from);
    let state = if cfg!(target_os = "macos") {
        home.join("Library/Application Support")
    } else if cfg!(windows) {
        set("LOCALAPPDATA").unwrap_or_else(|| home.join("AppData/Local"))
    } else {
        set("XDG_STATE_HOME")
            .filter(|dir| dir.is_absolute())
            .unwrap_or_else(|| home.join(".local/state"))
    };
    state.join("cmux-tui").join("agent-config")
}
