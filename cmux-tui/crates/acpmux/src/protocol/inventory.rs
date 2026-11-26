//! Typed input of the local, cache-only inventory subscription.

use schemars::JsonSchema;
use serde::Deserialize;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct InventoryWatchParams {
    pub enabled: bool,
}

// Only the owner's fixed cached-install registry lookup is accepted.
#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct InventoryRefreshParams {}

// CLI family evidence, never a profile, machine, session or command selector.
#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HarnessUpdatePlanParams {
    pub cli: String,
}
