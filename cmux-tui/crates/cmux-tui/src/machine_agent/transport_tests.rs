use std::ffi::OsStr;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::thread;

use super::*;

#[test]
fn ssh_exec_command_is_exact_and_user_input_only_selects_destination() {
    let connector = SshCloudConnector::new(SshOptions {
        host: "cmux.cloud".into(),
        user: Some("dev".into()),
        port: Some(2222),
        identity_file: Some(Path::new("/keys/cmux").into()),
    })
    .unwrap();
    let args = connector.command_args();
    assert_eq!(
        &args[args.len() - 5..],
        [
            OsStr::new("--"),
            OsStr::new("dev@cmux.cloud"),
            OsStr::new("cmux"),
            OsStr::new("machine"),
            OsStr::new("register"),
        ]
    );
    assert!(args.contains(&OsString::from("dev@cmux.cloud")));
    assert!(args.contains(&OsString::from("IdentitiesOnly=yes")));
    assert!(args.contains(&OsString::from("BatchMode=yes")));
    assert!(args.contains(&OsString::from("StrictHostKeyChecking=yes")));
    assert!(args.contains(&OsString::from("RemoteCommand=none")));
    assert!(args.contains(&OsString::from("ClearAllForwardings=yes")));
    assert!(args.contains(&OsString::from("ForwardAgent=no")));
    assert!(!args.iter().any(|argument| argument.to_string_lossy().contains("sh -c")));
    assert!(
        SshCloudConnector::new(SshOptions {
            host: "-oProxyCommand=bad".into(),
            user: None,
            port: None,
            identity_file: None,
        })
        .is_err()
    );
}

/// The registration link never becomes a ControlMaster, so turning its
/// forwarding off cannot reach an interactive session.
#[test]
fn machine_agent_uses_hardened_ssh_argv() {
    let connector = SshCloudConnector::new(SshOptions {
        host: "cmux.cloud".into(),
        user: None,
        port: None,
        identity_file: None,
    })
    .unwrap();
    let args = connector.command_args();
    for option in
        ["ControlMaster=no", "ForwardAgent=no", "ForwardX11=no", "ClearAllForwardings=yes"]
    {
        let index = args
            .iter()
            .position(|argument| argument == option)
            .unwrap_or_else(|| panic!("missing -o {option}"));
        assert_eq!(args[index - 1], "-o");
    }
    let separator = args.iter().position(|argument| argument == "--").unwrap();
    assert_eq!(args[separator + 1], "cmux.cloud");
}

#[test]
fn local_connector_accepts_only_the_current_cmux_protocol() {
    fn verify(version: u32) -> anyhow::Result<()> {
        let path = std::env::temp_dir()
            .join(format!("cmux-machine-agent-probe-{}-{version}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        let server = thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap()).read_line(&mut request).unwrap();
            assert_eq!(request, "{\"id\":1,\"cmd\":\"identify\"}\n");
            writeln!(stream, "{{\"id\":1,\"ok\":true,\"data\":{{\"protocol\":{version}}}}}")
                .unwrap();
        });
        let result = SocketSessionConnector::new(path.clone(), false).verify_protocol();
        server.join().unwrap();
        std::fs::remove_file(path).unwrap();
        result
    }

    verify(PROTOCOL_VERSION).unwrap();
    assert!(verify(PROTOCOL_VERSION - 1).is_err());
}
