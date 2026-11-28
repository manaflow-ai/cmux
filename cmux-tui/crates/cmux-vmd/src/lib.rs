//! cmux-vmd: a self-hosted Firecracker microVM host for AutoCloud (tier B in hq
//! `docs/design/freestyle-build-vs-buy.md`).
//!
//! One daemon per host runs microVMs with create, snapshot, fork, pause/resume, files and exec,
//! deny-by-default networking (IPv4 and IPv6) and one network namespace per VM. It needs only a
//! Linux host with KVM, `ip`, `nft` and a Firecracker binary, so the same daemon runs on a GCE
//! nested-virt VM, OCI bare metal or a Hetzner dedicated server. [`provider::VmdProvider`] puts a
//! host behind the AutoCloud `MachineProvider` trait.

pub mod cmd;
pub mod fc;
pub mod host;
pub mod net;
pub mod ownhost;
pub mod proto;
pub mod provider;
pub mod server;
pub mod vsock;

/// Sets `key` on a JSON object; a non-object is left as it is. `value[key] = ..` would panic on one.
pub(crate) fn set_field(value: &mut serde_json::Value, key: &str, field: serde_json::Value) {
    if let Some(object) = value.as_object_mut() {
        object.insert(key.to_owned(), field);
    }
}
