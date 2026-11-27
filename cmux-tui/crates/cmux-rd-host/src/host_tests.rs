use super::*;

#[test]
fn window_ids_read_as_decimal_or_hex() {
    assert_eq!(parse_window_id("0x2a00007"), Ok(0x2a0_0007));
    assert_eq!(parse_window_id(" 44040199 "), Ok(44_040_199));
    assert!(parse_window_id("0").is_err());
    assert!(parse_window_id("main").is_err());
}

/// `host::run` and `serve::run` are safe and may run with threads up (the cmux binary
/// calls `run_cli` too), and `set_var` races every concurrent `getenv`, a C library's
/// included. So the safe path must not write `XAUTHORITY`: only `main` may, before any
/// thread exists.
#[cfg(target_os = "linux")]
#[test]
fn the_safe_xauthority_path_leaves_the_environment_alone() {
    let cookie =
        std::env::temp_dir().join(format!("cmux-rd-xauthority-test-{}", std::process::id()));
    std::fs::write(&cookie, b"").expect("cookie file");
    let path = cookie.to_str().expect("utf-8 temp path").to_owned();
    let opts = Opts::parse(&["--xauthority".to_owned(), path.clone()]).expect("parse");
    let checked = check_xauthority(&opts);
    let now = std::env::var_os("XAUTHORITY");
    std::fs::remove_file(&cookie).ok();
    assert_ne!(now.as_deref(), Some(std::ffi::OsStr::new(&path)), "a safe fn wrote XAUTHORITY");
    // `main` did not set it in this process, so the host refuses to go on without it.
    assert!(checked.expect_err("unset").to_string().contains("was not set at start"));
}

#[test]
fn a_real_loopback_connection_passes_the_default_check() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let addr = listener.local_addr().expect("addr");
    let _client = std::net::TcpStream::connect(addr).expect("connect");
    let (accepted, _) = listener.accept().expect("accept");
    assert!(peer_allowed(accepted.peer_addr().expect("peer").ip(), Reach::LoopbackOnly));
}

#[cfg(target_os = "linux")]
#[test]
fn listen_systemd_refuses_the_development_and_browser_options() {
    for extra in [
        &["--token-fd", "3"][..],
        &["--port", "4103"],
        &["--browser", "https://example.com"],
        &["--browser-cdp-port", "9222"],
    ] {
        let mut args: Vec<String> =
            ["--listen-systemd", "--peer-uid", "0"].iter().map(|s| s.to_string()).collect();
        args.extend(extra.iter().map(|s| s.to_string()));
        let err = run_systemd(&Opts::parse(&args).expect("parse")).expect_err("refused");
        assert!(err.to_string().contains("is not used with --listen-systemd"), "{extra:?}: {err}");
    }
    let args: Vec<String> = ["--listen-systemd"].iter().map(|s| s.to_string()).collect();
    let err = run_systemd(&Opts::parse(&args).expect("parse")).expect_err("no peer uid");
    assert!(err.to_string().contains("--peer-uid"), "{err}");
}

#[test]
fn an_http_request_is_closed_before_any_reply() {
    for prefix in [
        "GET / HTTP/1.1\r\n",
        "POST /x HTTP/1.1\r\n",
        "OPTIONS * HTTP/1.1",
        "PUT /",
        "HEAD /",
        "CONNECT a:1",
    ] {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
        let addr = listener.local_addr().expect("addr");
        let mut client = std::net::TcpStream::connect(addr).expect("connect");
        std::io::Write::write_all(&mut client, prefix.as_bytes()).expect("write");
        let (mut server, _) = listener.accept().expect("accept");
        server.set_nonblocking(true).expect("nonblocking");
        let mut reader = FrameReader::default();
        let err = read_control(&mut server, &mut reader).expect_err("refused");
        assert!(err.to_string().contains("not the cmux.rd protocol"), "{prefix}: {err}");
        // Nothing was sent back; the connection is closed.
        client.set_read_timeout(Some(std::time::Duration::from_secs(2))).expect("timeout");
        let mut buf = [0u8; 16];
        assert_eq!(std::io::Read::read(&mut client, &mut buf).unwrap_or(0), 0, "{prefix}");
    }
}
