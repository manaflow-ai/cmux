//! `agent hook status`: which hook helper the agents of this pane run
//! (W5-Q, bench round 4 #10).
//!
//! `agent hook install` writes one shared helper per user and points the
//! harness configs at it; that helper runs whichever build installed it
//! last. An agent started in a cmux terminal runs this daemon build's own
//! helper instead (`CMUX_TUI_HOOK`, own_build_helpers.rs). The status names
//! that one as `helper`, and the shared one as `installed_helper`.

use std::path::PathBuf;

use serde_json::{Value, json};

/// The hook helper an agent started here runs: the `CMUX_TUI_HOOK` the
/// pane carries (its daemon's own build), else this build's own helper.
pub(super) fn pane_helper() -> Option<PathBuf> {
    let executable = crate::claude_wrapper::current_executable().ok()?;
    crate::own_build_helpers::launch_hook_helper(&executable, std::env::var_os("CMUX_TUI_HOOK"))
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
mod tests {
    use serde_json::json;

    use super::*;

    /// W5-Q (bench r4 #10): `agent hook status` named the shared helper that
    /// `agent hook install` writes (it ran the NIGHTLY app's CLI), not the
    /// helper this pane's agents run (`CMUX_TUI_HOOK`, this build's own).
    /// `helper` is now the pane's; the shared one is `installed_helper`.
    #[test]
    fn w5q_agent_hook_status_names_the_panes_own_helper() {
        let status = json!({
            "action": "status",
            "helper": "/home/u/.local/share/cmux-tui/bin/cmux-tui-hook",
            "providers": [],
            "skipped": [],
            "errors": [],
        });
        let pane = PathBuf::from("/opt/r4/cmux-tui-hook");
        let shown = with_pane_helper(status.clone(), Some(pane));
        assert_eq!(shown["helper"], "/opt/r4/cmux-tui-hook", "{shown}");
        assert_eq!(shown["installed_helper"], "/home/u/.local/share/cmux-tui/bin/cmux-tui-hook");
        assert_eq!(with_pane_helper(status.clone(), None), status, "no pane helper: unchanged");
    }
}
