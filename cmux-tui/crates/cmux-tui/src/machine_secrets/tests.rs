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
