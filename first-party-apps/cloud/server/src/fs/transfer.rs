//! `cloud.file.push` and `cloud.file.pull` (contract 2.4): file transfer
//! through the machine's cmux daemon on the link, behind the `fs-v1` gate
//! (super::link_files). No SSH key, no scp, no Cloud API route.
//!
//! A pull reads the file in [`CHUNK_BYTES`] ranges (`fs.read {path, offset,
//! max_bytes}`) into a hidden landing file and publishes it with a hard
//! link; a push is one `fs.write` (mode `create`, never overwrite) of at
//! most [`super::MAX_WRITE_BYTES`] until the daemon has a write stream.
//! [`Transfer`] runs the copy on a worker; the real one is
//! [`DaemonTransfer`], tests use a fake.

use super::cancel::Cancel;
use super::link_files::{DaemonFiles, DialTarget, write_reconciled};
use super::path::{guest_arg, local_arg};
use super::running::{CancelAnswer, Running, TRANSFER_BUSY};
use super::{FILE_TOO_LARGE, MAX_WRITE_BYTES};
use crate::api::{CloudError, ControlPlane, Origin, args};
use crate::ops::Server;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde_json::{Value, json};
use std::io::Write as _;
use std::path::PathBuf;
use std::sync::Arc;

pub const TRANSFER_FAILED: &str = "cmux.cloud.transfer_failed";
/// The code of a transfer that `cloud.file.transfer.cancel` stopped (its
/// event says `state: cancelled`).
pub const TRANSFER_CANCELLED: &str = "cmux.cloud.transfer_cancelled";
/// `cloud.file.transfer.list {}`.
pub(crate) const LIST: &str = "cloud.file.transfer.list";
/// `cloud.file.transfer.cancel {transfer}`.
pub(crate) const CANCEL: &str = "cloud.file.transfer.cancel";
pub const LOCAL_EXISTS: &str = "cmux.cloud.local_exists";
/// One pull read (the daemon's own cap on one `fs.read`).
pub const CHUNK_BYTES: u64 = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// This Mac to the machine.
    Push,
    /// The machine to this Mac.
    Pull,
}

/// One transfer, ready to run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferJob {
    pub machine: String,
    pub direction: Direction,
    pub local: PathBuf,
    /// Absolute guest path without glob characters.
    pub guest: String,
    /// The machine's daemon on the link (no credential).
    pub target: DialTarget,
}

/// A failed transfer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferError {
    pub message: String,
    pub retryable: bool,
}

impl From<CloudError> for TransferError {
    fn from(error: CloudError) -> Self {
        Self { message: error.message, retryable: error.retryable }
    }
}

pub trait Transfer: Send + Sync {
    /// Copies one file. On `cancel` the implementation stops at the next
    /// chunk and returns an error; the loop then removes a pull's partial
    /// file.
    fn run(&self, job: &TransferJob, cancel: &Cancel) -> Result<u64, TransferError>;
}

/// The real [`Transfer`]: daemon `fs.*` ops on the link.
pub struct DaemonTransfer {
    files: Arc<dyn DaemonFiles>,
}

impl DaemonTransfer {
    pub fn new(files: Arc<dyn DaemonFiles>) -> Self {
        Self { files }
    }
}

fn stopped() -> TransferError {
    TransferError { message: "The transfer was cancelled".into(), retryable: false }
}

fn local_error(e: &std::io::Error) -> TransferError {
    TransferError { message: format!("the local file: {e}"), retryable: false }
}

fn bad_range() -> TransferError {
    TransferError {
        message: "the machine's daemon answered fs.read with a bad range".into(),
        retryable: false,
    }
}

/// The local file of a push, read with a bound. The opened file must be
/// the regular file the path names itself (not through a symlink put there
/// after the op's check): its device and inode must equal the path's own.
fn read_local(path: &std::path::Path) -> Result<Vec<u8>, TransferError> {
    use std::io::Read as _;
    let file = std::fs::File::open(path).map_err(|e| local_error(&e))?;
    let opened = file.metadata().map_err(|e| local_error(&e))?;
    let named = std::fs::symlink_metadata(path).map_err(|e| local_error(&e))?;
    #[cfg(unix)]
    let same = {
        use std::os::unix::fs::MetadataExt as _;
        (opened.dev(), opened.ino()) == (named.dev(), named.ino())
    };
    #[cfg(not(unix))]
    let same = true;
    if !named.file_type().is_file() || !same {
        return Err(TransferError {
            message: format!("{} is no longer a regular file", path.display()),
            retryable: false,
        });
    }
    let mut bytes = Vec::new();
    file.take(MAX_WRITE_BYTES as u64 + 1).read_to_end(&mut bytes).map_err(|e| local_error(&e))?;
    if bytes.len() > MAX_WRITE_BYTES {
        return Err(TransferError {
            message: format!("the local file is larger than {MAX_WRITE_BYTES} bytes"),
            retryable: false,
        });
    }
    Ok(bytes)
}

impl Transfer for DaemonTransfer {
    fn run(&self, job: &TransferJob, cancel: &Cancel) -> Result<u64, TransferError> {
        match job.direction {
            Direction::Push => {
                let bytes = read_local(&job.local)?;
                if cancel.is_cancelled() {
                    return Err(stopped());
                }
                let params = json!({ "path": job.guest, "bytes_base64": STANDARD.encode(&bytes),
                    "mode": "create" });
                write_reconciled(&*self.files, &job.target, params, bytes.len() as u64, cancel)?;
                Ok(bytes.len() as u64)
            }
            Direction::Pull => {
                let mut file = std::fs::OpenOptions::new()
                    .write(true)
                    .create_new(true)
                    .open(&job.local)
                    .map_err(|e| local_error(&e))?;
                let mut offset = 0u64;
                // The size the first answer names bounds the whole pull: a
                // daemon that keeps saying "more" cannot fill the disk.
                let mut size = None;
                loop {
                    if cancel.is_cancelled() {
                        return Err(stopped());
                    }
                    let params =
                        json!({ "path": job.guest, "offset": offset, "max_bytes": CHUNK_BYTES });
                    let answer = self.files.call(&job.target, "fs.read", params, cancel)?;
                    let bytes = super::files::read_bytes(&answer)?;
                    let more = answer["truncated"].as_bool() == Some(true);
                    let total = *size.get_or_insert(answer["size"].as_u64().unwrap_or(0));
                    offset += bytes.len() as u64;
                    if !super::files::range_ok(bytes.len() as u64, CHUNK_BYTES, more)
                        || offset > total
                    {
                        return Err(bad_range());
                    }
                    file.write_all(&bytes).map_err(|e| local_error(&e))?;
                    if !more {
                        break;
                    }
                }
                file.sync_all().map_err(|e| local_error(&e))?;
                Ok(offset)
            }
        }
    }
}

/// The ops `cloud.file.push` and `cloud.file.pull`.
pub(crate) fn run<C: ControlPlane>(
    server: &mut Server<C>,
    name: &str,
    raw: &Value,
    _origin: Origin,
    _key: Option<&str>,
) -> Result<Value, CloudError> {
    let direction = if name == "cloud.file.push" { Direction::Push } else { Direction::Pull };
    let map = args::object(raw, &["machine", "localPath", "path"])?;
    let machine = args::id(map, "machine")?.to_owned();
    let local = local_arg(map, "localPath")?;
    let guest = guest_arg(map, "path")?.literal_for_transfer()?.to_owned();
    check_local(&local, direction)?;
    if direction == Direction::Push
        && let Ok(meta) = std::fs::metadata(&local)
        && meta.len() > MAX_WRITE_BYTES as u64
    {
        return Err(CloudError::new(
            FILE_TOO_LARGE,
            format!(
                "{} is {} bytes; a push is at most {MAX_WRITE_BYTES} bytes until the machine's \
                 daemon has a write stream",
                local.display(),
                meta.len()
            ),
        ));
    }
    if server.edge_parts().0.transfers.full() {
        return Err(CloudError {
            retryable: true,
            ..CloudError::new(
                TRANSFER_BUSY,
                "Other file transfers are running: try again when one ends",
            )
        });
    }
    // The gate before anything else: a daemon without file ops answers a
    // typed unsupported, and nothing is written here.
    let target = super::link_files::target(server, &machine)?;
    // A pull lands in a fresh hidden name next to the target and is
    // published with a hard link, which never overwrites and never follows
    // a symlink put at the target meanwhile. A failed pull leaves nothing,
    // so the retry the error allows can run.
    let landing = match direction {
        Direction::Push => local.clone(),
        Direction::Pull => pull_landing(&local)?,
    };
    let job = TransferJob {
        machine: machine.clone(),
        direction,
        local: landing.clone(),
        guest: guest.clone(),
        target,
    };
    let (edge, _) = server.edge_parts();
    let worker = Arc::clone(&edge.transfer);
    let running = Running {
        machine: machine.clone(),
        direction,
        guest: guest.clone(),
        local: local.clone(),
        landing,
        cancel: Cancel::default(),
        started_at: 0,
    };
    let transfer = edge.transfers.start(worker, job, running)?;
    Ok(json!({
        "ok": true,
        "transfer": transfer,
        "state": "running",
        "machine": machine,
        "path": guest,
        "localPath": local.to_string_lossy(),
    }))
}

/// `<folder>/.<name>.cmux-pull-<random>`: the name a pull writes first.
fn pull_landing(local: &std::path::Path) -> Result<PathBuf, CloudError> {
    let mut nonce = [0u8; 8];
    getrandom::fill(&mut nonce)
        .map_err(|e| CloudError::new(TRANSFER_FAILED, format!("no system random source: {e}")))?;
    let hex: String = nonce.iter().map(|b| format!("{b:02x}")).collect();
    let name = local.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    Ok(local.with_file_name(format!(".{name}.cmux-pull-{hex}")))
}

/// Push: the local file exists and is a regular file. Pull: nothing exists
/// at the local path (no overwrite) and its directory exists.
fn check_local(local: &std::path::Path, direction: Direction) -> Result<(), CloudError> {
    let meta = std::fs::symlink_metadata(local);
    match direction {
        Direction::Push => match meta {
            Ok(m) if m.is_file() => Ok(()),
            _ => Err(CloudError::invalid(format!("{} is not a local file", local.display()))),
        },
        Direction::Pull => {
            if meta.is_ok() {
                return Err(CloudError::new(
                    LOCAL_EXISTS,
                    format!("{} already exists; pull never overwrites", local.display()),
                ));
            }
            match local.parent().map(std::fs::metadata) {
                Some(Ok(m)) if m.is_dir() => Ok(()),
                _ => Err(CloudError::invalid(format!(
                    "the folder of {} does not exist",
                    local.display()
                ))),
            }
        }
    }
}

/// `cloud.file.transfer.list {}`: the running transfers, then the recent
/// finished ones (crate::fs::running::Transfers::list).
pub(crate) fn list<C: ControlPlane>(
    server: &mut Server<C>,
    raw: &Value,
) -> Result<Value, CloudError> {
    args::object(raw, &[])?;
    let (edge, _) = server.edge_parts();
    Ok(json!({ "transfers": edge.transfers.list() }))
}

/// `cloud.file.transfer.cancel {transfer}`: `cancelling` for a running
/// transfer (one `cancelled` event follows), `ended` for one that already
/// ended (nothing changes), `cmux.cloud.not_found` for an id this server
/// never issued.
pub(crate) fn cancel<C: ControlPlane>(
    server: &mut Server<C>,
    raw: &Value,
) -> Result<Value, CloudError> {
    let map = args::object(raw, &["transfer"])?;
    let transfer = args::id(map, "transfer")?.to_owned();
    let (edge, _) = server.edge_parts();
    let state = match edge.transfers.cancel(&transfer)? {
        CancelAnswer::Cancelling => "cancelling",
        CancelAnswer::Ended => "ended",
    };
    Ok(json!({ "ok": true, "transfer": transfer, "state": state }))
}
