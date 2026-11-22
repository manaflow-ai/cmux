//! The device side of `secrets-v1`: values sealed into the requests a
//! machine's daemon opens. A caller sends the request over its session to
//! that daemon (the carrier session); this module never sends anything.

use cmux_remote_protocol::WorkspaceRequest;

use super::seal::{self, Purpose, SealError};

/// `replace-machine-secrets` for the daemon whose static key is `daemon_key`
/// on machine `machine_id`: every `(name, value)` sealed on its own.
pub fn replace_machine_secrets(
    daemon_key: &[u8; 32],
    machine_id: &str,
    values: &[(String, zeroize::Zeroizing<String>)],
) -> Result<WorkspaceRequest, SealError> {
    let items = values
        .iter()
        .map(|(name, value)| {
            seal::seal(daemon_key, machine_id, Purpose::Secret, name, value.as_bytes())
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(WorkspaceRequest::ReplaceMachineSecrets { items })
}
