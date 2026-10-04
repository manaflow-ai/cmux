//! Typed records of the cmux Cloud API (`web/app/api/vm/**` responses).
//! Field names stay camelCase like the API so the page reads them as is.
//! Unknown fields are ignored; a missing optional field is `None`.

use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum MachineStatus {
    /// A create, restore or fork answer carries no status: the machine is coming up.
    #[default]
    Provisioning,
    Running,
    Failed,
    Paused,
    Destroyed,
    #[serde(other)]
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct Address {
    pub ipv4: Option<String>,
    pub ipv6: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Creator {
    pub user_id: String,
    pub display_name: Option<String>,
}

/// One machine (`GET /api/vm` row, `GET /api/vm/:id`, create, restore, fork).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Machine {
    pub id: String,
    #[serde(default)]
    pub provider: String,
    #[serde(default, deserialize_with = "status_or_default")]
    pub status: MachineStatus,
    #[serde(default)]
    pub display_name: Option<String>,
    #[serde(default)]
    pub slug: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub image: Option<String>,
    #[serde(default)]
    pub image_version: Option<String>,
    #[serde(default, deserialize_with = "number_or_none")]
    pub created_at: Option<f64>,
    #[serde(default)]
    pub address: Option<Address>,
    #[serde(default)]
    pub created_by: Option<Creator>,
    #[serde(default, deserialize_with = "number_or_none")]
    pub free_access_expires_at: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", try_from = "SnapshotWire")]
pub struct Snapshot {
    pub id: String,
    pub name: Option<String>,
    pub created_at: Option<Value>,
}

/// The snapshot route answers `snapshotId` and `id`; lists answer `id`.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotWire {
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    snapshot_id: Option<String>,
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    created_at: Option<Value>,
}

impl TryFrom<SnapshotWire> for Snapshot {
    type Error = String;

    fn try_from(w: SnapshotWire) -> Result<Self, String> {
        let id = w.snapshot_id.or(w.id).ok_or("a snapshot has no id")?;
        Ok(Self { id, name: w.name, created_at: w.created_at })
    }
}

/// `GET /api/vm/:id/stats` and the `POST /api/vm/:id/resize` answer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Stats {
    pub state: String,
    #[serde(default)]
    pub cpus: Option<f64>,
    #[serde(default)]
    pub cpu_percent: Option<f64>,
    #[serde(default)]
    pub load_average1m: Option<f64>,
    #[serde(default)]
    pub memory_total_mb: Option<f64>,
    #[serde(default)]
    pub memory_used_mb: Option<f64>,
    #[serde(default)]
    pub disk_total_mb: Option<f64>,
    #[serde(default)]
    pub disk_used_mb: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_disk_mb: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_memory_mb: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_vcpus: Option<f64>,
}

/// The `limits` object of `GET /api/vm`: plan and usage come from it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct Limits {
    #[serde(default)]
    pub plan_id: Option<String>,
    #[serde(default)]
    pub max_active_vms: Option<i64>,
    #[serde(default)]
    pub active_vm_count: Option<i64>,
    #[serde(default)]
    pub memory_options_mb: Vec<i64>,
    #[serde(default)]
    pub locked_memory_options_mb: Vec<i64>,
    #[serde(default)]
    pub memory_upgrade_plan_id: Option<String>,
    #[serde(default)]
    pub free_access_window_days: Option<i64>,
    #[serde(default, deserialize_with = "number_or_none")]
    pub free_access_expires_at: Option<f64>,
    #[serde(default)]
    pub vm_hours_included: Option<f64>,
    #[serde(default)]
    pub vm_hours_used: Option<f64>,
    #[serde(default)]
    pub saved_vm_limit: Option<i64>,
}

/// `GET /api/vm`.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct MachineList {
    pub vms: Vec<Machine>,
    #[serde(default)]
    pub limits: Option<Limits>,
}

fn number_or_none<'de, D: Deserializer<'de>>(d: D) -> Result<Option<f64>, D::Error> {
    Ok(Value::deserialize(d)?.as_f64())
}

fn status_or_default<'de, D: Deserializer<'de>>(d: D) -> Result<MachineStatus, D::Error> {
    Ok(Option::<MachineStatus>::deserialize(d)?.unwrap_or_default())
}
