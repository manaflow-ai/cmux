//! `server ensure` flags.

use super::{Flags, UsageError};
use crate::cli::lifecycle::ServerAction;
use crate::local_owner::EnsureWebSocket;

/// `server ensure [--terminal-reap-grace-seconds <n>] [--install-key-stdin]
/// [--restore-progress] [--ws-loopback [--ws-allow-origin <origin>]]`: the
/// grace has the owner's own startup bounds, checked before any spawn.
pub(super) fn parse(flags: &mut Flags) -> Result<ServerAction, UsageError> {
    let install_key_stdin = flags.boolean("install-key-stdin");
    let progress = flags.boolean("restore-progress");
    let websocket = websocket(flags)?;
    let Some(value) = flags.take("terminal-reap-grace-seconds") else {
        return Ok(ServerAction::Ensure {
            terminal_reap_grace: None,
            install_key_stdin,
            progress,
            websocket,
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
        install_key_stdin,
        progress,
        websocket,
    })
}

/// `--ws-loopback` (private app contract): an owner this call spawns opens
/// its WebSocket listener on 127.0.0.1 with a credential it mints itself
/// (spec/transports.md "App listener and page files"). `--ws-allow-origin`
/// adds the one host page origin that may connect besides the listener's own.
fn websocket(flags: &mut Flags) -> Result<Option<EnsureWebSocket>, UsageError> {
    let loopback = flags.boolean("ws-loopback");
    let origin = flags.take("ws-allow-origin");
    match (loopback, origin) {
        (false, None) => Ok(None),
        (false, Some(_)) => Err(UsageError::new("--ws-allow-origin needs --ws-loopback")),
        (true, None) => Ok(Some(EnsureWebSocket { allow_origin: None })),
        (true, Some(origin)) => match cmux_tui_core::server::parse_websocket_origin(&origin) {
            Some(origin) => Ok(Some(EnsureWebSocket { allow_origin: Some(origin) })),
            None => Err(UsageError::new(
                "--ws-allow-origin needs scheme://host[:port], with no path; null is never allowed",
            )),
        },
    }
}
