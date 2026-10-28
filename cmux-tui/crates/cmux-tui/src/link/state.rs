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

/// The link mesh's inner MTU: 1200, the smaller of the two paths a session
/// may use (1380 direct, 1200 through the Freestyle tunnel; transport.md
/// 3.1), so a peer can move to the tunnel route without a size change.
pub(super) const LINK_MTU: u16 = 1200;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct LinkConfig {
    /// This install's id; the overlay address derives from it.
    pub install: String,
    /// The UDP port the link binds on every interface.
    pub port: u16,
    /// An explicitly selected private server enrollment; the key stays there.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_identity: Option<PathBuf>,
}

pub(super) struct LinkState {
    dir: PathBuf,
}

impl LinkState {
    /// The state directory `dir`, or the default; created with mode 0700.
    pub(super) fn open(dir: Option<PathBuf>) -> io::Result<Self> {
        let dir = match dir {
            Some(dir) => dir,
            None => default_dir()
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no state directory"))?,
        };
        create_private_dir(&dir)?;
        Ok(Self { dir })
    }

    pub(super) fn dir(&self) -> &Path {
        &self.dir
    }

    /// This link's local socket ([`socket_path_for`]).
    pub(super) fn socket_path(&self) -> PathBuf {
        socket_path_for(&self.dir)
    }

    /// Where a link that `cmux link ensure` started writes its output.
    pub(super) fn log_path(&self) -> PathBuf {
        self.dir.join("link.log")
    }

    /// Whether `init` has run (the config exists).
    pub(super) fn has_config(&self) -> bool {
        cmux_blocking::fs::metadata(self.config_path()).is_ok()
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
        let text = cmux_blocking::fs::read_to_string(self.config_path())?;
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
        if config.server_identity.is_some() {
            let _ = enrolled(config)?;
            if cmux_blocking::fs::symlink_metadata(self.key_path()).is_ok()
                || (self.has_config() && {
                    let old = self.config()?;
                    old.server_identity != config.server_identity || old.install != config.install
                })
            {
                return Err(io::Error::other("server_link.identity_conflict"));
            }
        } else if self.has_config() && self.config()?.server_identity.is_some() {
            return Err(io::Error::other("server_link.identity_conflict"));
        } else if cmux_blocking::fs::metadata(self.key_path()).is_err() {
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

    /// Moves this install's WireGuard key and paired peers aside under
    /// `old`'s name (`private.key.<old>`, `peers.<old>.json`) and puts back
    /// `new`'s archived pair when it has one. Nothing is deleted; a new
    /// install without an archive gets a new key (`init`) and no peers.
    pub(super) fn switch_install(&self, old: &str, new: &str) -> io::Result<()> {
        self.move_install(Some(old), Some(new))
    }

    /// Archives the current key and peers under `install` (`link archive`,
    /// after a sign-out) and removes the config, so no `ensure` without
    /// `--install` can start this link as that install again.
    pub(super) fn archive_install(&self, install: &str) -> io::Result<()> {
        self.move_install(Some(install), None)?;
        match cmux_blocking::fs::remove_file(self.config_path()) {
            Err(error) if error.kind() != io::ErrorKind::NotFound => Err(error),
            _ => Ok(()),
        }
    }

    /// Puts back `install`'s archived key and peers, if it has them (an
    /// install that signs in again on a state directory with no config).
    pub(super) fn restore_install(&self, install: &str) -> io::Result<()> {
        self.move_install(None, Some(install))
    }

    /// The moves of [`Self::switch_install`]: archive the current pair under
    /// `old`, then restore `new`'s. Both ids must be valid; an existing
    /// archive of `old` is never replaced; an archive of `new` is restored
    /// only when it is a regular file of this user that no one else may
    /// open. Everything is checked first; a failed move undoes the earlier
    /// ones.
    fn move_install(&self, old: Option<&str>, new: Option<&str>) -> io::Result<()> {
        let invalid = |why: &str| io::Error::new(io::ErrorKind::InvalidInput, why.to_owned());
        if old.into_iter().chain(new).any(|id| !cmux_link::stamp::valid_id(id)) {
            return Err(invalid("invalid install id"));
        }
        let archive = |stem: &str, ext: &str, id: &str| self.dir.join(format!("{stem}{id}{ext}"));
        let currents =
            [(self.key_path(), "private.key.", ""), (self.peers_path(), "peers.", ".json")];
        let mut moves: Vec<(PathBuf, PathBuf)> = Vec::new();
        for (current, stem, ext) in &currents {
            if let Some(old) = old {
                let to = archive(stem, ext, old);
                if cmux_blocking::fs::symlink_metadata(&to).is_ok() {
                    return Err(invalid(&format!("{} already exists", to.display())));
                }
                moves.push((current.clone(), to));
            }
            if let Some(new) = new {
                let from = archive(stem, ext, new);
                if cmux_blocking::fs::symlink_metadata(&from).is_ok() {
                    check_private_file(&from)?;
                    // A restore never overwrites a current file that was not
                    // archived first (no `old` moves it away here).
                    if old.is_none() && cmux_blocking::fs::symlink_metadata(current).is_ok() {
                        return Err(invalid(&format!(
                            "unarchived_key: {} exists and is not archived",
                            current.display()
                        )));
                    }
                    moves.push((from, current.clone()));
                }
            }
        }
        let mut done: Vec<(PathBuf, PathBuf)> = Vec::new();
        for (from, to) in moves {
            match cmux_blocking::fs::rename(&from, &to) {
                Ok(()) => done.push((from, to)),
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => {
                    while let Some((back_to, back_from)) = done.pop() {
                        let _ = cmux_blocking::fs::rename(&back_from, &back_to);
                    }
                    return Err(error);
                }
            }
        }
        Ok(())
    }

    pub(super) fn private_key(&self) -> io::Result<Zeroizing<[u8; 32]>> {
        let config = self.config()?;
        if config.server_identity.is_some() {
            return Ok(enrolled(&config)?.wireguard_key());
        }
        let text = Zeroizing::new(cmux_blocking::fs::read_to_string(self.key_path())?);
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

fn enrolled(config: &LinkConfig) -> io::Result<cmux_server::pairing::EnrolledIdentity> {
    let path = config
        .server_identity
        .as_ref()
        .ok_or_else(|| io::Error::other("server_link.not_enrolled"))?;
    let identity = cmux_server::pairing::EnrolledIdentity::load(path).map_err(io::Error::other)?;
    if identity.paired().install != config.install {
        return Err(io::Error::other("server_link.identity_conflict"));
    }
    Ok(identity)
}

/// The WireGuard public key of `private`.
pub(super) fn public_key(private: &[u8; 32]) -> [u8; 32] {
    let secret = x25519_dalek::StaticSecret::from(*private);
    x25519_dalek::PublicKey::from(&secret).to_bytes()
}

/// The default state directory: `<daemon state dir>/link`.
pub(super) fn default_dir() -> Option<PathBuf> {
    cmux_tui_core::platform::workspace_state_dir().map(|dir| dir.join("link"))
}

/// The local socket of the link whose state directory is `dir`:
/// `<runtime dir>/link-<12 hex>.sock`, or the same name in the short
/// fallback runtime dir when that path would not fit `sun_path`. The name
/// comes from the state directory, so two links with their own state
/// directories (a tagged DEV app's and the release app's) never share a
/// socket, also when they share a runtime directory. Readers find it in the
/// registration (`link.json`), never by this name.
pub(super) fn socket_path_for(dir: &Path) -> PathBuf {
    use sha2::{Digest as _, Sha256};
    let canonical = cmux_blocking::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf());
    let digest = Sha256::digest(canonical.as_os_str().as_encoded_bytes());
    let hex: String = digest.iter().take(6).map(|byte| format!("{byte:02x}")).collect();
    let leaf = format!("link-{hex}.sock");
    let preferred = cmux_tui_core::platform::runtime_dir().join(&leaf);
    if cmux_unix_socket::fits(&preferred) {
        return preferred;
    }
    cmux_tui_core::platform::fallback_runtime_dir().join(leaf)
}

/// A file the link restores is a regular file (not a symlink) of this user
/// that no group or other user may open.
fn check_private_file(path: &Path) -> io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let meta = cmux_blocking::fs::symlink_metadata(path)?;
    let uid = cmux_tui_core::platform::effective_uid();
    if !meta.file_type().is_file() || meta.uid() != uid || meta.mode() & 0o077 != 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} is not a private file of this user", path.display()),
        ));
    }
    Ok(())
}

/// Opens (or makes, 0600) a lock file of the state directory.
pub(super) fn open_lock(path: &Path) -> io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    crate::blocking::fs::open_with(
        std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW),
        path,
    )
}

/// The link socket's folder is this user's private folder: a real folder
/// (not a symlink), owned by this user, that no group or other user may
/// open. Also for the `/tmp/cmux-tui-<uid>` fallback, where another user
/// could have made the folder first.
pub(super) fn check_socket_dir(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::MetadataExt;
    let meta = cmux_blocking::fs::symlink_metadata(dir)?;
    let uid = cmux_tui_core::platform::effective_uid();
    let refuse = |why: String| Err(io::Error::new(io::ErrorKind::PermissionDenied, why));
    if meta.file_type().is_symlink() || !meta.is_dir() {
        return refuse(format!("the link socket folder {} is not a folder", dir.display()));
    }
    if meta.uid() != uid {
        return refuse(format!("the link socket folder {} belongs to another user", dir.display()));
    }
    if meta.mode() & 0o077 != 0 {
        return refuse(format!(
            "the link socket folder {} is open to other users (mode {:o})",
            dir.display(),
            meta.mode() & 0o777
        ));
    }
    Ok(())
}

fn create_private_dir(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    crate::blocking::fs::create_dir_with(
        std::fs::DirBuilder::new().recursive(true).mode(0o700),
        dir,
    )?;
    crate::blocking::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}

fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let temporary = path.with_file_name(format!(".{name}.{}.tmp", std::process::id()));
    let _ = cmux_blocking::fs::remove_file(&temporary);
    let written = crate::blocking::fs::open_with(
        std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600),
        &temporary,
    )
    .and_then(|mut file| {
        file.write_all(bytes)?;
        crate::blocking::fs::sync_all(&file)
    })
    .and_then(|()| cmux_blocking::fs::rename(&temporary, path));
    if written.is_err() {
        let _ = cmux_blocking::fs::remove_file(&temporary);
    }
    written
}
