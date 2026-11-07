//! `secrets-v1` on the session daemon of a Cloud machine.

use cmux_remote::workspace::WorkspaceService;

/// The daemon's workspace service. On a Cloud machine (one that knows its
/// id) it also answers `secrets-v1`: items sealed to this daemon's static key
/// for this machine, written under `$HOME`.
/// Its taken nonces are kept under `state_dir`, the daemon's state folder.
pub(crate) fn daemon_workspace_service(
    auth: &cmux_remote::identity::AuthDatabase,
    state_dir: &std::path::Path,
) -> WorkspaceService {
    let machine_id = crate::coderouter_usage::machine_vm_id();
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    match (machine_id, home) {
        (Some(machine_id), Some(home)) => {
            WorkspaceService::with_secrets(cmux_remote::secrets::MachineSecrets::new(
                &auth.identity(),
                machine_id,
                home,
                crate::agent_start_host::cloud_etc().dir.clone(),
                state_dir.to_path_buf(),
            ))
        }
        _ => WorkspaceService::new(),
    }
}
