//! Which daemon socket a CLI call reaches: `--socket`, `--session`, a
//! Chief's rule (cli/chief_target.rs), `CMUX_TUI_SOCKET`, then the app this
//! CLI belongs to. A socket the caller names is the only one tried: the
//! first explicit route wins and is never replaced by a default (cx-siev);
//! the app-side rule is cli/app.rs `command_socket`.

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
    // `CMUX_SOCKET_PATH` names one app; its session is that app's own, never
    // a default session (cx-siev): with nothing that names the app's
    // session, the call fails instead of reaching `cmux-app` or `main`.
    let app_socket_named = env("CMUX_SOCKET_PATH")
        .and_then(|value| value.into_string().ok())
        .is_some_and(|value| !value.trim().is_empty());
    // The `cmux` bundled in a cmux app talks to that app's session.
    #[cfg(target_os = "macos")]
    if let Some(identity) = crate::app_identity::AppIdentity::detect(
        |name| env(name).and_then(|value| value.into_string().ok()),
        std::env::current_exe().ok().as_deref(),
    ) {
        let names_session = identity.bundle_id.is_some() || identity.tag.is_some();
        if (names_session || !app_socket_named)
            && let Some(path) = crate::app_identity::app_daemon_socket(&identity)
        {
            return Ok((path, true));
        }
    }
    if app_socket_named {
        return Err(AppSocketOnly.into());
    }
    Ok((cmux_tui_core::server::try_default_socket_path("main")?, true))
}

/// `CMUX_SOCKET_PATH` names an app socket and nothing names that app's
/// session: the typed `socket.no_daemon` failure (wire.rs), never a default.
#[derive(Debug)]
pub(in crate::cli) struct AppSocketOnly;

impl std::fmt::Display for AppSocketOnly {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(crate::localization::catalog().cli_connection.app_socket_only())
    }
}

impl std::error::Error for AppSocketOnly {}
