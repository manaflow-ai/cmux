use super::*;

fn spec(name: &str) -> CreateMachineSpec {
    CreateMachineSpec { name: name.into(), ..CreateMachineSpec::default() }
}

fn exec(program: &str, args: &[&str]) -> ExecRequest {
    ExecRequest {
        program: program.into(),
        args: args.iter().map(|arg| (*arg).to_owned()).collect(),
        ..ExecRequest::default()
    }
}

/// A caller written against the trait object, as a real one would be.
fn provider(capabilities: MachineOperationCapabilities) -> Arc<dyn MachineProvider> {
    Arc::new(InMemoryMachineProvider::new(capabilities))
}

#[tokio::test]
async fn full_lifecycle_through_the_trait_object() {
    let provider = provider(MachineOperationCapabilities::ALL);
    let machine = provider.create(spec("primary")).await.unwrap();

    provider.write_file(&machine, "/work/note.txt", b"hello").await.unwrap();
    assert_eq!(provider.read_file(&machine, "/work/note.txt").await.unwrap(), b"hello");

    let out = provider.exec(&machine, exec("echo", &["hi", "there"])).await.unwrap();
    assert_eq!(out.exit_code, 0);
    assert_eq!(out.stdout, b"echo hi there");

    let ports = provider.exposed_ports(&machine).await.unwrap();
    assert_eq!(ports, vec![ExposedPort { port: 8080, protocol: PortProtocol::Tcp, url: None }]);

    provider.pause(&machine).await.unwrap();
    assert_eq!(provider.read_file(&machine, "/work/note.txt").await.unwrap(), b"hello");
    assert_eq!(
        provider.exec(&machine, exec("true", &[])).await,
        Err(MachineProviderError::InvalidState {
            operation: MachineOperation::Exec,
            state: MachineRunState::Paused,
        })
    );
    provider.resume(&machine).await.unwrap();

    let snapshot = provider.snapshot(&machine).await.unwrap();
    // A write after the snapshot must not reach the fork.
    provider.write_file(&machine, "/work/note.txt", b"changed").await.unwrap();
    let fork = provider.fork(&snapshot, spec("fork")).await.unwrap();
    assert_ne!(fork, machine);
    assert_eq!(provider.read_file(&fork, "/work/note.txt").await.unwrap(), b"hello");
    assert_eq!(provider.read_file(&machine, "/work/note.txt").await.unwrap(), b"changed");

    provider.delete(&machine).await.unwrap();
    assert_eq!(
        provider.read_file(&machine, "/work/note.txt").await,
        Err(MachineProviderError::MachineNotFound(machine.clone()))
    );
    // The fork outlives its source machine, and the snapshot still forks.
    assert_eq!(provider.read_file(&fork, "/work/note.txt").await.unwrap(), b"hello");
    provider.fork(&snapshot, spec("second-fork")).await.unwrap();
}

#[tokio::test]
async fn plain_vm_reports_and_refuses_snapshot_and_fork() {
    let provider = provider(MachineOperationCapabilities::PLAIN_VM);
    let caps = provider.capabilities();
    assert!(!caps.supports(MachineOperation::Snapshot));
    assert!(!caps.supports(MachineOperation::Fork));
    assert!(!caps.supports(MachineOperation::FsWhilePaused));
    assert!(caps.supports(MachineOperation::Exec));

    let machine = provider.create(spec("plain")).await.unwrap();
    assert_eq!(
        provider.snapshot(&machine).await,
        Err(MachineProviderError::Unsupported(MachineOperation::Snapshot))
    );
    assert_eq!(
        provider.fork(&SnapshotHandle("any".into()), spec("fork")).await,
        Err(MachineProviderError::Unsupported(MachineOperation::Fork))
    );

    provider.write_file(&machine, "/a", b"x").await.unwrap();
    provider.pause(&machine).await.unwrap();
    assert_eq!(
        provider.read_file(&machine, "/a").await,
        Err(MachineProviderError::Unsupported(MachineOperation::FsWhilePaused))
    );
    provider.resume(&machine).await.unwrap();
    assert_eq!(provider.read_file(&machine, "/a").await.unwrap(), b"x");
}

#[tokio::test]
async fn every_operation_says_unsupported_when_its_flag_is_off() {
    let all = MachineOperationCapabilities::ALL;
    // Each flag off on its own makes exactly its operations fail Unsupported,
    // checked before any lookup, so a missing machine id does not hide it.
    let cases: [(MachineOperationCapabilities, &[MachineOperation]); 8] = [
        (MachineOperationCapabilities { create: false, ..all }, &[MachineOperation::Create]),
        (MachineOperationCapabilities { snapshot: false, ..all }, &[MachineOperation::Snapshot]),
        (MachineOperationCapabilities { fork: false, ..all }, &[MachineOperation::Fork]),
        (
            MachineOperationCapabilities { pause_resume: false, ..all },
            &[MachineOperation::Pause, MachineOperation::Resume],
        ),
        (MachineOperationCapabilities { delete: false, ..all }, &[MachineOperation::Delete]),
        (
            MachineOperationCapabilities { fs: false, ..all },
            &[MachineOperation::FsRead, MachineOperation::FsWrite],
        ),
        (MachineOperationCapabilities { exec: false, ..all }, &[MachineOperation::Exec]),
        (
            MachineOperationCapabilities { exposed_ports: false, ..all },
            &[MachineOperation::ExposedPorts],
        ),
    ];
    let missing = MachineHandle("missing".into());
    for (caps, expected) in cases {
        let provider = provider(caps);
        for operation in expected {
            assert!(!caps.supports(*operation), "{operation} should be off");
            let got = match operation {
                MachineOperation::Create => provider.create(spec("m")).await.map(|_| ()),
                MachineOperation::Snapshot => provider.snapshot(&missing).await.map(|_| ()),
                MachineOperation::Fork => {
                    provider.fork(&SnapshotHandle("s".into()), spec("m")).await.map(|_| ())
                }
                MachineOperation::Pause => provider.pause(&missing).await,
                MachineOperation::Resume => provider.resume(&missing).await,
                MachineOperation::Delete => provider.delete(&missing).await,
                MachineOperation::FsRead => provider.read_file(&missing, "/a").await.map(|_| ()),
                MachineOperation::FsWrite => provider.write_file(&missing, "/a", b"").await,
                MachineOperation::Exec => provider.exec(&missing, exec("x", &[])).await.map(|_| ()),
                MachineOperation::ExposedPorts => {
                    provider.exposed_ports(&missing).await.map(|_| ())
                }
                MachineOperation::FsWhilePaused => unreachable!(),
            };
            assert_eq!(got, Err(MachineProviderError::Unsupported(*operation)));
        }
    }
}

#[test]
fn default_capabilities_support_nothing() {
    let none = MachineOperationCapabilities::default();
    for operation in [
        MachineOperation::Create,
        MachineOperation::Snapshot,
        MachineOperation::Fork,
        MachineOperation::Pause,
        MachineOperation::Resume,
        MachineOperation::Delete,
        MachineOperation::FsRead,
        MachineOperation::FsWrite,
        MachineOperation::FsWhilePaused,
        MachineOperation::Exec,
        MachineOperation::ExposedPorts,
    ] {
        assert!(!none.supports(operation), "{operation}");
        assert!(MachineOperationCapabilities::ALL.supports(operation), "{operation}");
    }
    assert_eq!(none.fork_latency, ForkLatencyClass::Unknown);
    // fs_while_paused alone is meaningless without fs.
    let paused_only = MachineOperationCapabilities { fs_while_paused: true, ..none };
    assert!(!paused_only.supports(MachineOperation::FsWhilePaused));
}

#[tokio::test]
async fn errors_for_bad_input_and_unknown_ids() {
    let provider = provider(MachineOperationCapabilities::ALL);
    assert!(matches!(
        provider.create(spec("  ")).await,
        Err(MachineProviderError::InvalidInput(_))
    ));
    let machine = provider.create(spec("m")).await.unwrap();
    assert!(matches!(
        provider.write_file(&machine, "relative", b"").await,
        Err(MachineProviderError::InvalidInput(_))
    ));
    assert!(matches!(
        provider.read_file(&machine, "/nope").await,
        Err(MachineProviderError::InvalidInput(_))
    ));
    let missing = SnapshotHandle("snapshot-404".into());
    assert_eq!(
        provider.fork(&missing, spec("f")).await,
        Err(MachineProviderError::SnapshotNotFound(missing.clone()))
    );
    assert_eq!(
        provider.resume(&machine).await,
        Err(MachineProviderError::InvalidState {
            operation: MachineOperation::Resume,
            state: MachineRunState::Running,
        })
    );
    provider.delete(&machine).await.unwrap();
    assert_eq!(
        provider.delete(&machine).await,
        Err(MachineProviderError::MachineNotFound(machine.clone()))
    );
}

#[test]
fn unsupported_error_names_the_operation() {
    assert_eq!(
        MachineProviderError::Unsupported(MachineOperation::Fork).to_string(),
        "this machine backend does not support fork"
    );
}
