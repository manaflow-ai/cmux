//! The state root of the carrier's own files: the tunnel hub socket
//! (`<root>/carrier/tunnel.sock`), the device's carrier key
//! (`<root>/carrier/ssh`) and the connect log (`<root>/carrier/connect.log`).
//!
//! The hub is run by the app's `cmux link serve`, on its link state
//! directory `<app daemon state dir>/link` (`link::carrier_tunnel::hub_socket`).
//! The app gives its own dials that directory as `CMUX_TUI_STATE_DIR`
//! (CmuxNext `CloudCarrierDial`), but the same app's bundled `cmux` run from
//! any other shell (the failover probe's `carrier capabilities` and
//! `cloud start-chat --carrier-fault`) has no such variable: it read
//! cmux-tui's default root while a NIGHTLY's link served the hub under
//! `cmux-next/tags/<tag>/tui`, so capabilities said `no_tunnel` with the hub
//! running (cmuxterm-hq probe cloud-carrier-ssh-failover, run 43654794835).
//! So without the variable the root is the daemon state directory of the
//! app bundle this `cmux` ships in, the one its link and daemon run on.

use std::path::{Path, PathBuf};

use crate::app_identity::AppIdentity;

/// `CMUX_TUI_STATE_DIR`, else the daemon state directory of this `cmux`'s
/// own app ([`AppIdentity::daemon_state_dir_in`], macOS), else cmux-tui's
/// default root.
pub(super) fn state_root() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        let exe = std::env::current_exe().ok();
        let home = std::env::var_os("HOME").filter(|h| !h.is_empty()).map(PathBuf::from);
        state_root_with(
            |key| std::env::var(key).ok(),
            exe.as_deref(),
            home.as_deref(),
            cmux_tui_core::platform::workspace_state_dir,
        )
    }
    #[cfg(not(target_os = "macos"))]
    {
        cmux_tui_core::platform::workspace_state_dir()
    }
}

/// [`state_root`] for the environment `env`, the executable `exe`, the user
/// home `home` and cmux-tui's root `default` (which itself honors
/// `CMUX_TUI_STATE_DIR`).
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub(super) fn state_root_with(
    env: impl Fn(&str) -> Option<String>,
    exe: Option<&Path>,
    home: Option<&Path>,
    default: impl FnOnce() -> Option<PathBuf>,
) -> Option<PathBuf> {
    if env("CMUX_TUI_STATE_DIR").is_some_and(|dir| !dir.is_empty()) {
        return default();
    }
    let app = home.and_then(|home| AppIdentity::detect(&env, exe)?.daemon_state_dir_in(home));
    app.or_else(default)
}

#[cfg(test)]
#[path = "state_root_tests.rs"]
mod tests;
