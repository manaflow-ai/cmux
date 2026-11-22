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
