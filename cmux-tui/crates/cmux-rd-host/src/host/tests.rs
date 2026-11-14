use super::*;

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
