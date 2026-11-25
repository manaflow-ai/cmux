//! Typed input of the local, cache-only inventory subscription.

use schemars::JsonSchema;
use serde::Deserialize;

#[derive(Deserialize, JsonSchema)]
// skew: strict schema only: keeps the web param type closed; serde ignores new fields
#[schemars(deny_unknown_fields)]
pub struct InventoryWatchParams {
    pub enabled: bool,
}

// Only the owner's fixed cached-install registry lookup is accepted.
#[derive(Deserialize, JsonSchema)]
// skew: strict local install control: a selector it ignored would refresh the wrong target
#[serde(deny_unknown_fields)]
pub struct InventoryRefreshParams {}

// CLI family evidence, never a profile, machine, session or command selector.
#[derive(Deserialize, JsonSchema)]
// skew: strict local update control: an ignored machine or session selector plans the wrong target
#[serde(deny_unknown_fields)]
pub struct HarnessUpdatePlanParams {
    pub cli: String,
}
