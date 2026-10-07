//! FETCH-PRIVATE-RANGES under a proxy store (browser-egress.md 7.3, ff
//! finding 2026-10-07). A proxy is an egress the session chooses: its own
//! address goes through the range rule (link-local is refused to every
//! session), and a remote (relay) session may set no proxy at all (7.3: BYO
//! exits are for local sessions only), because Chromium reports the PROXY's
//! address as a proxied response's remote address, so the host's
//! after-the-fact check never sees where the proxy went. A module of the
//! `chromium` test target.

use super::*;
use cmux_browser_host::gate::{Gate, Grants};
use cmux_browser_host::headless_source::{HeadlessBrowsers, HeadlessSession, HeadlessSource};
use cmux_browser_host::vm::VmHost;
use std::io::Read;
use std::sync::OnceLock;

/// A forward HTTP proxy on 127.0.0.2: it "resolves" every name to the
/// fixture server on 127.0.0.1:`upstream` and records the request lines.
fn forward_proxy(upstream: u16) -> (u16, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.2:0").expect("bind 127.0.0.2");
    let port = listener.local_addr().unwrap().port();
    let seen: Arc<Mutex<Vec<String>>> = Arc::default();
    let record = seen.clone();
    std::thread::spawn(move || {
        for client in listener.incoming().flatten() {
            let record = record.clone();
            std::thread::spawn(move || {
                let mut reader = BufReader::new(client.try_clone().unwrap());
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() || line.is_empty() {
                    return;
                }
                record.lock().unwrap().push(line.trim_end().to_owned());
                let mut parts = line.split_whitespace();
                let (method, target) = (parts.next().unwrap_or("GET"), parts.next().unwrap_or("/"));
                let mut client = client;
                if method == "CONNECT" {
                    let _ =
                        client.write_all(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n");
                    return;
                }
                let path = target
                    .split_once("://")
                    .and_then(|(_, rest)| rest.find('/').map(|at| rest[at..].to_owned()))
                    .unwrap_or_else(|| "/".to_owned());
                let mut headers = String::new();
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).unwrap_or(0) == 0 || header.trim().is_empty() {
                        break;
                    }
                    let name = header.split(':').next().unwrap_or("").trim().to_ascii_lowercase();
                    if !matches!(name.as_str(), "connection" | "proxy-connection" | "keep-alive") {
                        headers.push_str(&header);
                    }
                }
                let Ok(mut server) = std::net::TcpStream::connect(("127.0.0.1", upstream)) else {
                    return;
                };
                let request =
                    format!("{method} {path} HTTP/1.1\r\n{headers}Connection: close\r\n\r\n");
                if server.write_all(request.as_bytes()).is_err() {
                    return;
                }
                let mut response = Vec::new();
                let _ = server.read_to_end(&mut response);
                let _ = client.write_all(&response);
            });
        }
    });
    (port, seen)
}

/// A gated headless session (`remote` as CALLER-LOCALITY sets it) whose
/// engine events reach the gate as the host's would (rebinding checks), and
/// the events it saw.
fn gated_session(
    source: &Arc<HeadlessSource>,
    browsers: &HeadlessBrowsers,
    name: &str,
    remote: bool,
) -> (Arc<Gate>, Arc<Mutex<Vec<DriverEvent>>>) {
    let slot: Arc<OnceLock<Arc<Gate>>> = Arc::default();
    let events: Arc<Mutex<Vec<DriverEvent>>> = Arc::default();
    let (to_gate, seen) = (slot.clone(), events.clone());
    let sink: cmux_browser_host::driver::EventSink = Arc::new(move |event: DriverEvent| {
        if let Some(gate) = to_gate.get() {
            gate.mask_event(&event.name, &event.payload);
        }
        seen.lock().unwrap().push(event);
    });
    let lease = cmux_browser_host::lease::LeaseCaller {
        session: name.into(),
        actor: "t".into(),
        on_behalf_of: None,
        origin: "cli".into(),
        label: String::new(),
        implicit_session: false,
        engine: "headless".into(),
    };
    let session = HeadlessSession::new(source.clone(), browsers, Arc::from(AGENT), sink, lease)
        .expect("a headless session");
    let gate = Arc::new(Gate::new(Arc::new(session), Grants { remote, ..Grants::default() }));
    let _ = slot.set(gate.clone());
    (gate, events)
}

#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_proxy_cannot_carry_a_session_past_the_range_rule() {
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let (proxy_port, seen) = forward_proxy(port);
    let proxy = format!("http://127.0.0.2:{proxy_port}");
    let source =
        HeadlessSource::launch(&HeadlessOptions::new(binary.into()), Arc::from(AGENT), "agent")
            .expect("launch the shared browser");
    let browsers: HeadlessBrowsers = Arc::default();

    // A remote session: no proxy at all (BYO exits are local-only), so a
    // name the proxy resolves to loopback or metadata is never reached.
    let (remote, _) = gated_session(&source, &browsers, "remote", true);
    for server in [proxy.as_str(), "http://203.0.113.7:3128", "http://169.254.169.254:80"] {
        let refused = remote
            .driver_call("session.configure", json!({"proxy": {"server": server}}))
            .expect_err("a remote session sets no proxy");
        assert_eq!(refused.code, ErrorCode::Forbidden, "{server}: {refused}");
    }
    let opened = remote.driver_call("tabs.open", json!({"url": "http://inner.test/second"}));
    if let Ok(tab) = &opened {
        let title = remote
            .driver_call(
                "frame.evaluate",
                json!({"targetId": tab["targetId"], "world": "page", "source": "() => document.title"}),
            )
            .unwrap_or_default();
        assert_ne!(title, "Second", "the remote session reached loopback through the proxy");
    }
    assert!(
        seen.lock().unwrap().is_empty(),
        "no remote request reached the proxy: {:?}",
        seen.lock().unwrap()
    );

    // A local session: a proxy into link-local (metadata) is refused to
    // everyone; a loopback proxy is allowed for a local session.
    let (local, events) = gated_session(&source, &browsers, "local", false);
    let refused = local
        .driver_call("session.configure", json!({"proxy": {"server": "http://169.254.169.254:80"}}))
        .expect_err("a link-local proxy is refused");
    assert_eq!(refused.code, ErrorCode::Forbidden, "{refused}");
    let answer = local
        .driver_call("session.configure", json!({"proxy": {"server": proxy}}))
        .expect("a local session may use a loopback proxy");
    assert_eq!(answer["proxy"], true, "{answer}");
    let tab = local
        .driver_call("tabs.open", json!({"url": "http://inner.test/second"}))
        .expect("open through the proxy")["targetId"]
        .as_str()
        .unwrap()
        .to_owned();
    let deadline = Instant::now() + Duration::from_secs(10);
    let address = loop {
        let found = events.lock().unwrap().iter().find_map(|event| {
            (event.name == "response"
                && event.payload["url"].as_str().is_some_and(|u| u.contains("inner.test")))
            .then(|| event.payload["remoteIPAddress"].clone())
        });
        if let Some(address) = found {
            break address;
        }
        assert!(Instant::now() < deadline, "no response from inner.test");
        std::thread::sleep(Duration::from_millis(20));
    };
    // FACT for browser-egress.md 7.3: a proxied response reports the
    // proxy's address, never the address the proxy reached.
    assert_eq!(address, "127.0.0.2", "the remote address of a proxied response");
    assert!(seen.lock().unwrap().iter().any(|line| line.contains("inner.test")), "via the proxy");
    // A literal link-local address is refused before dispatch, proxy or not.
    let metadata = local
        .driver_call("tabs.open", json!({"url": "http://169.254.169.254/latest/meta-data/"}))
        .expect_err("metadata is refused to every session");
    assert_eq!(metadata.code, ErrorCode::Forbidden, "{metadata}");
    let _ = local.driver_call("tabs.close", json!({"targetId": tab}));
}

/// A page fetch (net.fetch with the page's tab) on an http page that is not
/// loopback: an insecure context, where the host world has no
/// `crypto.randomUUID`. The proxy gives the test such an origin
/// (`http://inner.test`).
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_page_fetch_works_on_an_insecure_http_page() {
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let (proxy_port, _) = forward_proxy(port);
    let source =
        HeadlessSource::launch(&HeadlessOptions::new(binary.into()), Arc::from(AGENT), "agent")
            .expect("launch the shared browser");
    let browsers: HeadlessBrowsers = Arc::default();
    let (local, _) = gated_session(&source, &browsers, "local", false);
    local
        .driver_call(
            "session.configure",
            json!({"proxy": {"server": format!("http://127.0.0.2:{proxy_port}")}}),
        )
        .unwrap();
    let tab = local
        .driver_call("tabs.open", json!({"url": "http://inner.test/second"}))
        .unwrap()["targetId"]
        .as_str()
        .unwrap()
        .to_owned();
    let secure = local
        .driver_call(
            "frame.evaluate",
            json!({"targetId": tab, "world": "page", "source": "() => isSecureContext"}),
        )
        .unwrap();
    assert_eq!(secure, false, "the page is an insecure context");
    let fetched = local
        .driver_call("net.fetch", json!({"targetId": tab, "url": "http://inner.test/second"}))
        .unwrap_or_else(|error| panic!("page fetch on an http page: {error}"));
    assert_eq!(fetched["status"], 200, "{fetched}");
    let _ = local.driver_call("tabs.close", json!({"targetId": tab}));
}
