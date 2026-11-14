//! `agent hook status`: which hook helper the agents of this pane run
//! (W5-Q, bench round 4 #10).
//!
//! `agent hook install` writes one shared helper per user and points the
//! harness configs at it; that helper runs whichever build installed it
//! last. An agent started in a cmux terminal runs this daemon build's own
//! helper instead (`CMUX_TUI_HOOK`, own_build_helpers.rs). In a cmux pane the
//! status names that one as `helper`, and the shared one as
//! `installed_helper`; outside a pane it is unchanged. Unix only, as the
//! own-build helpers are.

use std::ffi::OsString;
use std::path::PathBuf;

use serde_json::{Value, json};

/// The hook helper an agent started in this pane runs: the `CMUX_TUI_HOOK`
/// the pane carries (its daemon's own build). Outside a cmux pane there is
/// none, and the status keeps the installed helper.
pub(super) fn pane_helper() -> Option<PathBuf> {
    pane_helper_from(std::env::var_os("CMUX_TUI_HOOK"))
}

/// [`pane_helper`] for the `CMUX_TUI_HOOK` value `inherited`. It only reads:
/// a status call never writes a launcher file.
pub(super) fn pane_helper_from(inherited: Option<OsString>) -> Option<PathBuf> {
    crate::own_build_helpers::inherited_hook_helper(inherited)
}

/// The status `value` with `helper` naming `pane_helper` and the shared
/// helper `agent hook install` writes as `installed_helper`. Without a pane
/// helper the value is as it is.
pub(super) fn with_pane_helper(mut value: Value, pane_helper: Option<PathBuf>) -> Value {
    let Some(pane) = pane_helper else { return value };
    if let Some(object) = value.as_object_mut() {
        let installed = object.remove("helper").unwrap_or(Value::Null);
        object.insert("helper".into(), json!(pane));
        object.insert("installed_helper".into(), installed);
    }
    value
}

#[cfg(test)]
mod tests;
