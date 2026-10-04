//! Files on Cloud machines (cloud-app.md 3.5): `cloud.fs.*` over the Cloud
//! API file routes, `cmux.fs.provider/1` for the scheme `cloud-vm`, and
//! `cloud.file.push` / `cloud.file.pull` over SSH with a key per transfer.

pub mod cancel;
pub mod files;
pub mod key;
pub mod known_hosts;
mod openssh;
pub mod path;
pub mod provider;
pub(crate) mod running;
pub mod transfer;

pub use cancel::Cancel;
pub use files::Entry;
pub use key::TransferKey;
pub use known_hosts::KnownHosts;
pub use openssh::scp_args;
pub use path::GuestPath;
pub use provider::{CloudFs, FS_PROVIDER_INTERFACE, FsProvider, Root, SCHEME};
pub use running::{MAX_TRANSFERS, TRANSFER_BUSY, TransferEvent};
pub use transfer::{Direction, OpenSshTransfer, ScpEndpoint, Transfer, TransferError, TransferJob};

use crate::api::{CloudError, ControlPlane, Origin};
use crate::ops::Server;
use serde_json::Value;

/// Largest file `cloud.fs.read` returns: the bytes cross the host relay as
/// base64 in one JSON line.
pub const MAX_READ_BYTES: usize = 16 * 1024 * 1024;
/// Largest `cloud.fs.write`: the Cloud API's own limit (`MAX_WRITE_BYTES`
/// in `web/app/api/vm/[id]/fs/[operation]/route.ts`).
pub const MAX_WRITE_BYTES: usize = 16 * 1024 * 1024;

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
    files::run(&mut server.ctx(name, key), name, raw)
}
