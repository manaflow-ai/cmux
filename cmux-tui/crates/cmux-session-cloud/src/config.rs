//! The opt-in. With no config file nothing is offloaded and nothing leaves the machine.
//!
//! `<state>/session-cloud.json`, where `<state>` is the caller's own state folder (acpmux: its home, so a
//! tagged dev build never shares a NIGHTLY's config or key):
//! `{"store": "https://ORIGIN" | "fs:/path", "credentialFile": "...", "keyFile": "..."}`.
//! `$CMUX_SESSION_CLOUD_TOKEN` overrides the credential file. The key defaults to `<state>/session-cloud/key`.

use crate::seal::Key;
use crate::store::{BlobStore, FsStore, HttpStore};
use anyhow::{Context, bail};
use serde::Deserialize;
use std::path::{Path, PathBuf};

pub const CONFIG_FILE: &str = "session-cloud.json";

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub store: String,
    pub credential_file: Option<PathBuf>,
    pub key_file: Option<PathBuf>,
    /// Put before the GC root's pair id; a Cloud machine sets its own namespace here.
    pub root_prefix: Option<String>,
    /// Separately opt in to checkpoints of ordinary running chats. Cold history stays independent.
    #[serde(default)]
    pub running_replica: bool,
    /// The state folder the config was read from.
    #[serde(skip)]
    pub state: PathBuf,
}

impl Config {
    /// The config in `state`, or None when the person has not turned cloud history on.
    pub fn load_in(state: &Path) -> anyhow::Result<Option<Self>> {
        let path = state.join(CONFIG_FILE);
        match std::fs::read(&path) {
            Ok(bytes) => {
                let mut config: Self = serde_json::from_slice(&bytes)
                    .with_context(|| format!("{}", path.display()))?;
                config.state = state.to_path_buf();
                Ok(Some(config))
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    pub fn key_path(&self) -> PathBuf {
        self.key_file.clone().unwrap_or_else(|| self.state.join("session-cloud").join("key"))
    }

    pub fn key(&self) -> anyhow::Result<Key> {
        Key::load_or_create(&self.key_path())
    }

    pub fn open_store(&self) -> anyhow::Result<Box<dyn BlobStore>> {
        if let Some(dir) = self.store.strip_prefix("fs:") {
            return Ok(Box::new(FsStore::new(dir)?));
        }
        if !http_store_allowed(&self.store) {
            bail!(
                "store must be https://ORIGIN, http://127.0.0.1, http:// on a tailnet address \
                 (100.64.0.0/10) or fs:/path, not {}",
                self.store
            );
        }
        let credential = match std::env::var("CMUX_SESSION_CLOUD_TOKEN") {
            Ok(token) => token,
            Err(_) => {
                let file = self
                    .credential_file
                    .as_ref()
                    .context("no credentialFile and no CMUX_SESSION_CLOUD_TOKEN")?;
                std::fs::read_to_string(file)?.trim().to_string()
            }
        };
        Ok(Box::new(HttpStore::new(&self.store, &credential)?))
    }
}

/// Whether `store` is a network origin bytes may go to: any `https://`, or plain `http://` only
/// where the wire never leaves a trusted path: loopback (`127.0.0.1`), or a tailnet CGNAT address
/// (`100.64.0.0/10`, WireGuard-encrypted by Tailscale), as the fleet controller at
/// `http://100.89.225.106:18765`.
pub(crate) fn http_store_allowed(store: &str) -> bool {
    if store.starts_with("https://") {
        return true;
    }
    let Some(rest) = store.strip_prefix("http://") else { return false };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    if authority.contains('@') {
        return false;
    }
    let host = authority.rsplit_once(':').map_or(authority, |(host, _port)| host);
    let Ok(ip) = host.parse::<std::net::Ipv4Addr>() else { return false };
    let [a, b, ..] = ip.octets();
    ip.is_loopback() && ip == std::net::Ipv4Addr::LOCALHOST || (a == 100 && (64..128).contains(&b))
}

#[cfg(test)]
#[path = "config_tests.rs"]
mod tests;
