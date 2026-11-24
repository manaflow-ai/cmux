use super::*;

#[test]
fn urls_need_tls_except_loopback() {
    let u = Url::parse("https://hub.example/v1/sessions/s/ws?ticket=a.b.c").unwrap();
    assert_eq!(
        (u.tls, u.host.as_str(), u.port, u.target.as_str()),
        (true, "hub.example", 443, "/v1/sessions/s/ws?ticket=a.b.c")
    );
    let u = Url::parse("wss://hub.example:8443").unwrap();
    assert_eq!((u.port, u.target.as_str()), (8443, "/"));
    assert!(Url::parse("http://hub.example/v1").is_err());
    assert!(Url::parse("http://127.0.0.1:8787/v1").is_ok());
    assert!(Url::parse("https://user@hub.example/").is_err());
    assert_eq!(Url::join("https://hub.example/", "/v1/me").unwrap().target, "/v1/me");
}

#[test]
fn accept_key_matches_rfc_6455() {
    assert_eq!(accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
}

#[test]
fn frames_round_trip_masked_and_unmasked() {
    for len in [0usize, 5, 125, 126, 70_000] {
        let payload = vec![7u8; len];
        let frame = encode_frame(0x1, &payload).unwrap();
        let (fin, op, back, used) = decode_frame(&frame).unwrap().unwrap();
        assert!(fin);
        assert_eq!((op, back, used), (0x1, payload, frame.len()));
        assert!(decode_frame(&frame[..frame.len() - 1]).unwrap().is_none() || len == 0);
    }
    let server = [0x81, 0x02, b'h', b'i'];
    assert_eq!(decode_frame(&server).unwrap().unwrap().2, b"hi");
}

#[test]
fn responses_read_length_and_chunked_bodies() {
    let r = parse_response(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}extra").unwrap();
    assert_eq!((r.status, r.body.as_slice()), (200, &b"{}"[..]));
    let r = parse_response(b"HTTP/1.1 403 Forbidden\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n").unwrap();
    assert_eq!((r.status, r.body.as_slice()), (403, &b"abcde"[..]));
}

#[test]
fn a_plaintext_hub_is_reached_only_on_a_loopback_address() {
    let local = Url::parse("http://localhost:8787/v1").unwrap();
    let remote: SocketAddr = "203.0.113.7:8787".parse().unwrap();
    let v4: SocketAddr = "127.0.0.1:8787".parse().unwrap();
    let v6: SocketAddr = "[::1]:8787".parse().unwrap();
    // A hosts file or resolver that sends `localhost` elsewhere gets no cleartext.
    assert!(addresses(&local, vec![remote]).is_err());
    assert_eq!(addresses(&local, vec![remote, v6, v4]).unwrap(), vec![v6, v4]);
    // TLS checks the certificate; every address is tried, in the resolver's order.
    let tls = Url::parse("https://hub.example").unwrap();
    assert_eq!(addresses(&tls, vec![v6, remote]).unwrap(), vec![v6, remote]);
    assert!(addresses(&tls, vec![]).is_err());
}

/// A signal to the process (a helper's SIGCHLD when it exits) interrupts a timed socket
/// read even under SA_RESTART (signal(7)). That is nothing arriving, never the socket
/// closing: a share whose own helper crashed read it as "signaling closed before the
/// viewer connected", and the hub was never told the share failed.
#[cfg(unix)]
#[test]
fn a_signal_during_a_read_is_no_message_and_the_socket_stays_open() {
    use std::io::BufRead;
    use std::os::unix::thread::JoinHandleExt;
    extern "C" fn ignore(_: libc::c_int) {}
    // SAFETY: a zeroed sigaction is valid; the handler does nothing, which is
    // async-signal-safe, and SIGUSR2 is used by nothing else in this crate's tests.
    unsafe {
        let mut action: libc::sigaction = std::mem::zeroed();
        action.sa_sigaction = ignore as extern "C" fn(libc::c_int) as libc::sighandler_t;
        action.sa_flags = libc::SA_RESTART;
        libc::sigemptyset(&mut action.sa_mask);
        assert_eq!(libc::sigaction(libc::SIGUSR2, &action, std::ptr::null_mut()), 0);
    }
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let (send_now, sent) = std::sync::mpsc::channel::<()>();
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut reader = io::BufReader::new(stream.try_clone().unwrap());
        let mut key = String::new();
        loop {
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            if line.trim_end().is_empty() {
                break;
            }
            if let Some(v) = line.trim_end().strip_prefix("Sec-WebSocket-Key: ") {
                key = v.to_owned();
            }
        }
        let mut out = &stream;
        write!(
            out,
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {}\r\n\r\n",
            accept_key(&key)
        )
        .unwrap();
        sent.recv().unwrap();
        out.write_all(&[0x81, 2, b'h', b'i']).unwrap();
        // Held open until the client is done.
        let _ = io::copy(&mut reader, &mut io::sink());
    });
    let url = Url::parse(&format!("ws://127.0.0.1:{port}/")).unwrap();
    let mut ws = WebSocket::connect(&url, &[]).unwrap();
    let reader = std::thread::spawn(move || {
        let first = ws.recv(Duration::from_secs(30)).map_err(|e| e.to_string());
        (ws, first)
    });
    // Signal the reading thread until its read returns: it spends nearly all its time
    // blocked in recv, so one of these lands there.
    let thread = reader.as_pthread_t();
    while !reader.is_finished() {
        // SAFETY: the reading thread has not been joined, so its pthread_t is live.
        unsafe { libc::pthread_kill(thread, libc::SIGUSR2) };
        std::thread::yield_now();
    }
    let (mut ws, first) = reader.join().unwrap();
    assert!(matches!(first, Ok(None)), "an interrupted read: {first:?}");
    send_now.send(()).unwrap();
    let next = ws.recv(Duration::from_secs(30)).unwrap();
    assert!(matches!(next, Some(Message::Text(ref t)) if t == "hi"), "{next:?}");
    ws.close();
    drop(ws);
    server.join().unwrap();
}
