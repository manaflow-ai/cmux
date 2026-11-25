use std::net::SocketAddr;

use super::*;

fn user_layout() -> DaemonLayout {
    DaemonLayout {
        kind: LayoutKind::User,
        user: WORK_USER.to_owned(),
        uid: 1000,
        gid: 1000,
        groups: vec![1000],
        home: PathBuf::from(WORK_HOME),
        bin: binary_path(Path::new(WORK_HOME)),
    }
}

/// The forced command cmux-platform writes for the ssh carrier key
/// (cmux-platform#1032) names the session host's own binary, session and
/// socket. If this test fails, the ssh backup reaches a different daemon
/// than the relay carrier: change both sides together.
#[test]
fn the_ssh_carrier_command_reaches_the_session_hosts_socket() {
    let layout = user_layout();
    assert_eq!(
        ssh_carrier_command(&layout).unwrap().join(" "),
        "/home/cmux/.cmux/bin/cmux-tui remote-link --stdio --session cloud \
             --mux-socket /tmp/cmux-tui-1000/cloud.sock"
    );
    let root = DaemonLayout {
        kind: LayoutKind::Root,
        user: "root".into(),
        uid: 0,
        gid: 0,
        groups: vec![],
        home: PathBuf::from(ROOT_HOME),
        bin: binary_path(Path::new(ROOT_HOME)),
    };
    assert_eq!(ssh_carrier_command(&root), None, "ssh logs in as the work user only");
}

/// The Cloud session host names its terminal cmux: `TERM_PROGRAM=cmux`
/// and no Ghostty `TERM_PROGRAM_VERSION` (the daemon stamps cmux's own
/// version on every terminal child, `cmux_pty::TERMINAL_IDENTITY`).
#[test]
fn the_session_host_names_its_terminal_cmux() {
    let entry = RemoteEntry::Enrolled { bind: "127.0.0.1:1337".parse::<SocketAddr>().unwrap() };
    let spec = daemon_spec(&user_layout(), &entry, Path::new("/run/cmux/bound"));
    assert!(spec.set_env.contains(&("TERM_PROGRAM".into(), "cmux".into())), "{:?}", spec.set_env);
    assert!(spec.set_env.iter().all(|(k, _)| k != "TERM_PROGRAM_VERSION"), "{:?}", spec.set_env);
    assert!(spec.set_env.contains(&("TERM".into(), "xterm-256color".into())));
}

/// The session host derives [`session_socket`] and the default remote
/// state (`$HOME/.local/state/cmux/remote`, where its link socket lives)
/// only while nothing overrides them: no socket or remote state flag, and
/// none of the variables that move them pass from the agent.
#[test]
fn the_session_host_keeps_the_socket_and_link_the_ssh_carrier_names() {
    let layout = user_layout();
    let entry = RemoteEntry::Enrolled { bind: "127.0.0.1:1337".parse::<SocketAddr>().unwrap() };
    let spec = daemon_spec(&layout, &entry, Path::new("/run/cmux/bound"));
    assert_eq!(spec.program, layout.bin);
    assert_eq!(spec.args[..4], ["server", "start", "--session", SESSION]);
    for flag in ["--socket", "--remote-state-dir", "--remote-link-socket", "--remote-admin-socket"]
    {
        assert!(!spec.args.iter().any(|a| a == flag), "{flag} in {:?}", spec.args);
    }
    assert!(spec.set_env.contains(&("HOME".into(), WORK_HOME.into())));
    assert_eq!(spec.uid, 1000);
    let moved = [
        "XDG_RUNTIME_DIR",
        "TMPDIR",
        "XDG_STATE_HOME",
        "CMUX_REMOTE_STATE_DIR",
        "CMUX_MUX_SOCKET",
        "HOME",
    ];
    let env = inherited_env(moved.iter().map(|k| ((*k).to_owned(), "/elsewhere".to_owned())));
    assert!(env.iter().all(|(k, _)| !moved.contains(&k.as_str())), "{env:?}");
    assert_eq!(session_socket(spec.uid), PathBuf::from("/tmp/cmux-tui-1000/cloud.sock"));
}
