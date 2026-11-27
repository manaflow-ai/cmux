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

    /// W5-Q review (PR A finding 5): outside a cmux pane (no
    /// `CMUX_TUI_HOOK`: Settings > Agents, a devbox build script) the
    /// status keeps the installed helper, and a status read never writes a
    /// launcher file. In a pane it names the pane's helper as given.
    #[test]
    fn w5q_agent_hook_status_outside_a_pane_keeps_the_installed_helper() {
        assert_eq!(pane_helper_from(None), None, "outside a pane: no pane helper");
        let dir = std::env::temp_dir().join(format!("w5q-pane-helper-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let helper = dir.join("cmux-tui-hook");
        std::fs::write(&helper, "#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        assert_eq!(pane_helper_from(Some(helper.clone().into_os_string())), Some(helper));
        let _ = std::fs::remove_dir_all(dir);
    }
}
