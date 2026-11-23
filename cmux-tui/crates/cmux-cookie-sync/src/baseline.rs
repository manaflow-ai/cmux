//! The last fingerprint the app imported, one small file per source under
//! the app's state directory: `<state_dir>/<sanitized id>-<hash>.fingerprint`,
//! JSON `{"version": 1, "source": id, "hosts": {host_key: "hex hash"}}`,
//! written whole to a temporary file and renamed over the old one, mode 0600.
//! It holds hashes only: no cookie value, name or path.

use crate::fingerprint::{Fingerprint, create_private_dir};
use crate::hash::Fnv;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::{self, Write};
use std::path::{Path, PathBuf};

const VERSION: u32 = 1;

#[derive(Serialize, Deserialize)]
struct File {
    version: u32,
    source: String,
    hosts: BTreeMap<String, String>,
}

/// The baseline file of source `id` (its letters, digits, `.`, `_` and `-`
/// kept, the rest `_`, then a hash of the whole id so two ids never share it).
pub fn path(state_dir: &Path, id: &str) -> PathBuf {
    let readable: String = id
        .chars()
        .take(64)
        .map(|c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-') { c } else { '_' })
        .collect();
    let mut hash = Fnv::new();
    hash.bytes(id.as_bytes());
    state_dir.join(format!("{readable}-{:016x}.fingerprint", hash.finish()))
}

/// The saved baseline of `id`; none when there is none, or it is not one
/// this version wrote (then the current fingerprint becomes the baseline).
pub fn load(state_dir: &Path, id: &str) -> Option<Fingerprint> {
    let bytes = std::fs::read(path(state_dir, id)).ok()?;
    let file: File = serde_json::from_slice(&bytes).ok()?;
    if file.version != VERSION || file.source != id {
        return None;
    }
    file.hosts
        .into_iter()
        .map(|(host, hash)| u64::from_str_radix(&hash, 16).ok().map(|hash| (host, hash)))
        .collect()
}

/// Saves `fingerprint` as the baseline of `id`.
pub fn save(state_dir: &Path, id: &str, fingerprint: &Fingerprint) -> io::Result<()> {
    create_private_dir(state_dir)?;
    let file = File {
        version: VERSION,
        source: id.to_owned(),
        hosts: fingerprint
            .iter()
            .map(|(host, hash)| (host.clone(), format!("{hash:016x}")))
            .collect(),
    };
    let bytes = serde_json::to_vec(&file).map_err(io::Error::other)?;
    let target = path(state_dir, id);
    let mut temp = target.clone().into_os_string();
    temp.push(format!(".tmp-{}", std::process::id()));
    let temp = PathBuf::from(temp);
    let _ = std::fs::remove_file(&temp);
    let written = write_private(&temp, &bytes).and_then(|()| std::fs::rename(&temp, &target));
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written
}

fn write_private(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}
