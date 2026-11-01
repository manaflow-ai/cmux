//! Public Cloud enrollment identity. Files alone never establish freshness:
//! the host answers only after its main loop has observed provider metadata.
//!
//! This is a point-in-time observation, not an authorization lease. Callers
//! must revalidate after asynchronous work and abort work if identity changes.
//! In particular, this does not stop an inherited acpmux after a memory clone.

use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::cloud::client::Store;
use crate::cloud::wire::{BIND_FILE, BOUND_FILE, Bound, INSTALL_KEY_FILE};

pub const SOCKET: &str = "/run/cmux-host/identity.sock";
/// Written only after a successful enrollment, not when a key is rotated.
pub const RECEIPT: &str = "/var/lib/cmux/install/identity.json";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct HostIdentity {
    pub machine: String,
    pub instance_id: String,
    pub guest_key: String,
}

impl HostIdentity {
    pub fn from_key(machine: &str, instance_id: &str, key: &InstallKey) -> Self {
        Self {
            machine: machine.to_owned(),
            instance_id: instance_id.to_owned(),
            guest_key: format!("sha256:{:x}", Sha256::digest(key.public_spki())),
        }
    }
}

#[derive(Deserialize)]
struct SavedKey {
    instance_id: String,
    pkcs8: String,
}

/// Called after enrollment succeeds. The private key is never in the receipt.
pub(crate) fn record(store: &mut dyn Store, machine: &str, key: &InstallKey) -> Result<(), String> {
    let saved: SavedKey =
        serde_json::from_str(&store.read(INSTALL_KEY_FILE).ok_or("no install key")?)
            .map_err(|_| "invalid install key record")?;
    let installed = InstallKey::from_pkcs8_base64url(&saved.pkcs8, &SystemRandom::new())?;
    if installed.public_spki() != key.public_spki()
        || saved.instance_id.is_empty()
        || machine.is_empty()
    {
        return Err("enrolled key differs from installed key".to_owned());
    }
    let receipt = HostIdentity::from_key(machine, &saved.instance_id, key);
    let text = serde_json::to_string(&receipt).map_err(|e| e.to_string())?;
    store.write(RECEIPT, &text, 0o600)
}

/// The caller supplies a NEW metadata observation, never the cached status id.
pub(crate) fn enrolled(store: &dyn Store, fresh_instance: &str) -> Result<HostIdentity, String> {
    if fresh_instance.is_empty() || store.present(BIND_FILE)? {
        return Err("identity enrollment is pending".to_owned());
    }
    let receipt: HostIdentity =
        serde_json::from_str(&store.read(RECEIPT).ok_or("identity not enrolled")?)
            .map_err(|_| "invalid identity receipt")?;
    let bound: Bound = serde_json::from_str(&store.read(BOUND_FILE).ok_or("machine not bound")?)
        .map_err(|_| "invalid machine enrollment")?;
    let saved: SavedKey =
        serde_json::from_str(&store.read(INSTALL_KEY_FILE).ok_or("no install key")?)
            .map_err(|_| "invalid install key record")?;
    if saved.instance_id != fresh_instance
        || receipt.instance_id != fresh_instance
        || receipt.machine != bound.machine
        || bound.machine.is_empty()
        || bound.install.is_empty()
    {
        return Err("identity changed or enrollment is stale".to_owned());
    }
    let key = InstallKey::from_pkcs8_base64url(&saved.pkcs8, &SystemRandom::new())?;
    if receipt != HostIdentity::from_key(&bound.machine, fresh_instance, &key) {
        return Err("enrolled key differs from installed key".to_owned());
    }
    Ok(receipt)
}

#[cfg(target_os = "linux")]
mod ipc;
#[cfg(target_os = "linux")]
pub(crate) use ipc::Listener;
#[cfg(target_os = "linux")]
pub use ipc::query;

#[cfg(test)]
mod tests;
