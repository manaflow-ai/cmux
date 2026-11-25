use super::*;

#[test]
fn connected_target_is_deduplicated() {
    let mut runtime = MachineRuntime::new(PathBuf::from("/tmp/current.sock"), Vec::new());
    let first = runtime.connect_machine("dev@mini.local").unwrap();
    let second = runtime.connect_machine("dev@mini.local").unwrap();
    assert_eq!(first, second);
    assert_eq!(runtime.snapshot(runtime.initial_key()).machines.len(), 2);
}

#[test]
fn typed_ssh_command_prefix_adds_the_same_host_alias() {
    let mut runtime = MachineRuntime::new(PathBuf::from("/tmp/current.sock"), Vec::new());
    let command = runtime.connect_machine("ssh build-host").unwrap();
    let alias = runtime.connect_machine("build-host").unwrap();

    assert_eq!(command, alias);
    assert_eq!(runtime.name(command), Some("build-host"));
}

#[test]
fn client_catalog_machine_rename_is_session_local() {
    let machine = MachineConfig {
        id: "mini".into(),
        name: "Mini".into(),
        subtitle: "ssh".into(),
        target: MachineTargetConfig::Unix { socket: PathBuf::from("/tmp/mini.sock") },
    };
    let mut runtime = MachineRuntime::new(PathBuf::from("/tmp/current.sock"), vec![machine]);
    let key = runtime.snapshot(runtime.initial_key()).machines[1].key;

    assert_eq!(runtime.rename_machine(key, "  Build box  ").unwrap(), "Build box");
    assert_eq!(runtime.name(key), Some("Build box"));
    assert!(runtime.ui_state(runtime.initial_key()).is_client_machine_renamable(key));
}

#[test]
fn configured_targets_are_deduplicated_in_one_pass() {
    let machine = MachineConfig {
        id: "mini".into(),
        name: "Mini".into(),
        subtitle: "local".into(),
        target: MachineTargetConfig::Unix { socket: PathBuf::from("/tmp/mini.sock") },
    };
    let runtime =
        MachineRuntime::new(PathBuf::from("/tmp/current.sock"), vec![machine.clone(), machine]);

    assert_eq!(runtime.snapshot(runtime.initial_key()).machines.len(), 2);
}

#[test]
fn prototype_creation_sources_add_local_catalog_entries_without_provisioning() {
    let mut runtime = MachineRuntime::with_creation_sources(
        PathBuf::from("/tmp/current.sock"),
        Vec::new(),
        vec![MachineCreationSourceConfig {
            id: "docker".into(),
            name: "Docker".into(),
            subtitle: "container prototype".into(),
        }],
    );
    let active = runtime.initial_key();

    let ui = runtime.ui_state(active);
    assert!(ui.snapshot.capabilities.create);
    assert_eq!(ui.creation_sources[0].id, "docker");

    let (first, first_name) = runtime.create_from("docker").unwrap();
    let (second, second_name) = runtime.create_from("docker").unwrap();
    assert_ne!(first, second);
    assert_eq!(first_name, "Docker 1");
    assert_eq!(second_name, "Docker 2");
    let snapshot = runtime.snapshot(active);
    assert_eq!(snapshot.machines.len(), 3);
    assert_eq!(snapshot.machines[1].id, "prototype:docker:1");
    assert!(matches!(
        runtime.entry(first).map(|entry| &entry.target),
        Some(MachineTargetConfig::Unix { socket }) if socket == &PathBuf::from("/tmp/current.sock")
    ));
}

#[test]
fn external_catalog_has_no_implicit_machine_and_uses_disjoint_keys() {
    let machine = MachineConfig {
        id: "mini".into(),
        name: "Mini".into(),
        subtitle: "local".into(),
        target: MachineTargetConfig::Unix { socket: PathBuf::from("/tmp/mini.sock") },
    };
    let runtime = MachineRuntime::external(vec![machine], false);
    let snapshot = runtime.snapshot_with_active(None);

    assert_eq!(snapshot.machines.len(), 1);
    assert!(snapshot.machines[0].key.0 >= CLIENT_MACHINE_KEY_START);
    assert_eq!(snapshot.active, None);
    assert!(!snapshot.capabilities.connect);
}

#[test]
fn disabled_external_catalog_rejects_ephemeral_targets() {
    let mut runtime = MachineRuntime::external(Vec::new(), false);
    let error = runtime.connect_machine("mini.local").unwrap_err().to_string();
    assert!(error.contains("cannot connect external machines"), "{error}");
}

#[cfg(unix)]
#[test]
fn ssh_machine_connection_uses_managed_bootstrap_and_fail_closed_policy() {
    let options = managed_ssh_options(
        "mini.local",
        Some("dev"),
        Some(2200),
        Some(Path::new("/tmp/cloud key")),
        "agents",
        "/opt/cmux-tui",
    )
    .unwrap();

    assert_eq!(options.destination, "dev@mini.local:2200");
    assert_eq!(options.session, "agents");
    assert_eq!(options.remote_binary, "/opt/cmux-tui");
    for option in [
        "BatchMode=yes",
        "StrictHostKeyChecking=yes",
        "ForwardAgent=no",
        "ForwardX11=no",
        "ClearAllForwardings=yes",
    ] {
        assert!(options.ssh_args.windows(2).any(|pair| pair == ["-o", option]));
    }
    assert!(options.ssh_args.windows(2).any(|pair| pair == ["-i", "/tmp/cloud key"]));
    assert!(
        managed_ssh_options("mini.local", None, None, None, "agents", "/opt/cmux tui").is_err()
    );
}

/// These runs turn forwarding off, so they must never become the shared
/// ControlMaster that an interactive session to the same host reuses.
#[cfg(unix)]
#[test]
fn managed_machine_connection_uses_hardened_ssh_argv() {
    let options =
        managed_ssh_options("mini.local", None, None, None, "agents", "/opt/cmux-tui").unwrap();

    assert!(options.ssh_args.windows(2).any(|pair| pair == ["-o", "ControlMaster=no"]));
}
