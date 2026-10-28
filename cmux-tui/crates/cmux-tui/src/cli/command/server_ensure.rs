//! `server ensure` flags.

use super::{Flags, UsageError};
use crate::cli::lifecycle::ServerAction;
use crate::local_owner::EnsureWebSocket;

/// `server ensure [--terminal-reap-grace-seconds <n>] [--exit-with-pid <pid>] [--install-key-stdin]
/// [--restore-progress] [--replace-unresponsive] [--ws-loopback [--ws-allow-origin <origin>[,<origin>...]]]`: the
/// grace has the owner's own startup bounds, checked before any spawn.
pub(super) fn parse(flags: &mut Flags) -> Result<ServerAction, UsageError> {
    let install_key_stdin = flags.boolean("install-key-stdin");
    let progress = flags.boolean("restore-progress");
    let websocket = websocket(flags)?;
    let replace_unresponsive = flags.boolean("replace-unresponsive");
    let exit_with_pid = flags
        .take("exit-with-pid")
        .map(|value| crate::local_owner::resolve_exit_with_pid(&value))
        .transpose()
        .map_err(UsageError::new)?;
    let Some(value) = flags.take("terminal-reap-grace-seconds") else {
        return Ok(ServerAction::Ensure {
            terminal_reap_grace: None,
            exit_with_pid,
            install_key_stdin,
            progress,
            websocket,
            replace_unresponsive,
        });
    };
    let seconds = value
        .parse::<u64>()
        .map_err(|_| UsageError::new("--terminal-reap-grace-seconds must be an integer"))?;
    let grace =
        cmux_tui_core::validate_terminal_reap_grace(std::time::Duration::from_secs(seconds))
            .map_err(|error| UsageError::new(error.to_string()))?;
    Ok(ServerAction::Ensure {
        terminal_reap_grace: Some(grace),
        exit_with_pid,
        install_key_stdin,
        progress,
        websocket,
        replace_unresponsive,
    })
}

/// `--ws-loopback` (private app contract): an owner this call spawns opens
/// its WebSocket listener on 127.0.0.1 with a credential it mints itself
/// (spec/transports.md "App listener and page files"). `--ws-allow-origin`
/// adds the host page origins that may connect besides the listener's own: a
/// comma-separated list (the app's first-party pages, `cmux-page://cmux.<page>`;
/// an origin has no comma). One malformed member refuses the whole list.
fn websocket(flags: &mut Flags) -> Result<Option<EnsureWebSocket>, UsageError> {
    let loopback = flags.boolean("ws-loopback");
    let origins = flags.take("ws-allow-origin");
    match (loopback, origins) {
        (false, None) => Ok(None),
        (false, Some(_)) => Err(UsageError::new("--ws-allow-origin needs --ws-loopback")),
        (true, None) => Ok(Some(EnsureWebSocket { allow_origins: Vec::new() })),
        (true, Some(list)) => {
            let mut allow_origins = Vec::new();
            for origin in list.split(',') {
                let origin = cmux_tui_core::server::parse_websocket_origin(origin).ok_or_else(|| {
                    UsageError::new(
                        "--ws-allow-origin needs scheme://host[:port] (a comma-separated list), with no path; null is never allowed",
                    )
                })?;
                if !allow_origins.contains(&origin) {
                    allow_origins.push(origin);
                }
            }
            Ok(Some(EnsureWebSocket { allow_origins }))
        }
    }
}
