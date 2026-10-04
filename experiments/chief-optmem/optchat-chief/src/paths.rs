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
            root,
        }
    }

    /// Creates every directory the host writes into.
    pub fn create(&self) -> io::Result<()> {
        for dir in [&self.root, &self.chat, &self.session, &self.bin] {
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
