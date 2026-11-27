use super::*;

fn adopt_launch(seed: Vec<u8>) -> HostLaunchAdopt {
    HostLaunchAdopt {
        launch: HostLaunch {
            endpoint: "/tmp/cmux-th-1/a.sock".into(),
            record_path: "/state/a.json".into(),
            term: "xterm-256color".into(),
            cols: 100,
            rows: 30,
            cell_pixels: (9, 18),
            scrollback: 4096,
            cwd: None,
            command: Vec::new(),
            extra_env: Vec::new(),
            default_colors: DefaultColors::default(),
            kitty_graphics_limits: KittyGraphicsLimits::default(),
            seed: Vec::new(),
            workspace_key: String::new(),
        },
        child_pid: 4242,
        session_id: 4242,
        incarnation: HostIncarnation::random().unwrap(),
        seed,
        program_status: None,
    }
}

#[test]
fn launch_adopt_payload_round_trips_with_its_seed() {
    let launch = adopt_launch(b"\x1b[2Jseeded screen".to_vec());
    let decoded = HostLaunchAdopt::decode(&launch.encode().unwrap()).unwrap();
    assert_eq!(decoded.launch.endpoint, launch.launch.endpoint);
    assert_eq!(decoded.launch.record_path, launch.launch.record_path);
    assert_eq!((decoded.launch.cols, decoded.launch.rows), (100, 30));
    assert_eq!(decoded.launch.cell_pixels, (9, 18));
    assert_eq!(decoded.launch.scrollback, 4096);
    assert!(decoded.launch.command.is_empty() && decoded.launch.cwd.is_none());
    assert_eq!((decoded.child_pid, decoded.session_id), (4242, 4242));
    assert_eq!(decoded.incarnation, launch.incarnation);
    assert_eq!(decoded.seed, launch.seed);
    let empty = adopt_launch(Vec::new());
    assert!(HostLaunchAdopt::decode(&empty.encode().unwrap()).unwrap().seed.is_empty());
}

#[test]
fn launch_adopt_payload_enforces_its_bounds() {
    let payload = adopt_launch(b"seed".to_vec()).encode().unwrap();
    let mut trailing = payload.clone();
    trailing.push(0);
    assert!(HostLaunchAdopt::decode(&trailing).is_err(), "trailing byte");
    assert!(HostLaunchAdopt::decode(&payload[..payload.len() - 1]).is_err(), "truncated");
    assert!(adopt_launch(vec![0; MAX_BLOB + 1]).encode().is_err(), "oversized seed");
    let full = adopt_launch(vec![b'x'; MAX_BLOB]).encode().unwrap();
    assert!(full.len() <= MAX_LAUNCH_ADOPT_PAYLOAD && full.len() > MAX_LAUNCH_PAYLOAD);
    assert_eq!(HostLaunchAdopt::decode(&full).unwrap().seed.len(), MAX_BLOB);
    let mut unnamed = adopt_launch(Vec::new());
    unnamed.child_pid = 0;
    assert!(unnamed.encode().is_err(), "zero child pid");
    // A non-UUIDv4 incarnation (all zero bytes) is rejected on decode.
    let mut zero = adopt_launch(Vec::new()).encode().unwrap();
    let at = zero.len() - 4 - 16;
    zero[at..at + 16].fill(0);
    assert!(HostLaunchAdopt::decode(&zero).is_err(), "bad incarnation");
}

#[test]
fn launch_adopt_arguments_name_one_inherited_descriptor() {
    let args = |list: &[&str]| list.iter().map(|arg| (*arg).to_string()).collect::<Vec<_>>();
    assert_eq!(adopt_pty_fd(&args(&["--bootstrap-stdio"])).unwrap(), None);
    assert_eq!(
        adopt_pty_fd(&args(&["--bootstrap-stdio", "--adopt-pty-fd", "3"])).unwrap(),
        Some(3)
    );
    for bad in [
        &["--bootstrap-stdio", "--adopt-pty-fd", "2"][..],
        &["--bootstrap-stdio", "--adopt-pty-fd", "x"],
        &["--adopt-pty-fd", "3"],
        &["--bootstrap-stdio", "--adopt-pty-fd"],
        &[],
    ] {
        assert!(adopt_pty_fd(&args(bad)).is_err(), "{bad:?}");
    }
    assert_eq!(max_payload(None), MAX_LAUNCH_ADOPT_PAYLOAD, "a Launch may carry a seed");
    assert_eq!(max_payload(Some(3)), MAX_LAUNCH_ADOPT_PAYLOAD);
}
