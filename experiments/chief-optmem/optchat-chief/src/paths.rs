//! Where the Chief keeps its files under `$MUX_HOME`. The host lock is the one
//! `mux/host` and the P1 Rust Chief take, so the three never run together;
//! everything else lives under `optchat/`, apart from the files of `mux/host`.

use std::io;
use std::path::{Path, PathBuf};

/// `$MUX_HOME`, else `~/.cmux/mux` (tagged builds pass their own).
pub fn mux_home() -> PathBuf {
    if let Some(home) = crate::cli::env("MUX_HOME") {
        return PathBuf::from(home);
    }
    let user = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| "/".into());
    user.join(".cmux").join("mux")
}

/// A short id for a `MUX_HOME` (FNV-1a of its path, 8 hex digits). Two
/// homes sharing one acpmux daemon tag their children and name their acpmux
/// preset with it, so neither takes the other's.
pub fn home_id(home: &Path) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for b in home.as_os_str().as_encoded_bytes() {
        hash ^= u32::from(*b);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    format!("{hash:08x}")
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Paths {
    pub home: PathBuf,
    /// `$MUX_HOME/state/host.lock`, shared with mux/host (chief-mac.md section 2).
    pub host_lock: PathBuf,
    /// `$MUX_HOME/optchat`.
    pub root: PathBuf,
    /// The OptChat memory (section 2): `main/`, `tree/`, its own `lock`.
    pub chat: PathBuf,
    /// The constant working directory of every turn session (section 7.2:
    /// a constant cwd keeps the harness prompt and tools byte-identical).
    pub session: PathBuf,
    /// The host's durable state (outbox, cursor, children).
    pub state: PathBuf,
    /// The socket the `mcp` subcommand reaches the live memory on.
    pub tools_socket: PathBuf,
    /// Launchers on the turn session's PATH (`chief`).
    pub bin: PathBuf,
    /// The turn sessions' own Claude Code configuration (`CLAUDE_CONFIG_DIR`):
    /// no user CLAUDE.md, settings, hooks or auto-memory reach a turn.
    pub claude_config: PathBuf,
    /// The compactor sessions' own Claude Code configuration
    /// (`CLAUDE_CONFIG_DIR` of their required preset), separate from the
    /// turn sessions' so nothing a turn writes reaches a compactor call.
    pub compactor_config: PathBuf,
    /// The user's own instructions file, the end of every turn's system
    /// prompt (section 7.2); read once per host start.
    pub instructions: PathBuf,
}

impl Paths {
    pub fn new(home: &Path) -> Paths {
        let root = home.join("optchat");
        Paths {
            home: home.to_owned(),
            host_lock: home.join("state").join("host.lock"),
            chat: root.join("chat"),
            session: root.join("session"),
            state: root.join("host.json"),
            tools_socket: root.join("tools.sock"),
            bin: root.join("bin"),
            claude_config: root.join("claude"),
            compactor_config: root.join("compactor-claude"),
            instructions: root.join("AGENTS.md"),
            root,
        }
    }

    /// Creates every directory the host writes into. `optchat/` is 0700: the
    /// memory holds everything the user pasted, and a Mac mini often has
    /// other accounts.
    pub fn create(&self) -> io::Result<()> {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        std::fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.root)?;
        std::fs::set_permissions(&self.root, std::fs::Permissions::from_mode(0o700))?;
        for dir in [&self.chat, &self.session, &self.bin, &self.claude_config] {
            std::fs::create_dir_all(dir)?;
        }
        if let Some(parent) = self.host_lock.parent() {
            std::fs::create_dir_all(parent)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn the_optchat_directory_is_private_to_the_user() {
        let dir = tempfile::tempdir().unwrap();
        let paths = Paths::new(dir.path());
        paths.create().unwrap();
        let mode = std::fs::metadata(&paths.root).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o700);
    }
}
