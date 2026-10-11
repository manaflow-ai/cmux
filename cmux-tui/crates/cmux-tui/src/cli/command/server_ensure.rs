//! `server ensure` flags.

use super::{Flags, UsageError};
use crate::cli::lifecycle::ServerAction;

/// `server ensure [--terminal-reap-grace-seconds <n>] [--install-key-stdin]`:
/// the grace has the owner's own startup bounds, checked before any spawn.
pub(super) fn parse(flags: &mut Flags) -> Result<ServerAction, UsageError> {
    let install_key_stdin = flags.boolean("install-key-stdin");
    let Some(value) = flags.take("terminal-reap-grace-seconds") else {
        return Ok(ServerAction::Ensure { terminal_reap_grace: None, install_key_stdin });
    };
    let seconds = value
        .parse::<u64>()
        .map_err(|_| UsageError::new("--terminal-reap-grace-seconds must be an integer"))?;
    let grace =
        cmux_tui_core::validate_terminal_reap_grace(std::time::Duration::from_secs(seconds))
            .map_err(|error| UsageError::new(error.to_string()))?;
    Ok(ServerAction::Ensure { terminal_reap_grace: Some(grace), install_key_stdin })
}
