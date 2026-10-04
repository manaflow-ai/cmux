//! `server.json` (server.md 4.3 row "config"; settings of server.md 13).
//!
//! The file is a JSON object. This crate reads and writes only the keys it
//! owns and keeps every other key as it found it:
//! `installId`, `server.channel`, `server.pinnedVersion`, `postgres.port`.

use std::path::{Path, PathBuf};

use serde_json::{Map, Value};

use crate::error::{Error, Result};
use crate::fsx;

pub const DEFAULT_CHANNEL: &str = "stable";

#[derive(Clone, Debug, PartialEq)]
pub struct ServerConfig {
    path: PathBuf,
    root: Map<String, Value>,
}

impl ServerConfig {
    /// Reads `path`; a missing file is an empty config.
    pub fn load(path: &Path) -> Result<ServerConfig> {
        let root = match std::fs::read(path) {
            Ok(bytes) => match serde_json::from_slice::<Value>(&bytes) {
                Ok(Value::Object(map)) => map,
                Ok(_) => {
                    return Err(Error::rejected(format!("{}: not a JSON object", path.display())));
                }
                Err(e) => return Err(Error::rejected(format!("{}: {e}", path.display()))),
            },
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Map::new(),
            Err(e) => return Err(Error::io(path.display(), e)),
        };
        Ok(ServerConfig { path: path.to_owned(), root })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Writes the file atomically (0600; the directory 0700 when created).
    pub fn save(&self) -> Result<()> {
        if let Some(dir) = self.path.parent()
            && !dir.exists()
        {
            fsx::ensure_dir(dir, 0o700)?;
        }
        let mut bytes = serde_json::to_vec_pretty(&Value::Object(self.root.clone()))
            .map_err(|e| Error::internal(e.to_string()))?;
        bytes.push(b'\n');
        fsx::atomic_write(&self.path, &bytes, 0o600)
    }

    fn section(&self, name: &str) -> Option<&Map<String, Value>> {
        self.root.get(name).and_then(Value::as_object)
    }

    fn section_mut(&mut self, name: &str) -> &mut Map<String, Value> {
        let entry = self.root.entry(name).or_insert_with(|| Value::Object(Map::new()));
        if !entry.is_object() {
            *entry = Value::Object(Map::new());
        }
        entry.as_object_mut().expect("object")
    }

    pub fn install_id(&self) -> Option<&str> {
        self.root.get("installId").and_then(Value::as_str)
    }

    /// The install id, created on first use: `inst_` + 32 random hex
    /// characters (a valid `health::HostId`). Returns whether it was new.
    pub fn ensure_install_id(&mut self) -> Result<(String, bool)> {
        if let Some(id) = self.install_id() {
            return Ok((id.to_owned(), false));
        }
        let id = format!("inst_{}", crate::host::hex(&crate::host::random::<16>()?));
        self.root.insert("installId".to_owned(), Value::String(id.clone()));
        Ok((id, true))
    }

    pub fn channel(&self) -> String {
        self.section("server")
            .and_then(|s| s.get("channel"))
            .and_then(Value::as_str)
            .unwrap_or(DEFAULT_CHANNEL)
            .to_owned()
    }

    pub fn set_channel(&mut self, channel: &str) {
        self.section_mut("server").insert("channel".to_owned(), Value::String(channel.to_owned()));
    }

    pub fn pinned_version(&self) -> Option<String> {
        self.section("server")
            .and_then(|s| s.get("pinnedVersion"))
            .and_then(Value::as_str)
            .map(str::to_owned)
    }

    pub fn set_pinned_version(&mut self, version: Option<&str>) {
        let server = self.section_mut("server");
        match version {
            Some(v) => server.insert("pinnedVersion".to_owned(), Value::String(v.to_owned())),
            None => server.remove("pinnedVersion"),
        };
    }

    pub fn postgres_port(&self) -> Option<u16> {
        self.section("postgres")
            .and_then(|s| s.get("port"))
            .and_then(Value::as_u64)
            .and_then(|p| u16::try_from(p).ok())
    }

    pub fn set_postgres_port(&mut self, port: u16) {
        self.section_mut("postgres").insert("port".to_owned(), Value::from(port));
    }
}
