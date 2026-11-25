use super::*;
use std::{future::Future, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};

/// Every test wait ends after three seconds, even when a stub or regression stalls.
async fn bounded<T>(f: impl Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(3), f).await.expect("test timed out")
}

fn listener() -> (std::net::TcpListener, SocketAddr) {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = l.local_addr().unwrap();
    (l, addr)
}

/// Stops at CRLF CRLF or the three-second test deadline; never consumes tunnel bytes.
async fn headers(stream: &mut TcpStream) -> String {
    bounded(async {
        let mut bytes = Vec::new();
        while !bytes.ends_with(b"\r\n\r\n") {
            bytes.push(stream.read_u8().await.unwrap());
            assert!(bytes.len() <= 16 * 1024);
        }
        String::from_utf8(bytes).unwrap()
    })
    .await
}

#[test]
fn allowed_address_and_port_table() {
    let none = NetPolicy::default();
    let external = NetPolicy { api: Some((31415, false)) };
    let local = NetPolicy { api: Some((31415, true)) };
    for (text, expected) in [
        ("8.8.8.8:80", true),
        ("8.8.8.8:443", true),
        ("[2606:4700:4700::1111]:443", true),
        ("[::ffff:8.8.8.8]:80", true),
        ("[::127.0.0.1]:443", false),
        ("[::8.8.8.8]:80", false),
        ("[2002:7f00:1::]:443", false),
        ("[2002:808:808::]:80", false),
        ("[2001:0:1234:5678:9abc:def0:80ff:fffe]:443", false),
        ("[2001:0:1234:5678:9abc:def0:f7f7:f7f7]:80", false),
        ("[64:ff9b::7f00:1]:443", false),
        ("[64:ff9b::a9fe:a9fe]:80", false),
        ("[64:ff9b::e000:1]:443", false),
        ("[64:ff9b::ffff:ffff]:80", false),
        ("[64:ff9b::]:80", false),
        ("[64:ff9b::808:808]:443", true),
        ("[::ffff:0:7f00:1]:443", false),
        ("[::ffff:0:a9fe:a9fe]:80", false),
        ("[::ffff:0:e000:1]:443", false),
        ("[::ffff:0:ffff:ffff]:80", false),
        ("[::ffff:0:0:0]:443", false),
        ("[::ffff:0:808:808]:80", true),
        // Local NAT64 may use /48, /56, /64 or /96: RFC 6052 skips byte 8.
        ("[64:ff9b:1:7f00:0:108:808:808]:443", false),
        ("[64:ff9b:1:87f:0:1:808:808]:443", false),
        ("[64:ff9b:1:808:7f:0:108:808]:443", false),
        ("[64:ff9b:1:808:8:808:7f00:1]:443", false),
        ("[64:ff9b:1:a9fe:a9:fe08:808:808]:80", false),
        ("[64:ff9b:1:808:8:808:808:808]:443", true),
        ("10.0.0.1:443", true),
        ("8.8.8.8:22", false),
        ("8.8.8.8:0", false),
        ("127.0.0.1:443", false),
        ("127.12.34.56:80", false),
        ("[::1]:443", false),
        ("[::ffff:127.0.0.1]:443", false),
        ("0.0.0.0:80", false),
        ("0.1.2.3:80", false),
        ("[::ffff:0.1.2.3]:443", false),
        ("[::]:80", false),
        ("[::ffff:0.0.0.0]:80", false),
        ("169.254.169.254:80", false),
        ("[::ffff:169.254.169.254]:80", false),
        ("[fe80::1]:443", false),
        ("[febf::1]:443", false),
        ("224.0.0.1:80", false),
        ("239.255.255.255:443", false),
        ("[::ffff:224.0.0.1]:80", false),
        ("[ff02::1]:443", false),
        ("255.255.255.255:80", false),
        ("[::ffff:255.255.255.255]:80", false),
    ] {
        assert_eq!(allowed(&none, text.parse().unwrap()), expected, "{text}");
    }
    for text in ["8.8.8.8:31415", "[2606:4700:4700::1111]:31415"] {
        let addr = text.parse().unwrap();
        assert!(allowed(&external, addr));
        assert!(!allowed(&local, addr), "loopback API port must not open external egress");
        assert!(!allowed(&none, addr));
    }
    for text in ["127.0.0.1:31415", "[::1]:31415", "[::ffff:127.0.0.1]:31415"] {
        let addr = text.parse().unwrap();
        assert!(allowed(&local, addr));
        assert!(!allowed(&external, addr));
        assert!(!allowed(&none, addr));
    }
    assert!(!allowed(&local, "127.0.0.1:31416".parse().unwrap()));
    for text in
        ["[64:ff9b::7f00:1]:31415", "[::ffff:0:7f00:1]:31415", "[64:ff9b:1:808:8:808:7f00:1]:31415"]
    {
        assert!(!allowed(&local, text.parse().unwrap()), "no translated loopback exception");
    }
    assert!(!allowed(&NetPolicy { api: Some((0, true)) }, "127.0.0.1:0".parse().unwrap()));
}

#[tokio::test]
async fn forbidden_connect_never_reaches_listener_even_for_loopback_api() {
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = target.local_addr().unwrap();
    for api in [None, Some((addr.port(), false)), Some((addr.port(), true))] {
        let (l, proxy) = listener();
        let stop = CancellationToken::new();
        let task = tokio::spawn(serve_proxy(l, NetPolicy { api }, stop.clone()));
        let mut client = TcpStream::connect(proxy).await.unwrap();
        client
            .write_all(format!("CONNECT {addr} HTTP/1.1\r\nHost: {addr}\r\n\r\n").as_bytes())
            .await
            .unwrap();
        assert!(headers(&mut client).await.starts_with("HTTP/1.1 403 Forbidden\r\n"));
        let mut reason = String::new();
        bounded(client.read_to_string(&mut reason)).await.unwrap();
        assert_eq!(reason.lines().count(), 1, "one-line reason required");
        assert!(tokio::time::timeout(Duration::from_millis(50), target.accept()).await.is_err());
        stop.cancel();
        bounded(task).await.unwrap().unwrap();
    }
}

async fn stand_in(
    target: SocketAddr,
) -> (TcpStream, CancellationToken, tokio::task::JoinHandle<io::Result<()>>) {
    let (l, proxy) = listener();
    let stop = CancellationToken::new();
    let task = tokio::spawn(serve_proxy_with_filter(l, move |a| a == target, stop.clone()));
    (TcpStream::connect(proxy).await.unwrap(), stop, task)
}

#[tokio::test]
async fn connect_preserves_early_bytes_and_stop_closes_active_tunnel() {
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = target.local_addr().unwrap();
    let (mut client, stop, task) = stand_in(addr).await;
    client.write_all(format!("CONNECT {addr} HTTP/1.1\r\n\r\nearly").as_bytes()).await.unwrap();
    let (mut server, _) = bounded(target.accept()).await.unwrap();
    assert!(headers(&mut client).await.starts_with("HTTP/1.1 200 "));
    let mut bytes = [0; 5];
    bounded(server.read_exact(&mut bytes)).await.unwrap();
    assert_eq!(&bytes, b"early");
    server.write_all(b"reply").await.unwrap();
    bounded(client.read_exact(&mut bytes)).await.unwrap();
    assert_eq!(&bytes, b"reply");
    stop.cancel();
    bounded(task).await.unwrap().unwrap();
    assert_eq!(bounded(client.read(&mut bytes)).await.unwrap(), 0);
    assert_eq!(bounded(server.read(&mut bytes)).await.unwrap(), 0);
}

#[tokio::test]
async fn absolute_get_rewrites_origin_form_and_does_not_follow_redirect() {
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = target.local_addr().unwrap();
    let (mut client, stop, task) = stand_in(addr).await;
    client
        .write_all(
            format!("GET http://{addr}/path?q=one HTTP/1.1\r\nHost: {addr}\r\n\r\n").as_bytes(),
        )
        .await
        .unwrap();
    let (mut server, _) = bounded(target.accept()).await.unwrap();
    let request = headers(&mut server).await;
    assert!(request.starts_with("GET /path?q=one HTTP/1.1\r\n"), "{request}");
    let redirect =
        b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:22/\r\nContent-Length: 0\r\n\r\n";
    server.write_all(redirect).await.unwrap();
    assert_eq!(headers(&mut client).await.as_bytes(), redirect);
    stop.cancel();
    bounded(task).await.unwrap().unwrap();
}

#[tokio::test]
async fn allowed_but_unreachable_returns_502() {
    // A bound socket that never listens refuses connections and keeps the port from any
    // other test. A dropped listener would keep listening while a process another test
    // spawns holds a copy of it.
    let unreachable = tokio::net::TcpSocket::new_v4().unwrap();
    unreachable.bind("127.0.0.1:0".parse().unwrap()).unwrap();
    let addr = unreachable.local_addr().unwrap();
    let (mut client, stop, task) = stand_in(addr).await;
    client.write_all(format!("CONNECT {addr} HTTP/1.1\r\n\r\n").as_bytes()).await.unwrap();
    assert!(headers(&mut client).await.starts_with("HTTP/1.1 502 "));
    stop.cancel();
    bounded(task).await.unwrap().unwrap();
}

#[tokio::test]
async fn oversized_headers_are_rejected_without_connecting() {
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = target.local_addr().unwrap();
    let (mut client, stop, task) = stand_in(addr).await;
    let request = format!("CONNECT {addr} HTTP/1.1\r\nX: {}", "x".repeat(16 * 1024));
    client.write_all(request.as_bytes()).await.unwrap();
    assert!(headers(&mut client).await.starts_with("HTTP/1.1 431 "));
    assert!(tokio::time::timeout(Duration::from_millis(50), target.accept()).await.is_err());
    stop.cancel();
    bounded(task).await.unwrap().unwrap();
}

#[tokio::test]
async fn forward_requires_loopback_and_stop_ends_both_idle_loops() {
    let (l, _) = listener();
    assert!(
        serve_forward(l, "8.8.8.8:80".parse().unwrap(), CancellationToken::new()).await.is_err()
    );
    let (l, _) = listener();
    let (f, _) = listener();
    let stop = CancellationToken::new();
    let proxy = tokio::spawn(serve_proxy(l, NetPolicy::default(), stop.clone()));
    let forward = tokio::spawn(serve_forward(f, "127.0.0.1:12345".parse().unwrap(), stop.clone()));
    tokio::task::yield_now().await;
    stop.cancel();
    bounded(proxy).await.unwrap().unwrap();
    bounded(forward).await.unwrap().unwrap();
}

#[tokio::test]
async fn forward_is_raw_and_stop_closes_its_tunnels() {
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (l, proxy) = listener();
    let stop = CancellationToken::new();
    let task = tokio::spawn(serve_forward(l, target.local_addr().unwrap(), stop.clone()));
    let mut client = TcpStream::connect(proxy).await.unwrap();
    client.write_all(b"raw").await.unwrap();
    let (mut server, _) = bounded(target.accept()).await.unwrap();
    let mut bytes = [0; 3];
    bounded(server.read_exact(&mut bytes)).await.unwrap();
    assert_eq!(&bytes, b"raw");
    server.write_all(b"yes").await.unwrap();
    bounded(client.read_exact(&mut bytes)).await.unwrap();
    assert_eq!(&bytes, b"yes");
    stop.cancel();
    bounded(task).await.unwrap().unwrap();
    assert_eq!(bounded(server.read(&mut bytes)).await.unwrap(), 0);
    assert_eq!(bounded(client.read(&mut bytes)).await.unwrap(), 0);
}

#[tokio::test]
async fn at_most_256_live_tunnels_and_closing_one_releases_capacity() {
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = target.local_addr().unwrap();
    let (l, proxy) = listener();
    let stop = CancellationToken::new();
    let task = tokio::spawn(serve_proxy_with_filter(l, move |a| a == addr, stop.clone()));
    let request = format!("CONNECT {addr} HTTP/1.1\r\n\r\n");
    let mut clients = Vec::new();
    let mut servers = Vec::new();
    // Finite loop: fill exactly the specified 256 slots; every wait is bounded.
    for _ in 0..256 {
        let mut client = bounded(TcpStream::connect(proxy)).await.unwrap();
        client.write_all(request.as_bytes()).await.unwrap();
        servers.push(bounded(target.accept()).await.unwrap().0);
        assert!(headers(&mut client).await.starts_with("HTTP/1.1 200 "));
        clients.push(client);
    }
    let mut extra = bounded(TcpStream::connect(proxy)).await.unwrap();
    extra.write_all(request.as_bytes()).await.unwrap();
    assert!(tokio::time::timeout(Duration::from_millis(50), target.accept()).await.is_err());
    drop(clients.pop());
    servers.push(bounded(target.accept()).await.unwrap().0);
    assert!(headers(&mut extra).await.starts_with("HTTP/1.1 200 "));
    stop.cancel();
    bounded(task).await.unwrap().unwrap();
}

#[tokio::test]
async fn stop_cancels_a_partial_header_read() {
    let (l, proxy) = listener();
    let stop = CancellationToken::new();
    let task = tokio::spawn(serve_proxy(l, NetPolicy::default(), stop.clone()));
    let mut client = TcpStream::connect(proxy).await.unwrap();
    client.write_all(b"CONNECT ").await.unwrap();
    tokio::task::yield_now().await;
    stop.cancel();
    bounded(task).await.unwrap().unwrap();
    let mut byte = [0];
    let result = bounded(client.read(&mut byte)).await;
    assert!(matches!(result, Ok(0) | Err(_)), "a partial request survived cancellation");
}

#[tokio::test]
async fn absolute_form_cannot_reach_mapped_loopback() {
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = target.local_addr().unwrap().port();
    let (l, proxy) = listener();
    let stop = CancellationToken::new();
    let task = tokio::spawn(serve_proxy(l, NetPolicy { api: Some((port, true)) }, stop.clone()));
    let mut client = TcpStream::connect(proxy).await.unwrap();
    client
        .write_all(
            format!(
                "GET http://[::ffff:127.0.0.1]:{port}/ HTTP/1.1\r\nHost: harmless.example\r\n\r\n"
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    assert!(headers(&mut client).await.starts_with("HTTP/1.1 403 Forbidden\r\n"));
    assert!(tokio::time::timeout(Duration::from_millis(50), target.accept()).await.is_err());
    stop.cancel();
    bounded(task).await.unwrap().unwrap();
}

#[test]
fn request_targets_are_unambiguous() {
    for line in [
        "CONNECT host HTTP/1.1",
        "CONNECT host:0 HTTP/1.1",
        "CONNECT host:+443 HTTP/1.1",
        "CONNECT host:65536 HTTP/1.1",
        "CONNECT user@host:443 HTTP/1.1",
        "CONNECT [fe80::1%eth0]:80 HTTP/1.1",
        "GET /relative HTTP/1.1",
        "GET https://host/ HTTP/1.1",
        "GET http://host/#fragment HTTP/1.1",
        "GET http://host/ HTTP/1.0",
        "GET http://host/\r\nInjected:yes HTTP/1.1",
        "GET http://host/ HTTP/1.1 extra",
    ] {
        assert!(request(line).is_none(), "{line:?}");
    }
    assert_eq!(
        request("CONNECT [::ffff:8.8.8.8]:443 HTTP/1.1"),
        Some(("::ffff:8.8.8.8".into(), 443, None))
    );
    assert_eq!(
        request("GET http://host?x=1 HTTP/1.1"),
        Some(("host".into(), 80, Some("GET /?x=1 HTTP/1.1\r\n".into())))
    );
    assert_eq!(
        request("POST http://host:31415 HTTP/1.1"),
        Some(("host".into(), 31415, Some("POST / HTTP/1.1\r\n".into())))
    );
}

#[tokio::test]
async fn partial_header_deadline_is_thirty_seconds() {
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let mut client = TcpStream::connect(target.local_addr().unwrap()).await.unwrap();
    let (server, _) = bounded(target.accept()).await.unwrap();
    client.write_all(b"CONNECT ").await.unwrap();
    tokio::time::pause();
    let task = tokio::spawn(async move { proxy_connection(server, &|_| false).await });
    tokio::task::yield_now().await;
    tokio::time::advance(Duration::from_secs(29)).await;
    assert!(!task.is_finished(), "header expired before 30 seconds");
    tokio::time::advance(Duration::from_secs(1)).await;
    bounded(task).await.unwrap().unwrap();
    assert!(headers(&mut client).await.starts_with("HTTP/1.1 408 Request Timeout\r\n"));
}

#[tokio::test]
async fn running_out_of_descriptors_pauses_the_proxy_instead_of_ending_it() {
    const CHILD: &str = "ACPMUX_PROXY_TEST_EMFILE";
    const NAME: &str = "linux_sandbox::proxy::tests::running_out_of_descriptors_pauses_the_proxy_instead_of_ending_it";
    if std::env::var_os(CHILD).is_none() {
        let result = tokio::process::Command::new(std::env::current_exe().unwrap())
            .args(["--exact", NAME, "--nocapture", "--test-threads=1"])
            .env(CHILD, "1")
            .output()
            .await
            .unwrap();
        let stdout = String::from_utf8_lossy(&result.stdout);
        assert!(
            result.status.success() && stdout.contains("1 passed"),
            "isolated descriptor test failed: {stdout}\n{}",
            String::from_utf8_lossy(&result.stderr)
        );
        return;
    }
    // Only in the re-executed child: a full descriptor table would fail parallel tests.
    let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
    // SAFETY: plain getrlimit/setrlimit on a local struct, in this child process only.
    unsafe {
        assert_eq!(libc::getrlimit(libc::RLIMIT_NOFILE, &mut limit), 0);
        limit.rlim_cur = limit.rlim_cur.min(1024);
        assert_eq!(libc::setrlimit(libc::RLIMIT_NOFILE, &limit), 0);
    }
    let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (l, proxy) = listener();
    let stop = CancellationToken::new();
    let task = tokio::spawn(serve_forward(l, target.local_addr().unwrap(), stop.clone()));
    let mut spare = Vec::new();
    loop {
        match std::fs::File::open("/dev/null") {
            Ok(file) => spare.push(file),
            Err(e) => {
                assert_eq!(e.raw_os_error(), Some(libc::EMFILE));
                break;
            }
        }
    }
    // One free slot holds the client's socket, so the proxy's accept fails with EMFILE.
    spare.pop();
    let mut client = TcpStream::connect(proxy).await.unwrap();
    tokio::time::sleep(Duration::from_millis(300)).await;
    assert!(!task.is_finished(), "the proxy ended on EMFILE: {:?}", task.await);
    spare.clear();
    client.write_all(b"raw").await.unwrap();
    let (mut server, _) = bounded(target.accept()).await.unwrap();
    let mut bytes = [0; 3];
    bounded(server.read_exact(&mut bytes)).await.unwrap();
    assert_eq!(&bytes, b"raw");
    stop.cancel();
    bounded(task).await.unwrap().unwrap();
}

#[tokio::test]
async fn either_side_eof_ends_the_whole_tunnel() {
    for client_first in [true, false] {
        let target = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = target.local_addr().unwrap();
        let (mut client, stop, task) = stand_in(addr).await;
        client.write_all(format!("CONNECT {addr} HTTP/1.1\r\n\r\n").as_bytes()).await.unwrap();
        let (mut server, _) = bounded(target.accept()).await.unwrap();
        assert!(headers(&mut client).await.starts_with("HTTP/1.1 200 "));
        if client_first {
            client.shutdown().await.unwrap();
        } else {
            server.shutdown().await.unwrap();
        }
        let mut byte = [0];
        assert_eq!(bounded(client.read(&mut byte)).await.unwrap(), 0);
        assert_eq!(bounded(server.read(&mut byte)).await.unwrap(), 0);
        stop.cancel();
        bounded(task).await.unwrap().unwrap();
    }
}
