//! The host's audit log (teammate-access-DESIGN.md 6):
//! `<host dir>/audit.jsonl`, owner-only, one JSON line per admission
//! decision. Kept on this machine, never sent.

use std::io::Write as _;
use std::path::Path;

use anyhow::Context as _;
use serde_json::Value;

/// Size at which the log moves to `audit.jsonl.1` (one old file kept).
const ROTATE_BYTES: u64 = 5 * 1024 * 1024;

pub(crate) const FILE: &str = "audit.jsonl";

/// Appends `entry` (an object) with a `ts` field to the log in `dir`.
pub(crate) fn append_in(dir: &Path, entry: &Value) -> anyhow::Result<()> {
    let path = dir.join(FILE);
    if cmux_blocking::fs::metadata(&path).is_ok_and(|m| m.len() >= ROTATE_BYTES) {
        let _ = cmux_blocking::fs::rename(&path, dir.join(format!("{FILE}.1")));
    }
    let mut line = entry.clone();
    if let Some(map) = line.as_object_mut() {
        map.insert("ts".to_owned(), Value::String(super::grant::now_rfc3339()));
    }
    let mut bytes = serde_json::to_vec(&line)?;
    bytes.push(b'\n');
    let mut options = std::fs::OpenOptions::new();
    options.append(true).create(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = crate::blocking::fs::open_with(&options, &path)
        .with_context(|| format!("cannot open {}", path.display()))?;
    cmux_tui_core::platform::restrict_file(&path)?;
    file.write_all(&bytes)?;
    Ok(())
}

/// Appends to the log in the host state directory; a failure is printed,
/// never fatal to the connection decision already made.
pub(crate) fn append(entry: &Value) {
    let result = super::config::ensure_dir().and_then(|dir| append_in(&dir, entry));
    if let Err(e) = result {
        eprintln!("cmux host: audit log: {e:#}");
    }
}
