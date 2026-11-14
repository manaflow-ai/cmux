//! The paired peers a link accepts and dials. Slice 1 keeps them in a JSON
//! file in the link's state directory (0600), written by
//! `cmux link peer add|remove`, which `cmux server pair` calls. The
//! TeamDO peer map replaces the file when it lands (transport.md 15 step 4);
//! the record shape stays.

use std::io;
use std::net::{Ipv6Addr, SocketAddr};
use std::path::Path;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};

use crate::overlay_addr::overlay_address;
use crate::stamp::{LinkPeer, valid_id};

/// One paired peer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PairingRecord {
    /// The peer's install id; its overlay address derives from it.
    pub install: String,
    /// The user the pairing approved (the server's owner checks it).
    pub user: String,
    pub team: String,
    /// The peer's WireGuard public key, standard base64 of 32 bytes.
    pub public_key: String,
    /// The peer's UDP endpoint on the same network, when known. Without it
    /// the link only answers that peer (it learns the endpoint from the
    /// peer's first authenticated datagram).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub endpoint: Option<SocketAddr>,
}

impl PairingRecord {
    /// The decoded public key, if it is 32 bytes of valid base64.
    pub fn key(&self) -> Option<[u8; 32]> {
        STANDARD.decode(&self.public_key).ok()?.try_into().ok()
    }

    pub fn overlay_address(&self) -> Ipv6Addr {
        overlay_address(&self.install)
    }

    /// The identity the link stamps on this peer's streams.
    pub fn peer(&self) -> LinkPeer {
        LinkPeer { install: self.install.clone(), user: self.user.clone(), team: self.team.clone() }
    }

    pub fn is_valid(&self) -> bool {
        valid_id(&self.install)
            && valid_id(&self.user)
            && valid_id(&self.team)
            && self.key().is_some()
    }
}

/// Every paired peer, unique by install and by key.
/// The held write lock of a pairing file ([`Pairings::lock`]); dropped, it is free.
#[derive(Debug)]
pub struct PairingsLock(std::fs::File);

impl Drop for PairingsLock {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Pairings {
    pub peers: Vec<PairingRecord>,
}

impl Pairings {
    /// Read the file at `path`; a missing file is no peers.
    pub fn load(path: &Path) -> io::Result<Self> {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(error) => return Err(error),
        };
        let pairings: Self = serde_json::from_str(&text)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        if let Some(bad) = pairings.peers.iter().find(|record| !record.is_valid()) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid pairing record for install {:?}", bad.install),
            ));
        }
        Ok(pairings)
    }

    /// Hold the pairing file's write lock: `flock` on `.<file>.lock` next to
    /// it, shared by every process. Every read, change and save of the file
    /// runs under it ([`Pairings::update`]), as does moving the file aside.
    pub fn lock(path: &Path) -> io::Result<PairingsLock> {
        let name = path.file_name().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "the pairing file has no name")
        })?;
        // Hidden, and outside the names install archives take (`peers.<install>.json`).
        let mut lock_name = std::ffi::OsString::from(".");
        lock_name.push(name);
        lock_name.push(".lock");
        let mut options = std::fs::OpenOptions::new();
        options.read(true).write(true).create(true).truncate(false);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let file = options.open(path.with_file_name(lock_name))?;
        file.lock()?;
        Ok(PairingsLock(file))
    }

    /// Read the file at `path`, apply `change`, save it, all under
    /// [`Pairings::lock`]: two writers never save over each other, in one
    /// process or two. Nothing is saved when `change` fails.
    pub fn update<T>(
        path: &Path,
        change: impl FnOnce(&mut Self) -> io::Result<T>,
    ) -> io::Result<T> {
        let _lock = Self::lock(path)?;
        let mut pairings = Self::load(path)?;
        let out = change(&mut pairings)?;
        pairings.save(path)?;
        Ok(out)
    }

    /// Write the file at `path` with mode 0600, replacing it atomically and
    /// durably: the synced temporary file is renamed into place and then the
    /// directory is synced, so once this returns the new file survives a
    /// crash. A rekey is acknowledged on that (the peer then deletes its old
    /// key), so a rename still only in the page cache is not enough.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        let text = serde_json::to_string_pretty(self)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        let temporary = unique_temporary(path);
        let result = write_private(&temporary, text.as_bytes())
            .and_then(|()| std::fs::rename(&temporary, path));
        if result.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        result?;
        sync_parent(path)
    }

    /// Add `record`, replacing a record with the same install or key.
    pub fn upsert(&mut self, record: PairingRecord) -> io::Result<()> {
        if !record.is_valid() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid pairing record"));
        }
        let key = record.key();
        self.peers.retain(|existing| existing.install != record.install && existing.key() != key);
        self.peers.push(record);
        Ok(())
    }

    /// Move `install`'s record to `public_key`: its link adopted this machine's node key and
    /// said so over its old key's session. Refused when `install` has no record or another
    /// install's record holds the key (a peer never takes over another's pairing); false when
    /// the record already holds it.
    /// [`Pairings::rekey`] of `from`'s install, only while its stored record
    /// is still the one that authenticated the request: the same key
    /// (`from_key`) and the same identity (`from`). A record that `link peer
    /// add` replaced or removed meanwhile is never written over.
    pub fn rekey_from(
        &mut self,
        from: &LinkPeer,
        from_key: &[u8; 32],
        public_key: &[u8; 32],
    ) -> io::Result<bool> {
        let current = self
            .by_install(&from.install)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "not_paired"))?;
        if current.key().as_ref() != Some(from_key) || current.peer() != *from {
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, "pairing_changed"));
        }
        self.rekey(&from.install, public_key)
    }

    pub fn rekey(&mut self, install: &str, public_key: &[u8; 32]) -> io::Result<bool> {
        if self.by_key(public_key).is_some_and(|record| record.install != install) {
            return Err(io::Error::new(io::ErrorKind::AlreadyExists, "key_in_use"));
        }
        let record = self
            .peers
            .iter_mut()
            .find(|record| record.install == install)
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "not_paired"))?;
        if record.key().as_ref() == Some(public_key) {
            return Ok(false);
        }
        record.public_key = STANDARD.encode(public_key);
        Ok(true)
    }

    /// Remove the record of `install`; true when one existed.
    pub fn remove(&mut self, install: &str) -> bool {
        let before = self.peers.len();
        self.peers.retain(|record| record.install != install);
        before != self.peers.len()
    }

    pub fn by_install(&self, install: &str) -> Option<&PairingRecord> {
        self.peers.iter().find(|record| record.install == install)
    }

    pub fn by_key(&self, key: &[u8; 32]) -> Option<&PairingRecord> {
        self.peers.iter().find(|record| record.key().as_ref() == Some(key))
    }
}

/// A temp file next to `path` that no other writer uses (pid and a counter),
/// so two writers never share one and its mode is always the one we set.
fn unique_temporary(path: &Path) -> std::path::PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let name = path.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
    let serial = NEXT.fetch_add(1, Ordering::Relaxed);
    path.with_file_name(format!(".{name}.{}.{serial}.tmp", std::process::id()))
}

/// Sync the directory holding `path`, so a rename or removal in it survives a crash.
#[cfg(unix)]
fn sync_parent(path: &Path) -> io::Result<()> {
    let dir = match path.parent() {
        Some(dir) if !dir.as_os_str().is_empty() => dir,
        _ => Path::new("."),
    };
    std::fs::File::open(dir)?.sync_all()
}

#[cfg(not(unix))]
fn sync_parent(_path: &Path) -> io::Result<()> {
    Ok(())
}

#[cfg(unix)]
fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file =
        std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

#[cfg(not(unix))]
fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    std::fs::write(path, bytes)
}

#[cfg(test)]
mod tests;
