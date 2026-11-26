//! Where Claude Code and Codex keep the person's setup, as each agent finds it.
//!
//! - Claude Code: its home is `$CLAUDE_CONFIG_DIR`, else `~/.claude`; its global state file is
//!   `$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json` (beside the home, not in it). A
//!   project's shared servers are `.mcp.json` in the project folder or a parent; its own settings
//!   are `.claude/settings.json` and `.claude/settings.local.json`.
//! - Codex: its home is `$CODEX_HOME`, else `~/.codex`, with `config.toml` in it; a project adds
//!   `.codex/config.toml` in the project folder or a parent.
//!
//! [`Homes`] and [`project_dirs`] serve the skills reader; [`Paths`] and [`project_chain`] the MCP
//! servers reader.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::write::Store;

/// The files of one person's setup, from one environment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Paths {
    pub home: PathBuf,
    /// Claude Code's home (`$CLAUDE_CONFIG_DIR` or `~/.claude`).
    pub claude_dir: PathBuf,
    /// Claude Code's global state, which holds user and local MCP servers (`~/.claude.json`).
    pub claude_json: PathBuf,
    /// Codex's home (`$CODEX_HOME` or `~/.codex`).
    pub codex_home: PathBuf,
}

impl Paths {
    /// The files for `env` (the process environment, or a test's): `HOME`, `CLAUDE_CONFIG_DIR`,
    /// `CODEX_HOME`. None without a home.
    pub fn from_env(env: &BTreeMap<String, String>) -> Option<Self> {
        let set =
            |key: &str| env.get(key).filter(|value| !value.trim().is_empty()).map(PathBuf::from);
        let home = set("HOME")?;
        let (claude_dir, claude_json) = match set("CLAUDE_CONFIG_DIR") {
            Some(dir) => (dir.clone(), dir.join(".claude.json")),
            None => (home.join(".claude"), home.join(".claude.json")),
        };
        let codex_home = set("CODEX_HOME").unwrap_or_else(|| home.join(".codex"));
        Some(Self { home, claude_dir, claude_json, codex_home })
    }

    /// The process's own environment.
    pub fn current() -> Option<Self> {
        Self::from_env(&std::env::vars().collect())
    }

    /// Codex's user `config.toml`.
    pub fn codex_config(&self) -> PathBuf {
        self.codex_home.join("config.toml")
    }

    /// Codex's plugin cache (`<marketplace>/<plugin>/<version>/.mcp.json`).
    pub fn codex_plugin_cache(&self) -> PathBuf {
        self.codex_home.join("plugins").join("cache")
    }
}

/// `project` and each parent up to and including the first one that holds a repository (`.git`),
/// or up to the home folder, closest first: the folders whose `.mcp.json` or `.codex/config.toml`
/// an agent started in `project` reads. A folder outside home stops at its repository or the root.
pub fn project_chain(project: &Path, home: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for folder in project.ancestors() {
        // Home's own `.codex` is the user layer, not a project's; home's `.mcp.json` counts as
        // a project's only when home is the project itself.
        if folder == home && folder != project {
            break;
        }
        out.push(folder.to_path_buf());
        if folder.join(".git").exists() {
            break;
        }
    }
    out
}

/// The homes one read or write resolves against. Tests build one over a temporary folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Homes {
    /// The person's home folder.
    pub home: PathBuf,
    /// Claude Code's config folder (`$CLAUDE_CONFIG_DIR` or `~/.claude`).
    pub claude: PathBuf,
    /// Codex's home (`$CODEX_HOME` or `~/.codex`).
    pub codex: PathBuf,
    /// The edit locks and backups of every file a skills switch writes: the private folder
    /// outside every project the hooks and settings parts use ([`crate::hooks_paths::state_dir`]).
    pub edits: Store,
    /// cmux's own saved prompts, which the composer's `/` menu lists in every chat whatever its
    /// agent ([`cmux_commands_dir`]).
    pub cmux_commands: PathBuf,
}

impl Homes {
    /// The homes this process's environment names; `None` without a home folder.
    pub fn from_env() -> Option<Self> {
        let var = |name: &str| std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from);
        let home = var("HOME")?;
        Some(Self {
            claude: var("CLAUDE_CONFIG_DIR").unwrap_or_else(|| home.join(".claude")),
            codex: var("CODEX_HOME").unwrap_or_else(|| home.join(".codex")),
            edits: Store::new(crate::hooks_paths::state_dir(&home, |name| std::env::var_os(name))),
            cmux_commands: cmux_commands_dir(&home, |name| std::env::var_os(name)),
            home,
        })
    }

    /// Homes under one folder, as both CLIs default them (`<home>/.claude`, `<home>/.codex`), with
    /// cmux's edit store inside it too, so a test never touches the real one.
    pub fn under(home: impl Into<PathBuf>) -> Self {
        let home = home.into();
        Self {
            claude: home.join(".claude"),
            codex: home.join(".codex"),
            edits: Store::new(home.join(".local/state/cmux-tui/agent-config")),
            cmux_commands: cmux_commands_dir(&home, |_| None),
            home,
        }
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

/// cmux's saved prompts folder: `$CMUX_COMMANDS_DIR`, else `$XDG_CONFIG_HOME/cmux/commands`, else
/// `~/.config/cmux/commands`, beside `~/.config/cmux/skills` (`cmux-next` instead of `cmux` on
/// macOS, `cmux_config::NEXT_DIR`). One `NAME.md` a prompt: its
/// frontmatter `description`, then the text the `/NAME` pick writes into the draft.
pub fn cmux_commands_dir(home: &Path, var: impl Fn(&str) -> Option<std::ffi::OsString>) -> PathBuf {
    let set = |name: &str| var(name).filter(|value| !value.is_empty()).map(PathBuf::from);
    if let Some(dir) = set("CMUX_COMMANDS_DIR") {
        return dir;
    }
    set("XDG_CONFIG_HOME")
        .unwrap_or_else(|| home.join(".config"))
        .join(cmux_config::NEXT_DIR)
        .join("commands")
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

    fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    #[test]
    fn defaults_and_overrides() {
        let p = Paths::from_env(&env(&[("HOME", "/h")])).unwrap();
        assert_eq!(p.claude_json, PathBuf::from("/h/.claude.json"));
        assert_eq!(p.claude_dir, PathBuf::from("/h/.claude"));
        assert_eq!(p.codex_config(), PathBuf::from("/h/.codex/config.toml"));
        let p = Paths::from_env(&env(&[
            ("HOME", "/h"),
            ("CLAUDE_CONFIG_DIR", "/c"),
            ("CODEX_HOME", "/x"),
        ]))
        .unwrap();
        assert_eq!(p.claude_json, PathBuf::from("/c/.claude.json"));
        assert_eq!(p.codex_config(), PathBuf::from("/x/config.toml"));
        assert!(Paths::from_env(&env(&[])).is_none());
    }

    #[test]
    fn chain_stops_at_repo_or_home() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let repo = home.join("repo");
        let deep = repo.join("a").join("b");
        std::fs::create_dir_all(&deep).unwrap();
        std::fs::create_dir_all(repo.join(".git")).unwrap();
        assert_eq!(project_chain(&deep, &home), vec![deep.clone(), repo.join("a"), repo.clone()]);
        let loose = home.join("loose");
        std::fs::create_dir_all(&loose).unwrap();
        assert_eq!(project_chain(&loose, &home), vec![loose.clone()]);
        assert_eq!(project_chain(&home, &home).first(), Some(&home));
    }

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
        // Outside any repo: the folder alone.
        let loose = root.path().join("loose/x");
        std::fs::create_dir_all(&loose).unwrap();
        assert_eq!(project_dirs(&loose, Path::new("/nonexistent-home")), vec![loose.clone()]);
        // The home folder itself is the user scope, never a project.
        assert!(project_dirs(root.path(), root.path()).is_empty());
    }
}
