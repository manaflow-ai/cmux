use super::*;
use std::io::Write;

#[test]
fn internal_args_never_accept_an_inline_authority() {
    let error = parse(&[
        "__provider-authority".into(),
        "install".into(),
        "--socket".into(),
        "/run/cmux.sock".into(),
        "--generation".into(),
        "1".into(),
        "--authority".into(),
        "do-not-put-secrets-in-argv-00000000".into(),
    ])
    .unwrap_err()
    .to_string();
    assert_eq!(error, "invalid internal provider authority arguments");
    assert!(!error.contains("do-not-put-secrets"));
}

#[test]
fn unavailable_live_management_protocol_is_retryable() {
    if unsafe { libc::geteuid() } != 0 {
        return;
    }
    let suffix = format!("{}-{}", std::process::id(), std::thread::current().name().unwrap());
    let authority_path = std::env::temp_dir().join(format!("cmux-authority-{suffix}"));
    let socket_path = std::env::temp_dir().join(format!("cmux-old-mux-{suffix}.sock"));
    let mut authority =
        OpenOptions::new().create_new(true).write(true).mode(0o600).open(&authority_path).unwrap();
    authority.write_all(b"old-mux-upgrade-authority-000000000001").unwrap();
    drop(authority);
    let exit = try_run(&[
        "__provider-authority".into(),
        "install".into(),
        "--socket".into(),
        socket_path.display().to_string(),
        "--generation".into(),
        "1".into(),
        "--authority-file".into(),
        authority_path.display().to_string(),
    ])
    .unwrap();
    std::fs::remove_file(authority_path).unwrap();
    assert_eq!(exit, 1);
}

#[test]
fn unresponsive_listener_is_retryable() {
    use std::os::unix::net::UnixListener;

    if unsafe { libc::geteuid() } != 0 {
        return;
    }
    let suffix = format!("old-{}", std::process::id());
    let authority_path = std::env::temp_dir().join(format!("cmux-authority-{suffix}"));
    let socket_path = std::env::temp_dir().join(format!("cmux-old-mux-{suffix}.sock"));
    let mut authority =
        OpenOptions::new().create_new(true).write(true).mode(0o600).open(&authority_path).unwrap();
    authority.write_all(b"unresponsive-mux-authority-000000000001").unwrap();
    drop(authority);
    let listener = UnixListener::bind(&socket_path).unwrap();
    let exit = try_run(&[
        "__provider-authority".into(),
        "install".into(),
        "--socket".into(),
        socket_path.display().to_string(),
        "--generation".into(),
        "1".into(),
        "--authority-file".into(),
        authority_path.display().to_string(),
    ])
    .unwrap();
    drop(listener);
    std::fs::remove_file(authority_path).unwrap();
    std::fs::remove_file(socket_path).unwrap();
    assert_eq!(exit, 1);
}

#[test]
fn explicit_unsupported_protocol_returns_upgrade_required() {
    use std::io::{BufRead, BufReader};
    use std::os::unix::net::UnixListener;

    if unsafe { libc::geteuid() } != 0 {
        return;
    }
    let suffix = format!("future-{}", std::process::id());
    let authority_path = std::env::temp_dir().join(format!("cmux-authority-{suffix}"));
    let socket_path = std::env::temp_dir().join(format!("cmux-future-mux-{suffix}.sock"));
    let mut authority =
        OpenOptions::new().create_new(true).write(true).mode(0o600).open(&authority_path).unwrap();
    authority.write_all(b"future-mux-authority-000000000000000001").unwrap();
    drop(authority);
    let listener = UnixListener::bind(&socket_path).unwrap();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut request = String::new();
        BufReader::new(stream.try_clone().unwrap()).read_line(&mut request).unwrap();
        assert!(request.contains("\"operation\":\"status\""));
        stream
                .write_all(
                    b"{\"protocol\":2,\"ok\":false,\"error\":{\"code\":\"unsupported_version\",\"message\":\"future protocol\"}}\n",
                )
                .unwrap();
    });
    let exit = try_run(&[
        "__provider-authority".into(),
        "install".into(),
        "--socket".into(),
        socket_path.display().to_string(),
        "--generation".into(),
        "1".into(),
        "--authority-file".into(),
        authority_path.display().to_string(),
    ])
    .unwrap();
    server.join().unwrap();
    std::fs::remove_file(authority_path).unwrap();
    std::fs::remove_file(socket_path).unwrap();
    assert_eq!(exit, UPGRADE_REQUIRED_EXIT);
}
