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
//! A packed offload ([`offload::upload_pack`]) stores a session-pack tail bundle and the older
//! chunks separately. [`fetch::open_pack`] opens the tail, and [`fetch::backfill`] adds verified
//! chunks to the same cache as the caller requests them.
//!
//! Opt-in: with no config file ([`config::Config`]) [`Cloud::get_in`] answers None, nothing is offloaded and
//! nothing leaves the machine.

pub mod config;
pub mod fetch;
pub mod offload;
pub mod seal;
pub mod store;
pub mod stub;
pub mod transcripts;

use sha2::{Digest, Sha256};
use std::sync::{Arc, Mutex};

/// A store and the key that seals what goes in it.
pub struct Cloud {
    pub store: Box<dyn store::BlobStore>,
    pub key: seal::Key,
    /// Put before the GC root's pair id: empty for a person token; a Cloud machine's token may
    /// only register roots under its own prefix (config `rootPrefix`).
    pub root_prefix: String,
}

static OVERRIDE: Mutex<Option<Arc<Cloud>>> = Mutex::new(None);

impl Cloud {
    /// The cloud this process uses: one set with [`Cloud::set`] (tests, benches), else the config in the
    /// caller's state folder, else None (cloud history is off).
    pub fn get_in(state: &std::path::Path) -> anyhow::Result<Option<Arc<Cloud>>> {
        if let Some(cloud) = OVERRIDE.lock().unwrap_or_else(|e| e.into_inner()).clone() {
            return Ok(Some(cloud));
        }
        let Some(config) = config::Config::load_in(state)? else { return Ok(None) };
        Ok(Some(Arc::new(Cloud {
            store: config.open_store()?,
            key: config.key()?,
            root_prefix: config.root_prefix.clone().unwrap_or_default(),
        })))
    }

    /// The GC root this machine's history registers under (`POST /v1/sync/roots`): stable for the
    /// key, opaque (a hash, never a path or host name), and distinct per machine since each key is.
    pub fn root_pair(&self) -> String {
        let id =
            sha256_hex(&[b"cmux-session-cloud root\0".as_slice(), self.key.id_material()].concat());
        let short_id: String = id.chars().take(32).collect();
        format!("{}csh.{short_id}", self.root_prefix)
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
        // Owner-only, like every file in an agent's home (acpmux refuses a group-writable one).
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = options.open(&tmp)?;
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
