//! The cmux-next Cloud backend's records (`cmux.wire/1`,
//! plans/cmux-next/cloud-client-contract.md 1.2) are cmux-cloud-wire's
//! generated types (from backend/catalog/cloud-operations.json): this file
//! keeps only what the catalog does not say.
//!
//! - [`Machine`]: the generated `CloudMachine` plus the fields some backends
//!   add that the catalog lacks (platform, capabilities, provider operations,
//!   idle-pause diagnostics), relayed to the app as they came.
//! - [`Revision`]: the wire's revision is a decimal string; the projection
//!   needs its numeric order ([`order`]).
//! - [`decode_connect_info`]: the generated `CloudConnectInfo`, read with
//!   the one lenience the link keeps (a Worker without `vm_kind`).
//!
//! Strictness: a record missing a field the catalog requires is refused
//! (`bad_response`), as the generated types decode. Both backends build
//! their records from the catalog's schema, so a missing field is a broken
//! backend, not an older one; an older backend omits only optional fields.

use super::{CloudError, decode_answer};
use cmux_cloud_wire::{CloudConnectInfo, CloudMachine, CloudMachineConnectInfoOp, Op};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::cmp::Ordering;

/// A `CloudMachine` record as the app gets it: the catalog's fields, plus
/// the [`MachineExtra`] fields a backend may add. Its revision is a checked
/// decimal (leading zeros stripped).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(try_from = "MachineWire")]
pub struct Machine {
    #[serde(flatten)]
    pub record: CloudMachine,
    #[serde(flatten)]
    pub extra: MachineExtra,
}

/// The fields of a machine record that the catalog does not declare, which
/// the app reads (cmux-cloud-machine `from_next`). Their names never repeat
/// a catalog field (a test checks it), so the record encodes each key once.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct MachineExtra {
    /// Optional non-secret platform metadata supplied by the machine owner.
    #[serde(default)]
    pub platform: Option<MachinePlatform>,
    /// Stable capability names; credentials, paths and account labels stay in
    /// the session-host operations rather than this record.
    #[serde(default)]
    pub capabilities: Vec<String>,
    /// Provider operations are a separate field from the guest/session
    /// capability names above. This keeps `agent_session` and similar wire
    /// capabilities from being interpreted as provider feature gates by the
    /// app. Older backends omit this field.
    #[serde(default, skip_serializing_if = "Vec::is_empty", alias = "providerCapabilities")]
    pub provider_operations: Vec<String>,
    /// Optional idle-pause diagnostics from the cmux REST VM projection.
    /// Keep the object opaque here so this relay preserves new diagnostic
    /// fields without coupling the app server to the cron implementation.
    #[serde(
        rename = "idlePause",
        alias = "idle_pause",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub idle_pause: Option<Value>,
}

/// Non-secret host metadata that an owner may attach to a machine record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct MachinePlatform {
    #[serde(default)]
    pub os: Option<String>,
    #[serde(default)]
    pub arch: Option<String>,
}

/// [`Machine`] as decoded, before its revision is checked.
#[derive(Deserialize)]
struct MachineWire {
    #[serde(flatten)]
    record: CloudMachine,
    #[serde(flatten)]
    extra: MachineExtra,
}

impl TryFrom<MachineWire> for Machine {
    type Error = String;

    fn try_from(wire: MachineWire) -> Result<Self, String> {
        let MachineWire { mut record, extra } = wire;
        record.revision = Revision::try_from(std::mem::take(&mut record.revision))?.into();
        Ok(Self { record, extra })
    }
}

impl Machine {
    pub fn id(&self) -> &str {
        &self.record.id
    }

    /// The backend revision (a checked decimal); compare with [`order`].
    pub fn revision(&self) -> &str {
        &self.record.revision
    }

    /// The revision as the projection keeps it for a removal.
    pub(crate) fn revision_key(&self) -> Revision {
        // Checked when the record was decoded.
        Revision(self.record.revision.clone())
    }

    /// Whether this record advertises one exact capability name.
    pub fn has_capability(&self, capability: &str) -> bool {
        self.extra.capabilities.iter().any(|candidate| candidate == capability)
    }
}

/// The `vm_kind` a `connect_info` answer reads as when the Worker sent none
/// (one that predates it) or sent a value that is not a string: it grants
/// nothing (only the exact `owner` owns the machine), as the connect answer's
/// own `unknown` (crate::link::ops).
pub const VM_KIND_UNKNOWN: &str = "unknown";

/// The `connect_info` answer as the generated `CloudConnectInfo`. The one
/// lenience: `vm_kind` absent or not a string reads as [`VM_KIND_UNKNOWN`]
/// (fail closed), so the link to a machine of an older Worker still comes
/// up. Every other catalog-required field is required.
pub(crate) fn decode_connect_info(op: &str, mut value: Value) -> Result<ConnectInfo, CloudError> {
    if let Some(fields) = value.as_object_mut()
        && !fields.get("vm_kind").is_some_and(Value::is_string)
    {
        fields.insert("vm_kind".into(), VM_KIND_UNKNOWN.into());
    }
    let mut info = decode_answer::<<CloudMachineConnectInfoOp as Op>::Result>(op, value)?;
    check_revision(op, &mut info.revision)?;
    Ok(info)
}

/// An answer's revision (a snapshot's, a `connect_info`'s) checked as a
/// [`Machine`]'s is: a decimal, leading zeros stripped; anything else is a
/// `bad_response`, since the generated types keep it as any string.
pub(crate) fn check_revision(op: &str, revision: &mut String) -> Result<(), CloudError> {
    *revision = Revision::try_from(std::mem::take(revision))
        .map_err(|e| CloudError::new(super::codes::BAD_RESPONSE, format!("{op}: {e}")))?
        .into();
    Ok(())
}

/// `cloud.machine.connect_info` (contract 1.7): how `cmux link` reaches a
/// machine. It carries no credential: the dial token is
/// `cloud.machine.link_token`, which only `cmux link` calls.
pub type ConnectInfo = CloudConnectInfo;

/// The checks the link makes on a [`ConnectInfo`].
pub trait ConnectFacts {
    /// The Worker said the signed-in caller owns this machine: only the
    /// exact value `owner`; missing or any other value is not the owner.
    fn caller_owns_vm(&self) -> bool;
    /// Whether the Cloud policy permits this server to dial one service.
    /// Service names are opaque wire values; callers must not infer access
    /// from machine state or display fields.
    fn has_service(&self, service: &str) -> bool;
    /// Whether the connected daemon advertised a capability for this
    /// control generation. Missing or unknown names fail closed.
    fn daemon_has_capability(&self, capability: &str) -> bool;
}

impl ConnectFacts for ConnectInfo {
    fn caller_owns_vm(&self) -> bool {
        self.vm_kind.as_str() == "owner"
    }

    fn has_service(&self, service: &str) -> bool {
        self.services.iter().any(|candidate| candidate.as_str() == service)
    }

    fn daemon_has_capability(&self, capability: &str) -> bool {
        self.daemon.capabilities.iter().any(|candidate| candidate == capability)
    }
}

/// The numeric order of two `cmux.wire/1` revisions (decimal strings of any
/// length): leading zeros carry nothing, then the longer is larger, then
/// the digits compare.
pub fn order(a: &str, b: &str) -> Ordering {
    fn digits(s: &str) -> &str {
        let s = s.trim_start_matches('0');
        if s.is_empty() { "0" } else { s }
    }
    let (a, b) = (digits(a), digits(b));
    a.len().cmp(&b.len()).then_with(|| a.cmp(b))
}

/// A checked `cmux.wire/1` revision (`^[0-9]+$`, leading zeros stripped),
/// ordered as a number ([`order`]). The projection keeps these for the
/// removals and listings it holds.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(try_from = "String", into = "String")]
pub struct Revision(String);

impl Revision {
    pub fn zero() -> Self {
        Self("0".into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<String> for Revision {
    type Error = String;

    fn try_from(s: String) -> Result<Self, String> {
        if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
            return Err(format!("{s:?} is not a decimal revision"));
        }
        // Leading zeros carry nothing; strip them so length orders first.
        let digits = s.trim_start_matches('0');
        Ok(Self(if digits.is_empty() { "0".into() } else { digits.to_owned() }))
    }
}

impl From<Revision> for String {
    fn from(r: Revision) -> String {
        r.0
    }
}

impl Ord for Revision {
    fn cmp(&self, other: &Self) -> Ordering {
        order(&self.0, &other.0)
    }
}

impl PartialOrd for Revision {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

#[cfg(test)]
mod tests;
