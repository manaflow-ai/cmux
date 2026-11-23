//! Densities, backdrops, the omnibar and managed keys: Swift `CustomDensitiesSetting`, `BackdropSelectionSetting`, `BrowserOmnibarSetting`, `ManagedKeyGuard`, `ManagedPreferences`.

use serde_json::Value;

use super::OpError;

/// The ops this area answers; `None` for an op of another area.
pub fn call(op: &str, request: &Value) -> Option<Result<Value, OpError>> {
    let _ = request;
    match op {
        _ => None,
    }
}
