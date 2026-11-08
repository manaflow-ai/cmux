//! `agent hook status`: which hook helper the agents of this pane run
//! (W5-Q, bench round 4 #10).

use std::path::PathBuf;

use serde_json::Value;

/// The hook helper an agent started here runs. Not yet: none.
pub(super) fn pane_helper() -> Option<PathBuf> {
    None
}

/// The status `value` with `helper` naming `pane_helper`. Not yet: as it is.
pub(super) fn with_pane_helper(value: Value, _pane_helper: Option<PathBuf>) -> Value {
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
