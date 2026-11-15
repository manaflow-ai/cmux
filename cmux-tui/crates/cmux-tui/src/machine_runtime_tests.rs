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
fn ssh_config_discovery_follows_includes_and_skips_patterns() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let ssh_root = home.join(".ssh");
    let include_root = ssh_root.join("hosts");
    fs::create_dir_all(&include_root).unwrap();
    fs::write(
        ssh_root.join("config"),
        "Include hosts/*.conf\nHost buildbox *.internal !blocked duplicate\n",
    )
    .unwrap();
    fs::write(include_root.join("a.conf"), "Host mini duplicate\n  HostName 192.0.2.10\n").unwrap();
    fs::write(include_root.join("b.conf"), "Host=quoted-host # note\n").unwrap();

    assert_eq!(
        ssh_config_hosts_from_path(&ssh_root.join("config"), &ssh_root, home),
        vec!["buildbox", "duplicate", "mini", "quoted-host"]
    );
}

#[test]
fn ssh_config_discovery_reads_each_hosts_first_host_name() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let ssh_root = home.join(".ssh");
    fs::create_dir_all(&ssh_root).unwrap();
    fs::write(
        ssh_root.join("config"),
        "Host gh\n  HostName github.com\nHost gh\n  HostName example.com\n\
             Host mini mini-b\n  HostName %h.tail1234.ts.net\nHost *.corp\n  HostName x\n\
             Match host plain\n  HostName y\nHost plain\n",
    )
    .unwrap();
    let host = |alias: &str, host_name: Option<&str>| SshConfigHost {
        alias: alias.to_owned(),
        host_name: host_name.map(str::to_owned),
    };
    assert_eq!(
        ssh_config_targets_from_path(&ssh_root.join("config"), &ssh_root, home),
        vec![
            host("gh", Some("github.com")),
            host("mini", Some("mini.tail1234.ts.net")),
            host("mini-b", Some("mini-b.tail1234.ts.net")),
            host("plain", None),
        ]
    );
}

/// Writes each `(file, lines)` under a scratch `~/.ssh` and reads the
/// config's hosts with their HostNames.
fn host_names_of(files: &[(&str, &[&str])]) -> Vec<(String, Option<String>)> {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let ssh_root = home.join(".ssh");
    fs::create_dir_all(&ssh_root).unwrap();
    for (file, lines) in files {
        fs::write(ssh_root.join(file), lines.join("\n") + "\n").unwrap();
    }
    ssh_config_targets_from_path(&ssh_root.join("config"), &ssh_root, home)
        .into_iter()
        .map(|h| (h.alias, h.host_name))
        .collect()
}

fn named(alias: &str, host_name: &str) -> (String, Option<String>) {
    (alias.to_owned(), Some(host_name.to_owned()))
}

#[test]
fn a_host_name_from_an_include_counts_where_the_include_stands() {
    // `early` comes before `gh`'s block, so its HostName wins. `inside`
    // is read inside `lab`'s block, so it names `lab` and never
    // `target` or `other` (ssh reads it only for lab). `loop` includes
    // the config again, which stops.
    let config: &[&str] = &[
        "Include early",
        "Host gh",
        "  HostName example.com",
        "Host lab",
        "  Include inside",
        "Host lab2",
        "  Include loop",
        "Host target",
        "  HostName target.internal",
    ];
    let names = host_names_of(&[
        ("config", config),
        ("early", &["Host gh", "  HostName github.com"]),
        ("inside", &["HostName 10.0.4.2", "Host target other", "  HostName github.com"]),
        ("loop", &["Include config", "HostName lab2.internal"]),
    ]);
    assert_eq!(
        names,
        vec![
            named("gh", "github.com"),
            named("lab", "10.0.4.2"),
            named("lab2", "lab2.internal"),
            named("target", "target.internal"),
            ("other".to_owned(), None),
        ]
    );
}

#[test]
fn a_negated_host_keeps_its_block_and_includes_from_that_host() {
    let config: &[&str] = &[
        "Host lab !lab",
        "  HostName github.com",
        "Host box gpu.corp !*.corp",
        "  HostName gitlab.com",
        "  Include under",
        "Host lab",
        "  HostName lab.internal",
        "Host gpu.corp",
        "  HostName 10.0.0.9",
    ];
    let names = host_names_of(&[("config", config), ("under", &["HostName ignored.example"])]);
    assert_eq!(
        names,
        vec![
            // Discovery order is unchanged: every concrete alias, in order.
            named("lab", "lab.internal"),
            named("box", "gitlab.com"),
            named("gpu.corp", "10.0.0.9"),
        ]
    );
    assert!(ssh_pattern_matches("*.corp", "gpu.corp"));
    assert!(ssh_pattern_matches("g?u*", "gpu.corp"));
    assert!(!ssh_pattern_matches("*.corp", "corp"));
    assert!(!ssh_pattern_matches("lab", "lab2"));
}

#[test]
fn a_host_name_before_any_host_line_is_every_hosts() {
    let names = host_names_of(&[
        (
            "config",
            &["Include first", "HostName second.example", "Host jump", "  HostName jump.internal"],
        ),
        ("first", &["HostName %h.tail1234.ts.net"]),
    ]);
    assert_eq!(names, vec![named("jump", "jump.tail1234.ts.net")]);
}

#[test]
fn a_host_s_own_name_read_before_the_global_one_wins() {
    let names = host_names_of(&[
        (
            "config",
            &["Include early", "HostName old-air.tail1234.ts.net", "Host jump", "  HostName x"],
        ),
        ("early", &["Host jump", "  HostName jump.internal"]),
    ]);
    assert_eq!(names, vec![named("jump", "jump.internal")]);
}

#[test]
fn a_host_name_may_be_set_with_an_equals_sign() {
    let config: &[&str] = &[
        "Host a",
        "  HostName = a.example",
        "Host b",
        "  HostName =b.example",
        "Host c",
        "  HostName= c.example",
        "Host d",
        "  HostName=d.example",
        "Host = e",
        "  HostName e.example",
    ];
    let names = host_names_of(&[("config", config)]);
    let want = |a: &str| named(a, &format!("{a}.example"));
    assert_eq!(names, vec![want("a"), want("b"), want("c"), want("d"), want("e")]);
}

#[test]
fn ssh_config_discovery_breaks_include_cycles() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let ssh_root = home.join(".ssh");
    fs::create_dir_all(&ssh_root).unwrap();
    fs::write(ssh_root.join("config"), "Include loop\nHost root\n").unwrap();
    fs::write(ssh_root.join("loop"), "Include config\nHost nested\n").unwrap();

    assert_eq!(
        ssh_config_hosts_from_path(&ssh_root.join("config"), &ssh_root, home),
        vec!["root", "nested"]
    );
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
