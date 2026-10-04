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

    /// Write the file at `path` with mode 0600, replacing it atomically.
    pub fn save(&self, path: &Path) -> io::Result<()> {
        let text = serde_json::to_string_pretty(self)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        let temporary = path.with_extension("tmp");
        write_private(&temporary, text.as_bytes())?;
        std::fs::rename(&temporary, path)
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

#[cfg(unix)]
fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

#[cfg(not(unix))]
fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    std::fs::write(path, bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(install: &str, key_byte: u8) -> PairingRecord {
        PairingRecord {
            install: install.into(),
            user: "user_1".into(),
            team: "team_1".into(),
            public_key: STANDARD.encode([key_byte; 32]),
            endpoint: Some("192.168.1.20:51820".parse().unwrap()),
        }
    }

    #[test]
    fn pairings_are_unique_by_install_and_by_key_and_survive_a_reload() {
        let directory = cmux_unix_socket::short_test_dir("pair");
        let path = directory.path().join("peers.json");
        let mut pairings = Pairings::load(&path).unwrap();
        pairings.upsert(record("inst_a", 1)).unwrap();
        pairings.upsert(record("inst_b", 2)).unwrap();
        pairings.upsert(record("inst_c", 1)).unwrap();
        assert!(pairings.by_install("inst_a").is_none(), "same key replaces the old install");
        assert_eq!(pairings.by_key(&[1; 32]).unwrap().install, "inst_c");
        pairings.save(&path).unwrap();
        assert_eq!(Pairings::load(&path).unwrap(), pairings);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }
        assert!(pairings.remove("inst_b"));
        assert!(!pairings.remove("inst_b"));
    }

    #[test]
    fn a_record_with_a_bad_key_or_id_is_refused() {
        let mut pairings = Pairings::default();
        let mut short = record("inst_a", 1);
        short.public_key = STANDARD.encode([1u8; 16]);
        assert!(pairings.upsert(short).is_err());
        assert!(pairings.upsert(record("../a", 1)).is_err());
    }
}
