//! `agent hook status`: which hook helper the agents of this pane run
//! (W5-Q, bench round 4 #10).
//!
//! `agent hook install` writes one shared helper per user and points the
//! harness configs at it; that helper runs whichever build installed it
//! last. An agent started in a cmux terminal runs this daemon build's own
//! helper instead (`CMUX_TUI_HOOK`, own_build_helpers.rs). In a cmux pane the
//! status names that one as `helper`, and the shared one as
//! `installed_helper`; outside a pane it is unchanged. When the pane's
//! helper is missing or cannot run (its build folder was deleted), the
//! status fails and says so. Unix only, as the own-build helpers are.

use std::ffi::OsString;
use std::path::PathBuf;

use serde_json::{Value, json};

/// The hook helper of the pane `agent hook status` runs in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) enum PaneHelper {
    /// Not in a cmux pane (no `CMUX_TUI_HOOK`), or the pane runs the shared
    /// helper itself: the status is as `agent hook install` reports it.
    Outside,
    /// The pane's agents run this build's own helper at this path.
    Runs(PathBuf),
    /// `CMUX_TUI_HOOK` names a helper that is missing or cannot run (its
    /// build folder was deleted): the pane's agents send no hook events.
    Broken(PathBuf),
}

/// The hook helper an agent started in this pane runs: the `CMUX_TUI_HOOK`
/// the pane carries (its daemon's own build).
pub(super) fn pane_helper() -> PaneHelper {
    pane_helper_from(std::env::var_os("CMUX_TUI_HOOK"))
}

/// [`pane_helper`] for the `CMUX_TUI_HOOK` value `inherited`. It only reads:
/// a status call never writes a launcher file.
fn pane_helper_from(inherited: Option<OsString>) -> PaneHelper {
    // An empty value is no pane helper: the hook command then runs the
    // shared helper (`${CMUX_TUI_HOOK:-...}`).
    let Some(inherited) = inherited.filter(|value| !value.is_empty()) else {
        return PaneHelper::Outside;
    };
    if let Some(path) = crate::own_build_helpers::inherited_hook_helper(Some(inherited.clone())) {
        return PaneHelper::Runs(path);
    }
    let path = PathBuf::from(inherited);
    if path.is_absolute() && crate::agent_hook_install::is_executable_file(&path) {
        // It runs: it is the shared helper itself.
        PaneHelper::Outside
    } else {
        PaneHelper::Broken(path)
    }
}

/// The status `value` for `pane`, and whether it is a fault. With a pane
/// helper, `helper` names it and the shared helper `agent hook install`
/// writes is `installed_helper`. A broken pane helper also adds the
/// reason, in `catalog`'s language, to `errors`, and is a fault.
pub(super) fn with_pane_helper(
    mut value: Value,
    pane: PaneHelper,
    catalog: &crate::localization::Catalog,
) -> (Value, bool) {
    let (path, broken) = match pane {
        PaneHelper::Outside => return (value, false),
        PaneHelper::Runs(path) => (path, false),
        PaneHelper::Broken(path) => (path, true),
    };
    if let Some(object) = value.as_object_mut() {
        let installed = object.remove("helper").unwrap_or(Value::Null);
        object.insert("helper".into(), json!(path));
        object.insert("installed_helper".into(), installed);
        if broken {
            let reason = catalog
                .pane_cli
                .agent_hook_pane_helper_missing
                .replace("{path}", &path.display().to_string());
            match object.get_mut("errors").and_then(Value::as_array_mut) {
                Some(errors) => errors.push(json!(reason)),
                None => {
                    object.insert("errors".into(), json!([reason]));
                }
            }
        }
    }
    (value, broken)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// W5-Q (bench r4 #10): `agent hook status` named the shared helper that
    /// `agent hook install` writes (it ran another app's CLI), not the
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
        let english = crate::localization::catalog_for_locale("en_US.UTF-8");
        let (shown, failed) = with_pane_helper(status.clone(), PaneHelper::Runs(pane), english);
        assert!(!failed);
        assert_eq!(shown["helper"], "/opt/r4/cmux-tui-hook", "{shown}");
        assert_eq!(shown["installed_helper"], "/home/u/.local/share/cmux-tui/bin/cmux-tui-hook");
        assert_eq!(
            with_pane_helper(status.clone(), PaneHelper::Outside, english),
            (status.clone(), false),
            "no pane helper: unchanged"
        );
    }

    /// W5-Q: outside a cmux pane (no `CMUX_TUI_HOOK`: a build script) the
    /// status keeps the installed helper, and a status read never writes a
    /// launcher file. In a pane it names the pane's helper as given.
    #[test]
    fn w5q_agent_hook_status_outside_a_pane_keeps_the_installed_helper() {
        use std::os::unix::fs::PermissionsExt as _;

        assert_eq!(pane_helper_from(None), PaneHelper::Outside, "outside a pane: no pane helper");
        assert_eq!(pane_helper_from(Some(OsString::new())), PaneHelper::Outside, "empty: shared");
        let dir = std::env::temp_dir().join(format!("w5q-pane-helper-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let helper = dir.join("cmux-tui-hook");
        std::fs::write(&helper, "#!/bin/sh\n").unwrap();
        std::fs::set_permissions(&helper, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(
            pane_helper_from(Some(helper.clone().into_os_string())),
            PaneHelper::Runs(helper)
        );
        let _ = std::fs::remove_dir_all(dir);
    }

    /// W5-Q review (w5qa2-1): a pane whose `CMUX_TUI_HOOK` names a helper of
    /// a deleted build runs no hooks. The status names that helper and
    /// fails with a localized reason; it does not show the shared helper as
    /// if all were well.
    #[test]
    fn w5q_agent_hook_status_reports_a_deleted_pane_helper_as_a_fault() {
        let gone = std::env::temp_dir()
            .join(format!("w5q-deleted-build-{}", std::process::id()))
            .join("cmux-tui-hook");
        assert_eq!(
            pane_helper_from(Some(gone.clone().into_os_string())),
            PaneHelper::Broken(gone.clone())
        );
        let status = json!({
            "action": "status",
            "helper": "/home/u/.local/share/cmux-tui/bin/cmux-tui-hook",
            "errors": [],
        });
        let english = crate::localization::catalog_for_locale("en_US.UTF-8");
        let (shown, failed) =
            with_pane_helper(status.clone(), PaneHelper::Broken(gone.clone()), english);
        assert!(failed, "{shown}");
        assert_eq!(shown["helper"], json!(gone), "{shown}");
        assert_eq!(shown["installed_helper"], "/home/u/.local/share/cmux-tui/bin/cmux-tui-hook");
        let error = shown["errors"][0].as_str().unwrap_or_default();
        assert!(
            error.contains(&gone.display().to_string()) && error.contains("missing"),
            "{error}"
        );
        let japanese = crate::localization::catalog_for_locale("ja_JP.UTF-8");
        let (shown, _) = with_pane_helper(status, PaneHelper::Broken(gone.clone()), japanese);
        let error = shown["errors"][0].as_str().unwrap_or_default();
        assert!(
            error.contains(&gone.display().to_string()) && error.contains("見つからない"),
            "{error}"
        );
    }
}
