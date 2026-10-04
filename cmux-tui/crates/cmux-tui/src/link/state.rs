//! The link's state directory: its WireGuard key, its config and its paired
//! peers. Default `<daemon state dir>/link` (`workspace_state_dir()`), mode
//! 0700; the registration file goes in its parent, the daemon state dir.

use std::io;
use std::path::{Path, PathBuf};

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

/// The UDP port the link binds by default (transport.md 3.1: 4101 is the
/// outer WireGuard port of cmux endpoints).
pub(super) const DEFAULT_PORT: u16 = 4101;

/// The inner MTU of a direct session (transport.md 3.1).
pub(super) const DIRECT_MTU: u16 = 1380;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct LinkConfig {
    /// This install's id; the overlay address derives from it.
    pub install: String,
    /// The UDP port the link binds on every interface.
    pub port: u16,
}

pub(super) struct LinkState {
    dir: PathBuf,
}

impl LinkState {
    /// The state directory `dir`, or the default; created with mode 0700.
    pub(super) fn open(dir: Option<PathBuf>) -> io::Result<Self> {
        let dir = match dir {
            Some(dir) => dir,
            None => cmux_tui_core::platform::workspace_state_dir()
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no state directory"))?
                .join("link"),
        };
        create_private_dir(&dir)?;
        Ok(Self { dir })
    }

    pub(super) fn dir(&self) -> &Path {
        &self.dir
    }

    /// Where `link.json` goes: the daemon state dir, the parent of the
    /// link's own directory.
    pub(super) fn registration_dir(&self) -> PathBuf {
        self.dir.parent().map(Path::to_path_buf).unwrap_or_else(|| self.dir.clone())
    }

    pub(super) fn peers_path(&self) -> PathBuf {
        self.dir.join("peers.json")
    }

    fn config_path(&self) -> PathBuf {
        self.dir.join("config.json")
    }

    fn key_path(&self) -> PathBuf {
        self.dir.join("private.key")
    }

    pub(super) fn config(&self) -> io::Result<LinkConfig> {
        let text = std::fs::read_to_string(self.config_path())?;
        let config: LinkConfig = serde_json::from_str(&text)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        if !cmux_link::stamp::valid_id(&config.install) {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "invalid install id"));
        }
        Ok(config)
    }

    /// Write the config and create the private key when there is none (an
    /// existing key is kept, so re-running init never breaks pairings).
    pub(super) fn init(&self, config: &LinkConfig) -> io::Result<()> {
        if !cmux_link::stamp::valid_id(&config.install) {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid install id"));
        }
        if !self.key_path().exists() {
            let mut private = Zeroizing::new([0u8; 32]);
            getrandom::fill(&mut *private).map_err(io::Error::other)?;
            let secret = x25519_dalek::StaticSecret::from(*private);
            let encoded = Zeroizing::new(STANDARD.encode(secret.to_bytes()));
            write_private(&self.key_path(), encoded.as_bytes())?;
        }
        let text = serde_json::to_vec_pretty(config)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        write_private(&self.config_path(), &text)
    }

    pub(super) fn private_key(&self) -> io::Result<Zeroizing<[u8; 32]>> {
        let text = Zeroizing::new(std::fs::read_to_string(self.key_path())?);
        let bytes = Zeroizing::new(
            STANDARD
                .decode(text.trim())
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?,
        );
        let key: [u8; 32] = bytes
            .as_slice()
            .try_into()
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "key is not 32 bytes"))?;
        Ok(Zeroizing::new(key))
    }
}

/// The WireGuard public key of `private`.
pub(super) fn public_key(private: &[u8; 32]) -> [u8; 32] {
    let secret = x25519_dalek::StaticSecret::from(*private);
    x25519_dalek::PublicKey::from(&secret).to_bytes()
}

/// The link's local socket: `<runtime dir>/link.sock`, or the short
/// fallback runtime dir when that path would not fit `sun_path`.
pub(super) fn socket_path() -> PathBuf {
    let preferred = cmux_tui_core::platform::runtime_dir().join("link.sock");
    if cmux_unix_socket::fits(&preferred) {
        return preferred;
    }
    cmux_tui_core::platform::fallback_runtime_dir().join("link.sock")
}

fn create_private_dir(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}

fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let temporary = path.with_extension("tmp");
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&temporary)?;
    file.write_all(bytes)?;
    file.sync_all()?;
    std::fs::rename(&temporary, path)
}
