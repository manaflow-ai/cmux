//! The host agent: `acpmux machine hypervisor serve` (cmuxterm-hq RFD 0100, step 5).
//!
//! One joined host runs many agent VMs. The hub books slots (`create | pause | resume |
//! destroy`, idempotent by slot name); this module makes them real on the local hypervisor
//! and cleans up after itself with no hosted reaper: every slot carries the hub's lease and
//! the host enforces it with its own clock (RFD 0100 section 6).
//!
//! - [`HypervisorDriver`]: the verbs, one implementation per hypervisor. libvirt first
//!   ([`libvirt::LibvirtDriver`], which also covers Proxmox's QEMU/KVM); `qm` and Firecracker follow.
//! - [`lease::LeaseBook`]: the leases, persisted, judged into pause-to-disk or destroy actions.
//! - [`source::CommandSource`]: where commands come from: a local spool (`machine hypervisor
//!   apply`), or with `serve --source hub` the hub's command lease ([`hub::HubSource`], RFD 0100
//!   step 4) with this joined machine's own credential.
//! - [`serve`]: the loop that ties them together.

pub mod hub;
pub mod lease;
pub mod libvirt;
pub mod pods;
pub mod serve;
pub mod source;

use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};

/// Every VM the host agent owns is named `cmux-<slot>` on the hypervisor; any other
/// domain is never touched. A `cmux-*` VM with no lease is an orphan (section 6).
pub const DOMAIN_PREFIX: &str = "cmux-";

/// A slot's name as the hub books it: 1 to 56 of `[a-z0-9-]`, so `cmux-<slot>` is a
/// valid domain, file and host name everywhere.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct SlotName(String);

impl SlotName {
    pub fn parse(name: &str) -> Result<Self> {
        let ok = !name.is_empty()
            && name.len() <= 56
            && !name.starts_with('-')
            && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
        if !ok {
            bail!("slot name {name:?}: use 1 to 56 of a-z, 0-9 and -, not starting with -");
        }
        Ok(Self(name.to_owned()))
    }

    /// The slot of a hypervisor domain name, when it is one of ours.
    pub fn from_domain(domain: &str) -> Option<Self> {
        domain.strip_prefix(DOMAIN_PREFIX).and_then(|s| Self::parse(s).ok())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn domain(&self) -> String {
        format!("{DOMAIN_PREFIX}{}", self.0)
    }
}

impl TryFrom<String> for SlotName {
    type Error = anyhow::Error;
    fn try_from(s: String) -> Result<Self> {
        Self::parse(&s)
    }
}

impl From<SlotName> for String {
    fn from(s: SlotName) -> Self {
        s.0
    }
}

impl std::fmt::Display for SlotName {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// What a slot's VM is doing now.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SlotState {
    Running,
    /// Paused with its RAM kept in the running hypervisor process (`memoryPause`).
    Paused,
    /// Paused to disk: RAM written out, no process (libvirt managed save).
    Saved,
    /// Defined but not running and with no saved RAM.
    Stopped,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Slot {
    pub name: SlotName,
    pub state: SlotState,
}

/// How a slot pauses (RFD 0100 section 5): keep RAM in the process, or write it to disk.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PauseMode {
    #[default]
    Memory,
    Disk,
}

/// The size of a new slot's VM.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SlotSpec {
    pub vcpus: u32,
    pub memory_mib: u64,
    /// The overlay's virtual size; the base image's when 0.
    pub disk_gib: u64,
    /// A one-time join token the hub minted for this slot (`serve --source hub` only): the
    /// new guest redeems it to join the hub as its own machine. Never read from or written to
    /// a command file, so a spooled command cannot carry or leak one.
    #[serde(skip)]
    pub join: Option<ChildJoin>,
}

impl Default for SlotSpec {
    fn default() -> Self {
        Self { vcpus: 2, memory_mib: 4096, disk_gib: 0, join: None }
    }
}

/// The variable a pod's init reads its one-time join token from (`cmj_...`, redeemed with
/// `acpmux machine join` on stdin, then unset).
pub const JOIN_TOKEN_ENV: &str = "CMUX_JOIN_TOKEN";
/// The variable naming the hub that minted it (`acpmux machine join --hub`).
pub const JOIN_HUB_ENV: &str = "CMUX_JOIN_HUB";

/// A child join token for one slot, minted by the host with its own machine credential
/// (cmux-platform `POST /v1/machines/credentials/self/children`). Wiped from memory when
/// dropped, and its `Debug` never shows it.
#[derive(Clone, PartialEq, Eq)]
pub struct ChildJoin {
    /// The hub origin that minted it, where the guest redeems it.
    pub hub: String,
    token: zeroize::Zeroizing<String>,
}

impl ChildJoin {
    pub fn new(hub: impl Into<String>, token: zeroize::Zeroizing<String>) -> Self {
        Self { hub: hub.into(), token }
    }

    /// The token itself: hand it only to the guest's environment.
    pub fn token(&self) -> &str {
        self.token.as_str()
    }

    /// The guest's environment for it: [`JOIN_TOKEN_ENV`] and [`JOIN_HUB_ENV`].
    pub fn env(&self) -> [(&'static str, &str); 2] {
        [(JOIN_TOKEN_ENV, self.token()), (JOIN_HUB_ENV, self.hub.as_str())]
    }
}

impl std::fmt::Debug for ChildJoin {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ChildJoin").field("hub", &self.hub).field("token", &"<redacted>").finish()
    }
}

/// The lifecycle verbs, by slot name. Every verb is idempotent: creating a slot that
/// exists, pausing a paused one, resuming a running one or destroying a gone one succeeds
/// and reports the state, so a command the hub leases twice does no harm.
pub trait HypervisorDriver {
    /// Make and start the slot's VM; an existing slot is left as it is. `spec.join`, when
    /// set, goes to the new guest's environment (pods); libvirt does not use it yet.
    fn create(&self, slot: &SlotName, spec: &SlotSpec) -> Result<SlotState>;
    fn pause(&self, slot: &SlotName, mode: PauseMode) -> Result<SlotState>;
    fn resume(&self, slot: &SlotName) -> Result<SlotState>;
    /// Stop the VM and remove it and its overlay disk. A slot that is gone is fine.
    fn destroy(&self, slot: &SlotName) -> Result<()>;
    /// Every `cmux-*` VM on this hypervisor, whatever made it.
    fn list(&self) -> Result<Vec<Slot>>;
}

/// The driver a `serve` or `ls` picked at run time (`--driver`).
impl HypervisorDriver for Box<dyn HypervisorDriver> {
    fn create(&self, slot: &SlotName, spec: &SlotSpec) -> Result<SlotState> {
        (**self).create(slot, spec)
    }
    fn pause(&self, slot: &SlotName, mode: PauseMode) -> Result<SlotState> {
        (**self).pause(slot, mode)
    }
    fn resume(&self, slot: &SlotName) -> Result<SlotState> {
        (**self).resume(slot)
    }
    fn destroy(&self, slot: &SlotName) -> Result<()> {
        (**self).destroy(slot)
    }
    fn list(&self) -> Result<Vec<Slot>> {
        (**self).list()
    }
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
