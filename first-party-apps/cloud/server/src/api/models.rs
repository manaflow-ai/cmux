//! Typed records of the cmux-next Cloud backend (`cmux.wire/1`,
//! plans/cmux-next/cloud-client-contract.md 1.2). Field names are the
//! backend's snake_case. Unknown fields are ignored; a missing optional
//! field is `None`. Timestamps are epoch milliseconds; revisions are
//! decimal strings that only grow per entity.

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum MachineStatus {
    #[default]
    Provisioning,
    Starting,
    Running,
    Pausing,
    Paused,
    Deleting,
    Failed,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Size {
    #[serde(default)]
    pub cpu: Option<u32>,
    #[serde(default)]
    pub memory_mb: Option<u64>,
    #[serde(default)]
    pub disk_mb: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Image {
    pub id: String,
    #[serde(default)]
    pub daemon_version: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IdlePolicy {
    #[serde(default)]
    pub idle_seconds: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MachineError {
    pub code: String,
    #[serde(default)]
    pub message: Option<String>,
    #[serde(default)]
    pub at: Option<i64>,
}

/// `CloudMachine`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Machine {
    pub id: String,
    #[serde(default)]
    pub team: Option<String>,
    #[serde(default)]
    pub creator: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub size: Option<Size>,
    #[serde(default)]
    pub status: MachineStatus,
    #[serde(default)]
    pub image: Option<Image>,
    /// The overlay host id; `None` until the machine is bound.
    #[serde(default)]
    pub host: Option<String>,
    #[serde(default)]
    pub classic: bool,
    #[serde(default)]
    pub created_at: Option<i64>,
    #[serde(default)]
    pub last_active_at: Option<i64>,
    #[serde(default)]
    pub idle_policy: Option<IdlePolicy>,
    #[serde(default)]
    pub error: Option<MachineError>,
    pub revision: Revision,
}

/// `CloudSnapshot`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Snapshot {
    pub id: String,
    #[serde(default)]
    pub machine: Option<String>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub size_mb: Option<u64>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub created_at: Option<i64>,
    pub revision: Revision,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanLimits {
    pub max_active: u32,
    pub max_saved: u32,
    #[serde(default)]
    pub memory_options_mb: Vec<u64>,
    #[serde(default)]
    pub locked_memory_options_mb: Vec<u64>,
    #[serde(default)]
    pub vm_hours_included: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PlanUsage {
    pub active: u32,
    pub saved: u32,
    #[serde(default)]
    pub vm_hours_used: Option<f64>,
    #[serde(default)]
    pub period_end: Option<i64>,
}

/// `CloudPlan`: limits and usage in one record (`cloud.usage.get` folded in).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Plan {
    pub plan_id: String,
    pub limits: PlanLimits,
    pub usage: PlanUsage,
}

/// `cloud.machine.list`: one page.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct MachinePage {
    pub machines: Vec<Machine>,
    #[serde(default)]
    pub next_cursor: Option<String>,
    /// The team's registry revision when the page was read.
    #[serde(default)]
    pub revision: Option<Revision>,
}

/// `cloud.machine.connect_info` (contract 1.7): how `cmux link` reaches a
/// machine. Peer data comes in every bound state, paused included.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ConnectInfo {
    pub machine: String,
    pub host: String,
    /// A restore or re-bind raises it; the link refuses a lower one.
    pub epoch: u64,
    pub state: MachineStatus,
    pub peer: Peer,
    /// This install's own tunnel into the VM's VPC; null = no tunnel path.
    #[serde(default)]
    pub gateway: Option<serde_json::Value>,
    /// What this caller may dial: `daemon`, `ssh`.
    pub services: Vec<String>,
    /// For one `hello` of `cmux link`. The server never passes it on: it
    /// is read here only so it can be dropped (contract 1.7: `cmux-cloud`
    /// never sees link tokens beyond this answer).
    #[serde(default, skip_serializing)]
    pub link_token: Option<serde_json::Value>,
    pub daemon: DaemonInfo,
    pub revision: Revision,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Peer {
    pub wg_public_key: String,
    pub overlay_address: String,
    #[serde(default)]
    pub vpc_endpoint: Option<String>,
    #[serde(default)]
    pub public_ipv6: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DaemonInfo {
    #[serde(default)]
    pub version: Option<String>,
    #[serde(default)]
    pub capabilities: Vec<String>,
}

/// A `cmux.wire/1` revision: a decimal string (`^[0-9]+$`), compared as a
/// number of any length.
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
        self.0.len().cmp(&other.0.len()).then_with(|| self.0.cmp(&other.0))
    }
}

impl PartialOrd for Revision {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}
