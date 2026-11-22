//! Which daemon socket a CLI call reaches: `--socket`, `--session`, a
//! Chief's rule (cli/chief_target.rs), `CMUX_TUI_SOCKET`, then the app this
//! CLI belongs to.

use std::path::PathBuf;

use super::super::GlobalArgs;

/// Resolve a socket and report whether it belongs to cmux's private runtime
/// directory. Environment-selected and explicit paths remain caller-managed.
pub(in crate::cli) fn resolve_socket_with_origin(
    global: &GlobalArgs,
) -> anyhow::Result<(PathBuf, bool)> {
    resolve_socket_with_env(global, |name| std::env::var_os(name))
}

pub(in crate::cli) fn resolve_socket_with_env(
    global: &GlobalArgs,
    env: impl Fn(&str) -> Option<std::ffi::OsString>,
) -> anyhow::Result<(PathBuf, bool)> {
    if let Some(path) = &global.socket {
        return Ok((path.clone(), false));
    }
    if let Some(session) = &global.session {
        // The bundling app starts its own session under the Darwin per-user
        // temp directory, whatever this process's TMPDIR is.
        #[cfg(target_os = "macos")]
        if let Some(identity) = crate::app_identity::AppIdentity::detect(
            |name| env(name).and_then(|value| value.into_string().ok()),
            std::env::current_exe().ok().as_deref(),
        ) && identity.daemon_session().as_deref() == Some(session.as_str())
            && let Some(path) = crate::app_identity::app_daemon_socket(&identity)
        {
            return Ok((path, true));
        }
        return Ok((cmux_tui_core::server::try_default_socket_path(session)?, true));
    }
    // A Chief's call: the app's daemon while the app runs, else the Chief's
    // owner daemon (chief_target.rs).
    if let Some(path) = super::super::chief_target::daemon_socket(
        |name| env(name).and_then(|value| value.into_string().ok()),
        super::super::chief_target::is_socket,
    ) {
        return Ok((path, false));
    }
    for name in ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"] {
        if let Some(path) = env(name)
            && !path.is_empty()
        {
            return Ok((PathBuf::from(path), false));
        }
    }
    // The `cmux` bundled in a cmux app talks to that app's session.
    #[cfg(target_os = "macos")]
    if let Some(identity) = crate::app_identity::AppIdentity::detect(
        |name| env(name).and_then(|value| value.into_string().ok()),
        std::env::current_exe().ok().as_deref(),
    ) && let Some(path) = crate::app_identity::app_daemon_socket(&identity)
    {
        return Ok((path, true));
    }
    Ok((cmux_tui_core::server::try_default_socket_path("main")?, true))
}
