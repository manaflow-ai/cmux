//! The account's machine cap, from a `limits` object (`GET /api/vm`'s). The server resolves it
//! from the plan's entitlements; the app never infers a cap from the machines it lists (#16012).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::json::int;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Limits {
    /// Most machines that may run at once. None: no cap. Zero: machines are closed on this plan
    /// (a zero is never "no cap").
    #[serde(default)]
    pub max_active_vms: Option<i64>,
    /// Machines running or starting now, as the server counts them.
    #[serde(default)]
    pub active_vm_count: i64,
    /// The plan that sets the cap (`free`, `go`, `pro`, `max`, `team`).
    #[serde(default)]
    pub plan_id: Option<String>,
    /// The memory sizes a create on this plan may ask for, smallest first, each once.
    #[serde(default)]
    pub memory_options_mb: Vec<i64>,
    /// The vCPUs the server gives each of those sizes, keyed by MiB.
    #[serde(default)]
    pub vcpus_by_memory_mb: BTreeMap<String, i64>,
    /// Sizes offered only with a plan upgrade, in MiB; None when the server sent none.
    #[serde(default)]
    pub locked_memory_options_mb: Option<Vec<i64>>,
}

/// The `limits` object. Each field on its own: one this client cannot read drops that field,
/// never the others. An unreadable cap reads as none, as a missing `limits` does (the server
/// still refuses).
pub fn read(value: &Value) -> Limits {
    let integers = |value: Option<&Value>| -> Option<Vec<i64>> {
        value?.as_array()?.iter().map(int).collect::<Option<Vec<_>>>()
    };
    let mut options = integers(value.get("memoryOptionsMb")).unwrap_or_default();
    options.retain(|mb| *mb > 0);
    options.sort_unstable();
    options.dedup();
    let vcpus = value
        .get("vcpusByMemoryMb")
        .and_then(Value::as_object)
        .and_then(|map| {
            map.iter()
                .map(|(key, value)| Some((key.clone(), int(value)?)))
                .collect::<Option<Vec<_>>>()
        })
        .unwrap_or_default()
        .into_iter()
        .filter_map(|(key, vcpus)| {
            let mb: i64 = key.parse().ok()?;
            (mb > 0 && vcpus > 0).then(|| (mb.to_string(), vcpus))
        })
        .collect();
    Limits {
        max_active_vms: value.get("maxActiveVms").and_then(int),
        active_vm_count: value.get("activeVmCount").and_then(int).unwrap_or(0),
        plan_id: value.get("planId").and_then(Value::as_str).map(str::to_owned),
        memory_options_mb: options,
        vcpus_by_memory_mb: vcpus,
        locked_memory_options_mb: integers(value.get("lockedMemoryOptionsMb")),
    }
}

/// Whether the plan pays for cmux Cloud: a named plan that is not `free`, and machines are not
/// closed on it (the same rule as the Mac's create gate). No cap is "no cap", which a paid plan
/// may have; only a zero closes machines.
pub fn pays_for_cloud(plan_id: Option<&str>, max_active_vms: Option<i64>) -> bool {
    let named = plan_id.is_some_and(|plan| {
        let plan = plan.to_lowercase();
        !plan.is_empty() && plan != "free"
    });
    named && max_active_vms.unwrap_or(1) > 0
}

#[cfg(test)]
mod tests;
