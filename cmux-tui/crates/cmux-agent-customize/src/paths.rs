//! Where Claude Code and Codex keep their config, resolved the way each CLI
//! resolves it, and the one atomic, backed-up write every edit goes through.

use std::ffi::OsString;
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Context as _;

/// cmux's own folder for agent-customization state (the Claude disabled-hook
/// store, backups). Overridable for tests and side copies.
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
}

impl AgentPaths {
    /// Roots from this process's environment.
    pub fn from_env(project: Option<PathBuf>) -> anyhow::Result<Self> {
        let home = std::env::var_os("HOME").map(PathBuf::from).context("HOME is not set")?;
        Ok(Self::from_vars(&home, project, |name| std::env::var_os(name)))
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

/// Writes `bytes` to `path` through a temp file and rename, keeping the
/// file's mode, after copying the prior file to `<store>/backups/`.
pub fn write_with_backup(store: &Path, path: &Path, bytes: &[u8]) -> anyhow::Result<()> {
    let previous = fs::read(path).ok();
    if previous.as_deref() == Some(bytes) {
        return Ok(());
    }
    if let Some(previous) = &previous {
        let backups = store.join("backups");
        fs::create_dir_all(&backups).with_context(|| format!("creating {}", backups.display()))?;
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|since| since.as_millis())
            .unwrap_or(0);
        let flat: String = path
            .to_string_lossy()
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '-' { c } else { '_' })
            .collect();
        let backup = backups.join(format!("{stamp}-{}", flat.trim_start_matches('_')));
        fs::write(&backup, previous)
            .with_context(|| format!("backing up to {}", backup.display()))?;
        prune_backups(&backups, 50);
    }
    let parent = path.parent().context("the file has no folder")?;
    fs::create_dir_all(parent).with_context(|| format!("creating {}", parent.display()))?;
    let mode = file_mode(path);
    let temp = parent.join(format!(
        ".{}.cmux-{}.tmp",
        path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default(),
        std::process::id()
    ));
    let write = || -> anyhow::Result<()> {
        let mut file =
            fs::File::create(&temp).with_context(|| format!("creating {}", temp.display()))?;
        file.write_all(bytes)?;
        file.sync_all()?;
        set_mode(&temp, mode);
        fs::rename(&temp, path).with_context(|| format!("replacing {}", path.display()))?;
        Ok(())
    };
    let result = write();
    if result.is_err() {
        let _ = fs::remove_file(&temp);
    }
    result
}

/// Keeps the newest `keep` backups.
fn prune_backups(backups: &Path, keep: usize) {
    let Ok(entries) = fs::read_dir(backups) else { return };
    let mut names: Vec<_> = entries.filter_map(Result::ok).map(|entry| entry.path()).collect();
    if names.len() <= keep {
        return;
    }
    names.sort();
    for old in &names[..names.len() - keep] {
        let _ = fs::remove_file(old);
    }
}

#[cfg(unix)]
fn file_mode(path: &Path) -> Option<u32> {
    use std::os::unix::fs::PermissionsExt as _;
    fs::metadata(path).ok().map(|meta| meta.permissions().mode() & 0o7777)
}

#[cfg(not(unix))]
fn file_mode(_: &Path) -> Option<u32> {
    None
}

#[cfg(unix)]
fn set_mode(path: &Path, mode: Option<u32>) {
    use std::os::unix::fs::PermissionsExt as _;
    if let Some(mode) = mode {
        let _ = fs::set_permissions(path, fs::Permissions::from_mode(mode));
    }
}

#[cfg(not(unix))]
fn set_mode(_: &Path, _: Option<u32>) {}
