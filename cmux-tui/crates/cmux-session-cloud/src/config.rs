//! The opt-in. With no config file nothing is offloaded and nothing leaves the machine.
//!
//! `~/.config/cmux/session-cloud.json` (or `$CMUX_SESSION_CLOUD_CONFIG`):
//! `{"store": "https://ORIGIN" | "fs:/path", "credentialFile": "...", "keyFile": "..."}`.
//! `$CMUX_SESSION_CLOUD_TOKEN` overrides the credential file.

use crate::seal::Key;
use crate::store::{BlobStore, FsStore, HttpStore};
use anyhow::{Context, bail};
use serde::Deserialize;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub store: String,
    pub credential_file: Option<PathBuf>,
    pub key_file: Option<PathBuf>,
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

pub fn config_path() -> PathBuf {
    std::env::var_os("CMUX_SESSION_CLOUD_CONFIG")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".config/cmux/session-cloud.json"))
}

impl Config {
    /// The config, or None when the person has not turned cloud history on.
    pub fn load() -> anyhow::Result<Option<Self>> {
        Self::load_from(&config_path())
    }

    pub fn load_from(path: &Path) -> anyhow::Result<Option<Self>> {
        match std::fs::read(path) {
            Ok(bytes) => Ok(Some(
                serde_json::from_slice(&bytes).with_context(|| format!("{}", path.display()))?,
            )),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    pub fn key_path(&self) -> PathBuf {
        self.key_file.clone().unwrap_or_else(|| home().join(".config/cmux/session-cloud/key"))
    }

    pub fn key(&self) -> anyhow::Result<Key> {
        Key::load_or_create(&self.key_path())
    }

    pub fn open_store(&self) -> anyhow::Result<Box<dyn BlobStore>> {
        if let Some(dir) = self.store.strip_prefix("fs:") {
            return Ok(Box::new(FsStore::new(dir)?));
        }
        if !self.store.starts_with("https://") && !self.store.starts_with("http://127.0.0.1") {
            bail!("store must be https://ORIGIN or fs:/path, not {}", self.store);
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
