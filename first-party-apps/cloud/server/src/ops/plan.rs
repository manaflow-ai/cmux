//! `cloud.plan.get` and `cloud.usage.get`: both read the `limits` object of
//! `GET /api/vm` (the Cloud API has no separate plan or usage route for a
//! person). The same answer refreshes the machine projection.

use super::machine::fetch_list;
use crate::api::args;
use crate::api::{CloudError, ControlPlane, Ctx};
use serde_json::{Value, json};

pub(super) fn run<C: ControlPlane>(
    ctx: &mut Ctx<'_, C>,
    name: &str,
    raw: &Value,
) -> Result<Value, CloudError> {
    args::object(raw, &[])?;
    let limits = fetch_list(ctx)?.limits.unwrap_or_default();
    Ok(if name == "cloud.usage.get" {
        json!({
            "vmHoursUsed": limits.vm_hours_used,
            "vmHoursIncluded": limits.vm_hours_included,
            "savedVmLimit": limits.saved_vm_limit,
            "activeVmCount": limits.active_vm_count,
        })
    } else {
        json!({
            "planId": limits.plan_id,
            "maxActiveVms": limits.max_active_vms,
            "activeVmCount": limits.active_vm_count,
            "memoryOptionsMb": limits.memory_options_mb,
            "lockedMemoryOptionsMb": limits.locked_memory_options_mb,
            "memoryUpgradePlanId": limits.memory_upgrade_plan_id,
            "freeAccessWindowDays": limits.free_access_window_days,
            "freeAccessExpiresAt": limits.free_access_expires_at,
        })
    })
}
