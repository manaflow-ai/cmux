//! `secrets-v1` on the session daemon of a Cloud machine.

use std::path::Path;

use cmux_remote::workspace::WorkspaceService;

/// Where the host writes the carrier grant config when the daemon is given
/// none (`--carrier-grant-config`).
#[cfg(any(target_os = "linux", target_os = "android"))]
const DEFAULT_GRANT_CONFIG: &str = "/run/cmux/carrier-grant.json";

/// The daemon's workspace service. On a Cloud machine that knows its
/// platform id it also answers `secrets-v1`: items sealed to this daemon's
/// static key for this machine, written under `$HOME`. Its taken nonces are
/// kept under `state_dir`, the daemon's state folder. Only Linux writes
/// them, so elsewhere the daemon never advertises it.
#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn daemon_workspace_service(
    auth: &cmux_remote::identity::AuthDatabase,
    state_dir: &Path,
    grant_config: Option<&Path>,
) -> WorkspaceService {
    let grant = std::fs::read_to_string(grant_config.unwrap_or(Path::new(DEFAULT_GRANT_CONFIG)));
    let machine_id = machine_id(grant.ok().as_deref(), crate::coderouter_usage::machine_vm_id);
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from);
    match (machine_id, home) {
        (Some(machine_id), Some(home)) => {
            WorkspaceService::with_secrets(cmux_remote::secrets::MachineSecrets::new(
                &auth.identity(),
                machine_id,
                home,
                state_dir.to_path_buf(),
            ))
        }
        // No platform id: fail closed, `secrets-v1` is not advertised.
        _ => WorkspaceService::new(),
    }
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
pub(crate) fn daemon_workspace_service(
    _: &cmux_remote::identity::AuthDatabase,
    _: &Path,
    _: Option<&Path>,
) -> WorkspaceService {
    WorkspaceService::new()
}

/// This Cloud machine's platform `vm_…` id ([`machine_id`] from the host's carrier grant config,
/// else `CMUX_VM_ID`), or `None` off a Cloud machine (`cmux host share`, `platform_shares.rs`).
#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn this_machine_id() -> Option<String> {
    let grant = std::fs::read_to_string(DEFAULT_GRANT_CONFIG);
    machine_id(grant.ok().as_deref(), crate::coderouter_usage::machine_vm_id)
}

/// Only a Linux Cloud machine has a platform id of its own.
#[cfg(not(any(target_os = "linux", target_os = "android")))]
pub(crate) fn this_machine_id() -> Option<String> {
    None
}

/// The platform's `vm_…` id the device seals for: the carrier grant
/// config's `machine` (the id the carrier itself admits), else `CMUX_VM_ID`.
/// Never the provider's instance id.
#[cfg_attr(not(any(target_os = "linux", target_os = "android")), allow(dead_code))]
fn machine_id(
    grant_config: Option<&str>,
    vm_id: impl FnOnce() -> Option<String>,
) -> Option<String> {
    let platform = |id: &str| id.starts_with("vm_") && id.len() > 3;
    grant_config
        .and_then(|text| serde_json::from_str::<serde_json::Value>(text).ok())
        .and_then(|config| config.get("machine")?.as_str().map(str::to_owned))
        .filter(|id| platform(id))
        .or_else(|| vm_id().filter(|id| platform(id)))
}

#[cfg(all(test, any(target_os = "linux", target_os = "android")))]
mod tests {
    use super::*;

    const VM: &str = "vm_0123456789abcdefghij";

    #[test]
    fn the_grant_configs_machine_comes_first_and_a_provider_id_never_counts() {
        let grant = format!(r#"{{"issuer": "cmux:cloud:test", "machine": "{VM}", "team": "t"}}"#);
        assert_eq!(machine_id(Some(&grant), || Some("vm_other".into())).as_deref(), Some(VM));
        assert_eq!(machine_id(None, || Some(VM.into())).as_deref(), Some(VM));
        assert_eq!(machine_id(Some("not json"), || Some(VM.into())).as_deref(), Some(VM));
        // A provider instance id is not a platform id: nothing is advertised.
        assert_eq!(machine_id(None, || Some("i-0abc123".into())), None);
        assert_eq!(machine_id(None, || None), None);
    }

    #[test]
    fn a_daemon_with_only_the_grant_config_opens_a_delivery_sealed_for_its_vm_id() {
        let dir = tempfile::tempdir().unwrap();
        let (home, state) = (dir.path().join("home"), dir.path().join("state"));
        std::fs::create_dir_all(home.join(".cmux/machine-config")).unwrap();
        std::fs::create_dir_all(&state).unwrap();
        std::fs::write(
            home.join(".cmux/machine-config/status.json"),
            r#"{"state": "done", "secrets": {"declared": ["DEMO_KEY"]}}"#,
        )
        .unwrap();
        let grant = format!(r#"{{"issuer": "cmux:cloud:test", "machine": "{VM}", "team": "t"}}"#);
        let identity = cmux_remote::crypto::StaticIdentity::generate().unwrap();
        let machine = machine_id(Some(&grant), || None).unwrap();
        let secrets = cmux_remote::secrets::MachineSecrets::new(&identity, machine, home, state)
            .with_log(std::sync::Arc::new(|_| {}));
        let value = zeroize::Zeroizing::new("generated-0123456789".to_owned());
        let cmux_remote_protocol::WorkspaceRequest::ReplaceMachineSecrets { items } =
            cmux_remote::secrets::request::replace_machine_secrets(
                &identity.public_key(),
                VM,
                &[("DEMO_KEY".to_owned(), value)],
            )
            .unwrap()
        else {
            panic!("not a replace request");
        };
        assert_eq!(secrets.replace_machine_secrets(&items).unwrap(), 1);
    }
}
