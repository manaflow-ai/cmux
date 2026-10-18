//! Typed input of the local, cache-only inventory subscription.

use schemars::JsonSchema;
use serde::Deserialize;

#[derive(Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct InventoryWatchParams {
    pub enabled: bool,
}
