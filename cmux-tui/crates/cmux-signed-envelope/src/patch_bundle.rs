//! Signed patch bundles (cmuxterm-hq docs/rfd/0224-one-update-system.md, "Hot patches": signed
//! patch bundles in the same envelope, for small fixes without a full update, applied with the
//! same health check and rollback as an update).
//!
//! A bundle is the envelope around this payload:
//!
//! ```json
//! {"schema": 1, "purpose": "cmux-patch-bundle", "id": "fix-1", "target": "acpmux",
//!  "base": "<the build it applies onto>", "issued_at": 1, "expires_at": 2,
//!  "files": [{"path": "web/app.js", "sha256": "<hex>", "content": "<base64>"}]}
//! ```
//!
//! [`verify`] opens it with [`crate::open`] (the signature before any field), then checks the
//! purpose, the target, that it applies onto this exact build, that it has not expired, that
//! every path stays inside the root, and that each file's bytes hash to its `sha256`.
//!
//! [`apply`] keeps a copy of each file it replaces under `<state>/prev/<id>/`, writes the new
//! files (each by a rename, keeping the old file's permissions), and runs the health probe. A
//! failed probe or write puts every file back as it was (a file the bundle added is removed)
//! and marks the id bad under `<state>/bad/<id>`, so the host never tries it again. A passed
//! probe records the bundle in `<state>/applied.json`.

use std::collections::BTreeSet;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::time::Duration;

use cmux_process::{Command, Stdio};

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

use crate::Key;

/// The payload purpose of a patch bundle.
pub const PURPOSE: &str = "cmux-patch-bundle";
/// The payload schema [`verify`] reads.
pub const PAYLOAD_SCHEMA: u64 = 1;
/// The largest bundle file read: a bundle is a small fix; a larger change is a full update.
pub const MAX_BUNDLE_BYTES: usize = 8 * 1024 * 1024;
/// The most files one bundle carries.
pub const MAX_FILES: usize = 64;
/// The longest id or path component.
pub const MAX_NAME: usize = 64;
/// The longest relative path.
pub const MAX_PATH: usize = 512;
/// The health check's bound after a swap (the RFD's 30 s).
pub const HEALTH_BOUND: Duration = Duration::from_secs(30);

/// One file of a verified bundle.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PatchFile {
    /// Relative to the root the bundle applies to; only normal components.
    pub path: String,
    pub bytes: Vec<u8>,
}

/// A verified bundle.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Bundle {
    pub id: String,
    pub target: String,
    pub base: String,
    pub issued_at: u64,
    pub expires_at: u64,
    pub files: Vec<PatchFile>,
}

#[derive(Deserialize)]
struct Payload {
    schema: u64,
    purpose: String,
    id: String,
    target: String,
    base: String,
    issued_at: u64,
    expires_at: u64,
    files: Vec<FileEntry>,
}

#[derive(Deserialize)]
struct FileEntry {
    path: String,
    sha256: String,
    content: String,
}

fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_NAME
        && id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b"._-".contains(&b))
}

/// A path the bundle may write: relative, only normal components, none hidden from the root.
fn valid_path(path: &str) -> bool {
    // Each `/` part on its own: Path::components drops `.` and doubled slashes silently.
    !path.is_empty()
        && path.len() <= MAX_PATH
        && path.split('/').all(|part| {
            !part.is_empty()
                && part.len() <= MAX_NAME
                && !part.starts_with('.')
                && !part.contains(['\\', '\0', ':'])
        })
}

/// The bundle in `body` when a `keys` signature covers it, it is for `target` on the build
/// `base`, and it is unexpired at `now` (unix seconds); else why not.
pub fn verify(
    body: &[u8],
    keys: &[Key],
    target: &str,
    base: &str,
    now: u64,
) -> Result<Bundle, String> {
    if body.len() > MAX_BUNDLE_BYTES {
        return Err(format!("the bundle is {} bytes, over {MAX_BUNDLE_BYTES}", body.len()));
    }
    let bytes = crate::open(body, keys)?;
    let payload: Payload = serde_json::from_slice(&bytes)
        .map_err(|err| format!("the bundle payload is not a bundle: {err}"))?;
    if payload.purpose != PURPOSE {
        return Err(format!("the payload's purpose is {:?}, not {PURPOSE:?}", payload.purpose));
    }
    if payload.schema != PAYLOAD_SCHEMA {
        return Err(format!("unknown bundle payload schema {}", payload.schema));
    }
    if !valid_id(&payload.id) {
        return Err(format!("bundle id {:?} is not [a-z0-9._-] of at most {MAX_NAME}", payload.id));
    }
    if payload.target != target {
        return Err(format!("the bundle is for {:?}, not {target:?}", payload.target));
    }
    if payload.base != base {
        return Err(format!(
            "the bundle applies onto {:?}, and this is {base:?}: a full update is next",
            payload.base
        ));
    }
    if payload.issued_at > payload.expires_at {
        return Err("the bundle expires before it was issued".to_owned());
    }
    if now >= payload.expires_at {
        return Err(format!("the bundle expired at {} (now {now})", payload.expires_at));
    }
    if payload.files.is_empty() || payload.files.len() > MAX_FILES {
        return Err(format!("the bundle has {} files: 1 to {MAX_FILES}", payload.files.len()));
    }
    let b64 = base64::engine::general_purpose::STANDARD;
    let mut seen = BTreeSet::new();
    let mut files = Vec::with_capacity(payload.files.len());
    for entry in payload.files {
        if !valid_path(&entry.path) {
            return Err(format!("path {:?} is not a plain relative path", entry.path));
        }
        if !seen.insert(entry.path.clone()) {
            return Err(format!("path {:?} is in the bundle twice", entry.path));
        }
        let bytes = b64
            .decode(&entry.content)
            .map_err(|_| format!("{}: content is not base64", entry.path))?;
        if hex(&Sha256::digest(&bytes)) != entry.sha256 {
            return Err(format!("{}: the content does not hash to its sha256", entry.path));
        }
        files.push(PatchFile { path: entry.path, bytes });
    }
    Ok(Bundle {
        id: payload.id,
        target: payload.target,
        base: payload.base,
        issued_at: payload.issued_at,
        expires_at: payload.expires_at,
        files,
    })
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// What [`apply`] did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Outcome {
    /// Written and healthy; recorded in `applied.json`.
    Applied { id: String, files: usize },
    /// `applied.json` already names this id.
    AlreadyApplied { id: String },
    /// The write or the health probe failed: every file is back as it was and the id is bad.
    RolledBack { id: String, why: String },
}

/// The bundle a host last applied (`<state>/applied.json`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AppliedRecord {
    pub id: String,
    pub target: String,
    pub base: String,
    pub files: Vec<String>,
}

/// The record of the bundle applied last in `state`, if any.
pub fn applied(state: &Path) -> Option<AppliedRecord> {
    serde_json::from_slice(&std::fs::read(state.join("applied.json")).ok()?).ok()
}

/// Why `id` was marked bad in `state`, if it was.
pub fn bad(state: &Path, id: &str) -> Option<String> {
    std::fs::read_to_string(state.join("bad").join(id)).ok()
}

/// What stood at a path before the bundle.
struct Prior {
    path: PathBuf,
    /// The copy under `prev/<id>/`, when a file stood there.
    copy: Option<PathBuf>,
}

/// Write `bundle` under `root`, run `probe`, and keep it only when the probe passes; the
/// rollback copies and records live in `state`. An `Err` is a failure before any file was
/// touched (a bad id, unreadable state), or a rollback that could not put a file back.
pub fn apply(
    bundle: &Bundle,
    root: &Path,
    state: &Path,
    probe: &mut dyn FnMut() -> Result<(), String>,
) -> Result<Outcome, String> {
    if let Some(why) = bad(state, &bundle.id) {
        return Err(format!("bundle {} is marked bad on this host: {}", bundle.id, why.trim()));
    }
    if applied(state).is_some_and(|record| record.id == bundle.id) {
        return Ok(Outcome::AlreadyApplied { id: bundle.id.clone() });
    }
    let prev = state.join("prev").join(&bundle.id);
    if prev.exists() {
        std::fs::remove_dir_all(&prev).map_err(|e| format!("clearing {}: {e}", prev.display()))?;
    }
    let mut priors = Vec::with_capacity(bundle.files.len());
    for file in &bundle.files {
        let path = root.join(&file.path);
        let copy = match std::fs::symlink_metadata(&path) {
            Ok(meta) if meta.is_file() => {
                let copy = prev.join(&file.path);
                create_parent(&copy)?;
                std::fs::copy(&path, &copy)
                    .map_err(|e| format!("keeping {}: {e}", path.display()))?;
                Some(copy)
            }
            Ok(_) => return Err(format!("{} is not a plain file", path.display())),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
            Err(e) => return Err(format!("reading {}: {e}", path.display())),
        };
        priors.push(Prior { path, copy });
    }
    let healthy = write_all(bundle, root).and_then(|()| probe());
    match healthy {
        Ok(()) => {
            let record = AppliedRecord {
                id: bundle.id.clone(),
                target: bundle.target.clone(),
                base: bundle.base.clone(),
                files: bundle.files.iter().map(|file| file.path.clone()).collect(),
            };
            let body = serde_json::to_vec_pretty(&record).map_err(|e| e.to_string())?;
            write_replacing(&state.join("applied.json"), &body, None)?;
            Ok(Outcome::Applied { id: bundle.id.clone(), files: bundle.files.len() })
        }
        Err(why) => {
            restore(&priors)?;
            let mark = state.join("bad").join(&bundle.id);
            write_replacing(&mark, format!("{why}\n").as_bytes(), None)?;
            Ok(Outcome::RolledBack { id: bundle.id.clone(), why })
        }
    }
}

fn create_parent(path: &Path) -> Result<(), String> {
    match path.parent() {
        Some(parent) => std::fs::create_dir_all(parent)
            .map_err(|e| format!("creating {}: {e}", parent.display())),
        None => Ok(()),
    }
}

fn write_all(bundle: &Bundle, root: &Path) -> Result<(), String> {
    for file in &bundle.files {
        let path = root.join(&file.path);
        let mode = std::fs::metadata(&path).ok().map(|meta| meta.permissions());
        write_replacing(&path, &file.bytes, mode)?;
    }
    Ok(())
}

/// Write `bytes` to `path` by a synced temp file renamed over it, with `mode` when given.
fn write_replacing(
    path: &Path,
    bytes: &[u8],
    mode: Option<std::fs::Permissions>,
) -> Result<(), String> {
    create_parent(path)?;
    let name = path.file_name().and_then(|name| name.to_str()).unwrap_or("file");
    let temp = path.with_file_name(format!(".{name}.patch-{}", std::process::id()));
    let written = (|| {
        let mut out = std::fs::File::create(&temp)?;
        out.write_all(bytes)?;
        out.sync_all()?;
        if let Some(mode) = mode {
            std::fs::set_permissions(&temp, mode)?;
        }
        std::fs::rename(&temp, path)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written.map_err(|e| format!("writing {}: {e}", path.display()))
}

/// Put every path back as it stood: the kept copy, or no file. Tries every path, then
/// reports the ones it could not restore.
fn restore(priors: &[Prior]) -> Result<(), String> {
    let mut failed = Vec::new();
    for prior in priors {
        let restored = match &prior.copy {
            Some(copy) => std::fs::read(copy).map_err(|e| e.to_string()).and_then(|bytes| {
                let mode = std::fs::metadata(copy).ok().map(|meta| meta.permissions());
                write_replacing(&prior.path, &bytes, mode)
            }),
            None => match std::fs::remove_file(&prior.path) {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.to_string()),
                _ => Ok(()),
            },
        };
        if let Err(why) = restored {
            failed.push(format!("{}: {why}", prior.path.display()));
        }
    }
    if failed.is_empty() {
        Ok(())
    } else {
        Err(format!("the rollback could not restore {}", failed.join("; ")))
    }
}

/// A health probe: run `argv` and pass when it exits 0 within `bound`; a probe still running
/// at the bound is killed and fails.
pub fn command_probe(argv: &[&str], bound: Duration) -> Result<(), String> {
    let (program, args) = argv.split_first().ok_or("the health probe has no command")?;
    let mut child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("starting the health probe {program}: {e}"))?;
    // The probe's Child ends with this call: killed at the bound, reaped either way.
    match child.wait_timeout(bound) {
        Ok(Some(status)) if status.success() => Ok(()),
        Ok(Some(status)) => Err(format!("the health probe {program} failed: {status}")),
        Ok(None) => {
            let _ = child.kill();
            let _ = child.wait();
            Err(format!("the health probe {program} did not pass within {bound:?}"))
        }
        Err(e) => Err(format!("waiting on the health probe {program}: {e}")),
    }
}

#[cfg(test)]
#[path = "patch_bundle_tests.rs"]
mod tests;
