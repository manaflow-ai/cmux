//! Cloud-hosted agent session histories.
//!
//! Leo, 2026-11-22: "i honestly am tempted to say 'cmux can now host session histories in the cloud to
//! save space for you as a service' ... given our projectionfs work", then "WE MOST DEF WANT THAT. ...
//! IT'S THE INTERMINGLING AND BREAKING OF BARRIERS BETWEEN LOCAL AND CLOUD."
//!
//! A cold chat's archive (acpmux `store/cold.rs`, `<session>/cold.zst`) is encrypted on this machine with a
//! key the server never sees and stored in the person's `/v1/sync` blob store ([`offload::upload`]). A small
//! stub (`cold.zst.cloud`, [`stub::Stub`]) replaces it ([`offload::commit`]). The first read of the chat
//! fetches the archive back ([`fetch::fetch_file`]) and acpmux thaws it as before.
//!
//! Opt-in: with no config file ([`config::Config`]) [`Cloud::get`] answers None, nothing is offloaded and
//! nothing leaves the machine.

pub mod config;
pub mod fetch;
pub mod offload;
pub mod seal;
pub mod store;
pub mod stub;

use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};

/// A store and the key that seals what goes in it.
pub struct Cloud {
    pub store: Box<dyn store::BlobStore>,
    pub key: seal::Key,
}

static OVERRIDE: Mutex<Option<Arc<Cloud>>> = Mutex::new(None);

impl Cloud {
    /// The cloud this process uses: one set with [`Cloud::set`] (tests, benches), else the person's config,
    /// else None (cloud history is off).
    pub fn get() -> anyhow::Result<Option<Arc<Cloud>>> {
        if let Some(cloud) = OVERRIDE.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            return Ok(Some(cloud));
        }
        let Some(config) = config::Config::load()? else { return Ok(None) };
        Ok(Some(Arc::new(Cloud { store: config.open_store()?, key: config.key()? })))
    }

    /// Makes `cloud` the one [`Cloud::get`] answers, for this process.
    pub fn set(cloud: Option<Arc<Cloud>>) {
        *OVERRIDE.lock().unwrap_or_else(|e| e.into_inner()) = cloud;
    }
}

/// Lowercase hex SHA-256 of `bytes`.
pub fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

/// Writes `bytes` to `path` through a temporary sibling, fsyncs it, renames it in place and fsyncs the folder.
pub fn write_durable(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = path.with_file_name(format!("{name}.tmp-{}", std::process::id()));
    {
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
    }
    std::fs::rename(&tmp, path)?;
    sync_dir(path.parent().unwrap_or(std::path::Path::new(".")))
}

/// fsyncs a folder so a rename or unlink in it is durable.
pub fn sync_dir(dir: &std::path::Path) -> std::io::Result<()> {
    std::fs::File::open(dir)?.sync_all()
}
