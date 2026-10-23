//! The device's state file: its keys and identity. Written mode 0600.

use std::io::Write;
use std::net::Ipv6Addr;
use std::path::Path;

use anyhow::Context;
use serde::{Deserialize, Serialize};

#[derive(Clone, Serialize, Deserialize)]
pub struct StateFile {
    pub coord: String,
    pub tailnet: String,
    pub node_id: String,
    pub name: String,
    pub address: Ipv6Addr,
    /// Ed25519 machine key seed, standard base64.
    pub machine_seed: String,
    /// X25519 WireGuard private key, standard base64.
    pub node_private: String,
}

impl StateFile {
    pub fn load(path: &Path) -> anyhow::Result<Option<Self>> {
        match std::fs::read(path) {
            Ok(bytes) => Ok(Some(
                serde_json::from_slice(&bytes)
                    .with_context(|| format!("parse {}", path.display()))?,
            )),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error).with_context(|| format!("read {}", path.display())),
        }
    }

    /// Write atomically (temp file + rename), owner read/write only.
    pub fn save(&self, path: &Path) -> anyhow::Result<()> {
        let text = serde_json::to_vec_pretty(self)?;
        let temp = path.with_extension("tmp");
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&temp).with_context(|| format!("write {}", temp.display()))?;
        file.write_all(&text)?;
        file.sync_all()?;
        std::fs::rename(&temp, path)?;
        Ok(())
    }
}
