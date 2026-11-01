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
use crate::cloud::wire::{BIND_FILE, BOUND_FILE, INSTALL_KEY_FILE};
use crate::config::Paths;

pub const SOCKET: &str = "/run/cmux-host/identity.sock";
/// Written only after a successful enrollment, not when a key is rotated.
pub const RECEIPT: &str = "/var/lib/cmux/install/identity.json";
/// Platform-scope enrollment is deliberately kept separate from legacy bind state.  A
/// late scoped read must never rotate the key or receipt owned by normal enrollment.
const SCOPED_INSTALL_KEY_FILE: &str = "/var/lib/cmux/install/platform-scope-key.json";
const SCOPED_RECEIPT: &str = "/var/lib/cmux/install/platform-scope-identity.json";

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
/// Its only caller is the Linux host loop (`linux/mod.rs`), so it is compiled there and in tests.
#[cfg(any(target_os = "linux", test))]
pub(crate) fn enrolled(store: &dyn Store, fresh_instance: &str) -> Result<HostIdentity, String> {
    use crate::cloud::wire::{BIND_FILE, BOUND_FILE, Bound};

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

/// Establish a host identity for a platform-provisioned Cloud scope that has
/// no legacy bind record. The scope file is root-owned and was written by the
/// platform, so it is the authority for the logical machine id; the key is
/// still generated and retained locally, and bind-in-progress machines refuse
/// this path until their normal enrollment completes.
#[cfg(any(target_os = "linux", test))]
pub(crate) fn scoped(store: &mut dyn Store, paths: &Paths) -> Result<HostIdentity, String> {
    if store.present(BIND_FILE)? || store.present(BOUND_FILE)? || store.present(RECEIPT)? {
        return Err("identity enrollment is pending".to_owned());
    }
    let values =
        crate::turn_scope::environment(paths).map_err(|_| "scope is unavailable".to_owned())?;
    let machine = values
        .iter()
        .find_map(|(key, value)| (key == "CMUX_PLATFORM_MACHINE_ID").then_some(value.as_str()))
        .filter(|value| !value.is_empty())
        .ok_or_else(|| "scope has no machine id".to_owned())?;
    let key = if let Some(saved) = store.read(SCOPED_INSTALL_KEY_FILE) {
        let parsed: SavedKey =
            serde_json::from_str(&saved).map_err(|_| "invalid scoped install key")?;
        if parsed.instance_id != machine {
            return Err("scoped install key belongs to another machine".to_owned());
        }
        InstallKey::from_pkcs8_base64url(&parsed.pkcs8, &SystemRandom::new())?
    } else {
        let key = InstallKey::generate(&SystemRandom::new())?;
        let text = serde_json::json!({
            "instance_id": machine,
            "pkcs8": key.pkcs8_base64url(),
        });
        store.write(SCOPED_INSTALL_KEY_FILE, &format!("{text}\n"), 0o600)?;
        key
    };
    let identity = HostIdentity::from_key(machine, machine, &key);
    let text = serde_json::to_string(&identity).map_err(|e| e.to_string())?;
    store.write(SCOPED_RECEIPT, &text, 0o600)?;
    Ok(identity)
}

#[cfg(target_os = "linux")]
mod ipc;
#[cfg(target_os = "linux")]
pub(crate) use ipc::Listener;
#[cfg(target_os = "linux")]
pub use ipc::query;

#[cfg(test)]
mod tests;
