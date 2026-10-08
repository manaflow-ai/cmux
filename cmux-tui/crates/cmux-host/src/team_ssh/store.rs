//! The trust files: atomic writes in the order sshd needs, and the reads
//! behind `principals`.

use std::fs;
use std::io::{self, Write};
use std::path::Path;

use super::trust::{self, Snapshot, TrustState, Verified};
use super::{CA_FILE, KRL_FILE, PRINCIPALS_DIR, TRUST_FILE};
use crate::config::Paths;

/// Writes `bytes` to `path` through a temp file in the same directory,
/// fsync and rename, so sshd sees the old or the new file, never a part.
pub fn write_atomic(path: &Path, bytes: &[u8], mode: u32) -> io::Result<()> {
    let dir = path.parent().ok_or_else(|| io::Error::other("path has no parent"))?;
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("file");
    let tmp = dir.join(format!(".{name}.tmp-{}", std::process::id()));
    let result = (|| {
        let mut file = fs::File::create(&tmp)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(mode))?;
        }
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&tmp, path)?;
        fs::File::open(dir)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

/// The applied state, `None` when absent or unreadable (fail closed).
pub fn load_state(paths: &Paths) -> Option<TrustState> {
    let text = fs::read_to_string(paths.at(TRUST_FILE)).ok()?;
    serde_json::from_str(&text).ok()
}

/// What an accepted apply changed.
#[derive(Debug, PartialEq, Eq)]
pub struct Applied {
    pub previous: Option<TrustState>,
    pub state: TrustState,
    /// The KRL version moved (the reaper must run).
    pub krl_changed: bool,
}

/// Validates `snapshot`, refuses a regression, then writes the KRL, the CA
/// keys and the state (in that order). A refusal changes no file, so the
/// last sync time keeps ageing toward the fail-closed bound.
pub fn apply(paths: &Paths, snapshot: &Snapshot, now: u64) -> Result<Applied, String> {
    let next: Verified = trust::verify(snapshot)?;
    let previous = load_state(paths);
    trust::decide(previous.as_ref(), &next)?;
    let io = |what: &str, e: io::Error| format!("{what}: {e}");
    let dir = paths.at(PRINCIPALS_DIR);
    fs::create_dir_all(&dir).map_err(|e| io("ssh dir", e))?;
    write_atomic(&paths.at(KRL_FILE), &next.krl, 0o644).map_err(|e| io("krl", e))?;
    let mut ca = next.ca_keys.join("\n");
    if !ca.is_empty() {
        ca.push('\n');
    }
    write_atomic(&paths.at(CA_FILE), ca.as_bytes(), 0o644).map_err(|e| io("ca keys", e))?;
    let state =
        TrustState { krl_version: next.krl_version, generation: next.generation, synced_at: now };
    let json = serde_json::to_vec(&state).map_err(|e| e.to_string())?;
    write_atomic(&paths.at(TRUST_FILE), &json, 0o644).map_err(|e| io("trust state", e))?;
    let krl_changed = previous.is_none_or(|p| p.krl_version != state.krl_version);
    Ok(Applied { previous, state, krl_changed })
}

/// `principals <user>`: the user's principals while trust is fresh.
pub fn principals(paths: &Paths, user: &str, now: u64) -> String {
    if !trust::valid_user(user) {
        return String::new();
    }
    let file = fs::read_to_string(paths.at(PRINCIPALS_DIR).join(user)).unwrap_or_default();
    trust::principals_output(load_state(paths).as_ref(), now, &file)
}
