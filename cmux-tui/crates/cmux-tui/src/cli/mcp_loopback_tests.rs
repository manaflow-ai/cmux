use super::*;

#[test]
fn the_forward_is_only_a_platform_callback() {
    assert!(valid_forward("https://cmux.com/v1/mcp-servers/oauth/callback"));
    assert!(valid_forward("https://api.staging.cmux.dev/v1/mcp-servers/oauth/callback"));
    assert!(valid_forward("http://127.0.0.1:8787/v1/mcp-servers/oauth/callback"));
    assert!(!valid_forward("http://evil.example/v1/mcp-servers/oauth/callback"));
    assert!(!valid_forward("https://cmux.com/v1/mcp-servers/oauth/callback?x=1"));
    assert!(!valid_forward("https://a@cmux.com/v1/mcp-servers/oauth/callback"));
    assert!(!valid_forward("https://cmux.com/elsewhere"));
    assert!(!valid_forward("https:///v1/mcp-servers/oauth/callback"));
}

#[test]
fn a_callback_forwards_its_query_unchanged_and_probes_need_the_loopback_host() {
    let host = Some("127.0.0.1:47215");
    assert_eq!(
        route("/callback?code=a%2Fb&state=s.t&iss=https%3A%2F%2Fvercel.com", None, 47215),
        Reply::Forward("code=a%2Fb&state=s.t&iss=https%3A%2F%2Fvercel.com".into())
    );
    assert_eq!(route("/callback", host, 47215), Reply::NotFound);
    assert_eq!(route("/cmux-loopback/ping", host, 47215), Reply::Ping);
    assert_eq!(route("/cmux-loopback/stop", host, 47215), Reply::Stop);
    assert_eq!(route("/cmux-loopback/stop", Some("evil.example:47215"), 47215), Reply::NotFound);
    assert_eq!(route("/", host, 47215), Reply::NotFound);
}

#[test]
fn a_request_reads_its_target_and_host() {
    let raw = b"GET /callback?code=1 HTTP/1.1\r\nHost: 127.0.0.1:47215\r\nUser-Agent: x\r\n\r\n";
    assert_eq!(
        read_request(&mut &raw[..]),
        Some(("/callback?code=1".into(), Some("127.0.0.1:47215".into())))
    );
    assert_eq!(read_request(&mut &b"POST /callback HTTP/1.1\r\n\r\n"[..]), None);
}

#[test]
fn the_listener_forwards_one_callback_then_answers_a_stop() {
    let port = {
        let probe = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        probe.local_addr().unwrap().port()
    };
    let forward = "https://cmux.com/v1/mcp-servers/oauth/callback".to_owned();
    let args = vec!["--port".into(), port.to_string(), "--forward".into(), forward.clone()];
    let server = std::thread::spawn(move || serve_main(&args));
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let started = Instant::now();
    while TcpStream::connect(addr).is_err() {
        assert!(started.elapsed() < Duration::from_secs(5), "listener never bound");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(probe(port, "/cmux-loopback/ping"), Some(format!("{BANNER} {forward}")));
    let mut stream = TcpStream::connect(addr).unwrap();
    stream.write_all(b"GET /callback?code=c&state=s HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n").unwrap();
    let mut answer = String::new();
    stream.read_to_string(&mut answer).unwrap();
    assert!(answer.starts_with("HTTP/1.1 302"), "{answer}");
    assert!(answer.contains(&format!("Location: {forward}?code=c&state=s\r\n")), "{answer}");
    assert_eq!(probe(port, "/cmux-loopback/stop"), Some(String::new()));
    assert_eq!(server.join().unwrap(), 0);
}
