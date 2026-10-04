//! Files on Cloud machines (contract 2.4): `cloud.fs.*`,
//! `cmux.fs.provider/1` for the scheme `cloud-vm`, and `cloud.file.push` /
//! `cloud.file.pull`, all on the machine's cmux daemon over the link behind
//! the `fs-v1` gate (link_files).

pub mod cancel;
pub mod files;
pub mod link_files;
pub mod path;
pub mod provider;
pub(crate) mod running;
pub mod transfer;

pub use cancel::Cancel;
pub use files::Entry;
pub use link_files::{DaemonFiles, DialTarget, FS_CAPABILITY, LinkDaemonFiles};
pub use path::GuestPath;
pub use provider::{CloudFs, FS_PROVIDER_INTERFACE, FsProvider, Root, SCHEME};
pub use running::{MAX_TRANSFERS, TRANSFER_BUSY, TransferEvent};
pub use transfer::{DaemonTransfer, Direction, Transfer, TransferError, TransferJob};

use crate::api::{CloudError, ControlPlane, Origin};
use crate::ops::Server;
use serde_json::Value;

/// Largest file `cloud.fs.read` returns (read in 1 MiB daemon ranges, sent
/// to the host as base64 in one JSON line).
pub const MAX_READ_BYTES: usize = 16 * 1024 * 1024;
/// Largest single daemon `fs.write` (decision D2: 12 MiB raw keeps its
/// base64 line under the daemon's 16 MiB line limit). `cloud.fs.write` and
/// a push answer `file_too_large` above it until the daemon has a write
/// stream.
pub const MAX_WRITE_BYTES: usize = 12 * 1024 * 1024;

/// File ops that may run at once (each on its own worker).
pub const MAX_FILE_OPS: usize = 8;

pub const FILE_TOO_LARGE: &str = "cmux.cloud.file_too_large";

/// Ops whose answer is live transfer state: never replayed from the ledger.
pub(crate) fn live_state_op(name: &str) -> bool {
    name == transfer::CANCEL
}

pub(crate) fn serves(name: &str) -> bool {
    name.starts_with("cloud.fs.") || name.starts_with("cloud.file.")
}

pub(crate) fn run<C: ControlPlane>(
    server: &mut Server<C>,
    name: &str,
    raw: &Value,
    origin: Origin,
    key: Option<&str>,
) -> Result<Value, CloudError> {
    if name == transfer::LIST {
        return transfer::list(server, raw);
    }
    if name == transfer::CANCEL {
        return transfer::cancel(server, raw);
    }
    if name.starts_with("cloud.file.") {
        return transfer::run(server, name, raw, origin, key);
    }
    let _ = key; // file ops are daemon ops: no backend key
    files::run(server, name, raw)
}
