//! `cloud.file.push` and `cloud.file.pull` (cloud-app.md 3.5): file transfer
//! over SSH to the machine with a key made for this one transfer.
//!
//! 1. The server makes a fresh Ed25519 key in memory ([`TransferKey`]).
//! 2. `POST /api/vm/:id/scp-endpoint {publicKey}` authorizes its public half
//!    for 15 minutes (`restrict`, no PTY) and answers the guest's host key.
//! 3. The bytes go through the machine's link: a one-shot forward on
//!    127.0.0.1 to the guest's SSH port (the same path as `cloud.port.*`), so
//!    no private-network route is needed on this Mac.
//! 4. [`Transfer`] runs the copy with the host key pinned. The real one is
//!    [`OpenSshTransfer`]; tests use a fake.

use super::cancel::Cancel;
use super::key::TransferKey;
pub use super::openssh::host_alias;
use super::path::{guest_arg, local_arg};
use super::running::{CancelAnswer, Running, TRANSFER_BUSY};
use crate::api::{CloudError, ControlPlane, Origin, args, codes};
use crate::app_env::SshFiles;
use crate::ops::Server;
use crate::ports::listener::Listener;
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use serde::Deserialize;
use serde_json::{Value, json};
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

pub use super::openssh::OpenSshTransfer;

pub const TRANSFER_FAILED: &str = "cmux.cloud.transfer_failed";
/// The code of a transfer that `cloud.file.transfer.cancel` stopped (its
/// event says `state: cancelled`).
pub const TRANSFER_CANCELLED: &str = "cmux.cloud.transfer_cancelled";
/// `cloud.file.transfer.cancel {transfer}`.
pub(crate) const CANCEL: &str = "cloud.file.transfer.cancel";
pub const LOCAL_EXISTS: &str = "cmux.cloud.local_exists";
/// The answer named no host key to pin. A host key the Cloud API did not
/// give needs the user's host key sheet (not built yet): the transfer stops.
pub const HOST_KEY_UNPINNED: &str = "cmux.cloud.host_key_unpinned";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    /// This Mac to the machine.
    Push,
    /// The machine to this Mac.
    Pull,
}

/// The `scp-endpoint` answer, checked (shapes from
/// `web/services/vms/drivers/types.ts` `SCPEndpoint`).
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScpEndpoint {
    pub host: String,
    pub port: u16,
    pub username: String,
    /// `ssh-ed25519 <base64>`: the only host key the transfer accepts.
    pub host_public_key: String,
    pub expires_at_unix: i64,
}

impl ScpEndpoint {
    /// Refuses anything but user `cmux` with one valid Ed25519 host key and
    /// an expiry in the future (`now` is Unix seconds).
    pub fn decode(answer: Value, now: i64) -> Result<Self, CloudError> {
        let bad = |why: &str| CloudError::new(codes::BAD_RESPONSE, format!("scp-endpoint: {why}"));
        let key = answer.get("hostPublicKey").and_then(Value::as_str).unwrap_or_default();
        if key.trim().is_empty() {
            return Err(CloudError::new(
                HOST_KEY_UNPINNED,
                "cmux Cloud gave no host key for this machine; a new host key needs your confirmation in cmux",
            ));
        }
        let endpoint: Self = serde_json::from_value(answer).map_err(|e| bad(&e.to_string()))?;
        if endpoint.username != "cmux" || endpoint.port == 0 {
            return Err(bad("unexpected user or port"));
        }
        if !valid_host_key(&endpoint.host_public_key) {
            return Err(bad("the host key is not one Ed25519 key"));
        }
        if endpoint.expires_at_unix <= now {
            return Err(bad("the transfer grant has already expired"));
        }
        Ok(endpoint)
    }
}

pub(crate) fn valid_host_key(text: &str) -> bool {
    let Some(encoded) = text.strip_prefix("ssh-ed25519 ") else { return false };
    let Ok(blob) = STANDARD.decode(encoded) else { return false };
    blob.len() == 51
        && blob[..4] == [0, 0, 0, 11]
        && &blob[4..15] == b"ssh-ed25519"
        && blob[15..19] == [0, 0, 0, 32]
}

/// One transfer, ready to run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferJob {
    pub machine: String,
    pub direction: Direction,
    pub local: PathBuf,
    /// Absolute guest path without glob characters.
    pub guest: String,
    pub endpoint: ScpEndpoint,
    /// Where the guest's SSH port is reachable from here (127.0.0.1).
    pub route: SocketAddr,
    /// The whole environment of each OpenSSH child (crate::app_env).
    pub env: Vec<(String, String)>,
    /// The app's OpenSSH config and pinned known_hosts.
    pub ssh: SshFiles,
    /// Folder for the transfer's short-lived agent socket.
    pub temp_dir: PathBuf,
}

/// A failed transfer. `message` never holds key material.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TransferError {
    pub message: String,
    pub retryable: bool,
}

pub trait Transfer: Send + Sync {
    /// Copies one file. The key is the one whose public half the endpoint
    /// authorized; the implementation must not store it. On `cancel` the
    /// implementation stops the copy (it registers a hook that kills each
    /// child it starts) and returns an error; the loop then removes a
    /// pull's partial file.
    fn run(&self, job: &TransferJob, key: &TransferKey, cancel: &Cancel)
    -> Result<u64, TransferError>;
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| i64::try_from(d.as_secs()).unwrap_or(i64::MAX))
}

/// The ops `cloud.file.push` and `cloud.file.pull`.
pub(crate) fn run<C: ControlPlane>(
    server: &mut Server<C>,
    name: &str,
    raw: &Value,
    origin: Origin,
    key: Option<&str>,
) -> Result<Value, CloudError> {
    let direction = if name == "cloud.file.push" { Direction::Push } else { Direction::Pull };
    let map = args::object(raw, &["machine", "localPath", "path"])?;
    let machine = args::id(map, "machine")?.to_owned();
    let local = local_arg(map, "localPath")?;
    let guest = guest_arg(map, "path")?.literal_for_transfer()?.to_owned();
    check_local(&local, direction)?;
    if server.edge_parts().0.transfers.full() {
        return Err(CloudError {
            retryable: true,
            ..CloudError::new(
                TRANSFER_BUSY,
                "Other file transfers are running: try again when one ends",
            )
        });
    }
    // The children's environment and the app's OpenSSH files, before any
    // Cloud API call: without a data folder nothing starts.
    let app_env = server.attach().env().clone();
    let no_data = |e: std::io::Error| {
        CloudError::new(TRANSFER_FAILED, format!("no private OpenSSH folder for the transfer: {e}"))
    };
    let child_env = app_env.child_env().map_err(no_data)?;
    let ssh = app_env.ssh_files().map_err(no_data)?;
    let carrier =
        crate::link::ops::connect(server, &machine, origin, key.map(|k| format!("{k}/start")))?;
    let transfer_key = TransferKey::generate()?;
    // No idempotency key: a retry must authorize its own new key.
    let answer = server.ctx(name, None).call(
        "POST",
        format!("/api/vm/{machine}/scp-endpoint"),
        Some(json!({ "publicKey": transfer_key.public_openssh() })),
    )?;
    let endpoint = ScpEndpoint::decode(answer, now_unix())?;
    let (edge, _) = server.edge_parts();
    // The loop thread is the only writer of known_hosts: the endpoint's
    // host key is pinned there before the copy starts.
    edge.pin_host_key(&ssh, &machine, &endpoint.host_public_key).map_err(|e| {
        CloudError::new(TRANSFER_FAILED, format!("could not pin the machine's host key: {e}"))
    })?;
    let handler = edge.forward_handler(&carrier, "localhost", endpoint.port);
    let route = Listener::bind(handler).map_err(|e| {
        CloudError::new(TRANSFER_FAILED, format!("could not listen on 127.0.0.1: {e}"))
    })?;
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
        endpoint,
        route: route.local_addr(),
        env: child_env,
        ssh,
        temp_dir: app_env.temp_dir(),
    };
    // The copy runs on a worker; the loop finishes it when it ends.
    let worker = Arc::clone(&edge.transfer);
    let running = Running {
        machine: machine.clone(),
        direction,
        guest: guest.clone(),
        local: local.clone(),
        landing,
        route,
        cancel: Cancel::default(),
    };
    let transfer = edge.transfers.start(worker, job, transfer_key, running)?;
    Ok(json!({
        "ok": true,
        "transfer": transfer,
        "state": "running",
        "machine": machine,
        "path": guest,
        "localPath": local.to_string_lossy(),
    }))
}

/// `<folder>/.<name>.cmux-pull-<random>`: the name scp writes during a pull.
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
