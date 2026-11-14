use super::*;
use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::Value;
use std::io;
use std::time::Duration;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio_tungstenite::tungstenite::Message;

/// Tiny dev-server double: "/" is HTML with a head, "/body-only" has no
/// head, "/plain" is not HTML, "/opt-out" answers with the no-inject
/// response header.
pub(super) async fn spawn_target() -> u16 {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.expect("target bind");
    let port = listener.local_addr().expect("target addr").port();
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { break };
            tokio::spawn(async move {
                let io = hyper_util::rt::TokioIo::new(stream);
                let service = hyper::service::service_fn(|request| async move {
                    if request.uri().path() == "/oversized" {
                        let mut response = hyper::Response::new(full_body(vec![
                            b'x';
                            PREVIEW_HTML_BODY_MAX_BYTES
                                + 1
                        ]));
                        response.headers_mut().insert(
                            hyper::header::CONTENT_TYPE,
                            hyper::header::HeaderValue::from_static("text/html"),
                        );
                        return Ok::<_, std::convert::Infallible>(response);
                    }
                    let (body, content_type, opt_out) = match request.uri().path() {
                        "/body-only" => ("<body><p>hi</p></body>", "text/html", false),
                        "/plain" => ("no tags here", "text/plain", false),
                        "/opt-out" => {
                            ("<html><head></head><body></body></html>", "text/html", true)
                        }
                        _ => (
                            "<html><head><title>t</title></head><body></body></html>",
                            "text/html; charset=utf-8",
                            false,
                        ),
                    };
                    let mut response = hyper::Response::new(full_body(body.as_bytes().to_vec()));
                    response.headers_mut().insert(
                        hyper::header::CONTENT_TYPE,
                        hyper::header::HeaderValue::from_str(content_type).expect("ct"),
                    );
                    if opt_out {
                        response
                            .headers_mut()
                            .insert(NO_INJECT_HEADER, hyper::header::HeaderValue::from_static("1"));
                    }
                    Ok::<_, std::convert::Infallible>(response)
                });
                let _ =
                    hyper::server::conn::http1::Builder::new().serve_connection(io, service).await;
            });
        }
    });
    port
}

pub(super) async fn spawn_upgrade_target() -> u16 {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.expect("target bind");
    let port = listener.local_addr().expect("target addr").port();
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { break };
            tokio::spawn(async move {
                let io = hyper_util::rt::TokioIo::new(stream);
                let service = hyper::service::service_fn(|request| async move {
                    let on_upgrade = hyper::upgrade::on(request);
                    let response = hyper::Response::builder()
                        .status(hyper::StatusCode::SWITCHING_PROTOCOLS)
                        .header(hyper::header::UPGRADE, "websocket")
                        .header(hyper::header::CONNECTION, "Upgrade")
                        .body(full_body(Vec::new()))
                        .expect("upgrade response");
                    tokio::spawn(async move {
                        if let Ok(upgraded) = on_upgrade.await {
                            let _ = tokio::time::sleep(Duration::from_secs(30)).await;
                            drop(upgraded);
                        }
                    });
                    Ok::<_, std::convert::Infallible>(response)
                });
                let _ = hyper::server::conn::http1::Builder::new()
                    .serve_connection(io, service)
                    .with_upgrades()
                    .await;
            });
        }
    });
    port
}

async fn open_proxy(registry: &PreviewRegistry, target_port: u16) -> u16 {
    open_proxy_credentials(registry, target_port).await.0
}

pub(super) async fn open_proxy_credentials(
    registry: &PreviewRegistry,
    target_port: u16,
) -> (u16, String) {
    match registry.open(i64::from(target_port)).await.expect("preview_open") {
        wire::WorkspaceResultBody::PreviewOpen(result) => {
            (u16::try_from(result.proxy_port).expect("port range"), result.capability)
        }
        other => panic!("wrong body: {other:?}"),
    }
}

async fn http_get(
    port: u16,
    path: &str,
    headers: &[(&str, &str)],
) -> (reqwest::StatusCode, reqwest::header::HeaderMap, String) {
    // reqwest's rustls-no-provider build needs the process default
    // provider, exactly like main() installs it.
    let _ = rustls::crypto::ring::default_provider().install_default();
    let client = reqwest::Client::new();
    let mut request = client.get(format!("http://127.0.0.1:{port}{path}"));
    for (name, value) in headers {
        request = request.header(*name, *value);
    }
    let response = request.send().await.expect("http response");
    let status = response.status();
    let headers = response.headers().clone();
    (status, headers, response.text().await.expect("body"))
}

async fn open_upgrade(port: u16, key: &str, capability: &str) -> tokio::net::TcpStream {
    let mut stream =
        tokio::net::TcpStream::connect(("127.0.0.1", port)).await.expect("connect preview proxy");
    let request = format!(
        "GET /hmr HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n{CAPABILITY_HEADER}: {capability}\r\n\r\n"
    );
    stream.write_all(request.as_bytes()).await.expect("write upgrade request");
    let mut response = Vec::new();
    let mut chunk = [0_u8; 512];
    loop {
        let read = tokio::time::timeout(Duration::from_secs(2), stream.read(&mut chunk))
            .await
            .expect("upgrade response timeout")
            .expect("read upgrade response");
        assert!(read > 0, "upgrade response ended before headers");
        response.extend_from_slice(&chunk[..read]);
        if response.windows(4).any(|window| window == b"\r\n\r\n") {
            break;
        }
        assert!(response.len() < 8192, "upgrade response headers too large");
    }
    assert!(response.starts_with(b"HTTP/1.1 101"), "upgrade response: {response:?}");
    stream
}

#[tokio::test]
async fn injects_into_html_and_honors_the_opt_outs() {
    let registry = PreviewRegistry::new();
    let target = spawn_target().await;
    let (proxy, capability) = open_proxy_credentials(&registry, target).await;
    let (status, _, body) = http_get(proxy, "/", &[(CAPABILITY_HEADER, &capability)]).await;
    assert_eq!(status, 200);
    let tag_at =
        body.find("<script src=\"/__chatmux__/target.js?capability=").expect("tag injected");
    assert!(body[tag_at..].contains(&format!("capability={capability}")));
    let head_at = body.find("</head>").expect("head kept");
    assert!(tag_at < head_at, "before </head>");

    let (_, _, body) = http_get(proxy, "/body-only", &[(CAPABILITY_HEADER, &capability)]).await;
    let tag_at =
        body.find("<script src=\"/__chatmux__/target.js?capability=").expect("tag injected");
    assert!(body[..tag_at].contains("<body>"), "after the <body> tag");

    let (_, _, body) = http_get(proxy, "/plain", &[(CAPABILITY_HEADER, &capability)]).await;
    assert!(!body.contains("/__chatmux__/target.js?capability="), "non-HTML passes through");

    let (_, _, body) = http_get(proxy, "/opt-out", &[(CAPABILITY_HEADER, &capability)]).await;
    assert!(!body.contains("/__chatmux__/target.js?capability="), "response header opts out");

    let (status, _, body) =
        http_get(proxy, "/oversized", &[(CAPABILITY_HEADER, &capability)]).await;
    assert_eq!(status, 502);
    assert!(body.contains("target HTML response exceeds"));

    let (_, _, body) =
        http_get(proxy, "/", &[(NO_INJECT_HEADER, "1"), (CAPABILITY_HEADER, &capability)]).await;
    assert!(!body.contains("/__chatmux__/target.js?capability="), "request header opts out");

    // Reuse: the same target port keeps its proxy port.
    let (reused_proxy, reused_capability) = open_proxy_credentials(&registry, target).await;
    assert_eq!(reused_proxy, proxy);
    assert_eq!(reused_capability, capability);
    registry.shutdown().await;
    assert!(registry.proxies.lock().await.is_empty(), "shutdown drops every proxy");
}

#[tokio::test]
async fn rejects_preview_connections_after_the_active_connection_cap() {
    let registry = PreviewRegistry::new();
    let target = spawn_target().await;
    let proxy = open_proxy(&registry, target).await;
    let mut held = Vec::with_capacity(PREVIEW_PROXY_CONNECTION_CAP);
    for _ in 0..PREVIEW_PROXY_CONNECTION_CAP {
        let mut stream = tokio::net::TcpStream::connect(("127.0.0.1", proxy))
            .await
            .expect("connect preview proxy");
        stream
            .write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\n")
            .await
            .expect("hold preview request open");
        held.push(stream);
    }
    tokio::task::yield_now().await;

    let mut rejected = tokio::net::TcpStream::connect(("127.0.0.1", proxy))
        .await
        .expect("connect over-cap preview client");
    rejected
        .write_all(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        .await
        .expect("write over-cap preview request");
    let mut response = [0_u8; 1];
    let read = tokio::time::timeout(Duration::from_secs(1), rejected.read(&mut response))
        .await
        .expect("over-cap preview client did not close");
    match read {
        Ok(0) => {}
        Err(error) => assert!(matches!(
            error.kind(),
            io::ErrorKind::ConnectionReset | io::ErrorKind::UnexpectedEof
        )),
        Ok(bytes) => panic!("over-cap preview client received {bytes} bytes"),
    }
    drop(held);
    registry.shutdown().await;
}

#[tokio::test]
async fn rejects_upgrades_after_the_copy_task_cap() {
    let registry = PreviewRegistry::new();
    let target = spawn_upgrade_target().await;
    let (proxy, capability) = open_proxy_credentials(&registry, target).await;
    let mut held = Vec::with_capacity(PREVIEW_PROXY_UPGRADE_CAP);
    for index in 0..PREVIEW_PROXY_UPGRADE_CAP {
        held.push(open_upgrade(proxy, &format!("dGhlIHNhbXBsZSA{index:02}"), &capability).await);
    }

    let mut over_cap = tokio::net::TcpStream::connect(("127.0.0.1", proxy))
        .await
        .expect("connect over-cap upgrade");
    over_cap
            .write_all(
                format!(
                    "GET /hmr HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSA2NA==\r\nSec-WebSocket-Version: 13\r\n{CAPABILITY_HEADER}: {capability}\r\n\r\n"
                )
                .as_bytes(),
            )
            .await
            .expect("write over-cap upgrade");
    let mut response = [0_u8; 512];
    let bytes = tokio::time::timeout(Duration::from_secs(2), over_cap.read(&mut response))
        .await
        .expect("over-cap response timeout")
        .expect("read over-cap response");
    assert!(
        std::str::from_utf8(&response[..bytes]).expect("response utf8").starts_with("HTTP/1.1 503")
    );

    drop(held);
    registry.shutdown().await;
}

/// One raw HTTP/1.1 exchange against the proxy, returning the response
/// head (status line plus headers) lowercased. Lets a test pin the Host
/// header, which reqwest always derives from the URL.
pub(super) async fn raw_response_head(port: u16, request: &str) -> String {
    let mut stream =
        tokio::net::TcpStream::connect(("127.0.0.1", port)).await.expect("connect preview proxy");
    stream.write_all(request.as_bytes()).await.expect("write raw request");
    let mut response = Vec::new();
    let mut chunk = [0_u8; 1024];
    loop {
        let read = tokio::time::timeout(Duration::from_secs(2), stream.read(&mut chunk))
            .await
            .expect("raw response timeout")
            .expect("read raw response");
        if read == 0 {
            break;
        }
        response.extend_from_slice(&chunk[..read]);
        if let Some(end) = response.windows(4).position(|window| window == b"\r\n\r\n") {
            response.truncate(end);
            break;
        }
        assert!(response.len() < 16_384, "raw response head too large");
    }
    String::from_utf8(response).expect("raw response utf8").to_ascii_lowercase()
}

#[tokio::test]
async fn status_cors_grant_requires_the_preview_capability() {
    let registry = PreviewRegistry::with_public_host_suffixes(["preview.test"]);
    let target = spawn_target().await;
    let (proxy, capability) = open_proxy_credentials(&registry, target).await;
    let origin = "http://localhost:3000";

    // An Origin without the preview capability gets no cross-origin
    // read grant: an arbitrary website must not learn preview state.
    let (status, headers, _) = http_get(proxy, "/__chatmux__/status", &[("origin", origin)]).await;
    assert_eq!(status, 200);
    assert!(headers.get("access-control-allow-origin").is_none());
    assert!(headers.get("access-control-allow-credentials").is_none());

    // A guessed value of the right shape is refused the same way.
    let wrong = "0".repeat(capability.len());
    let (_, headers, _) =
        http_get(proxy, &format!("/__chatmux__/status?capability={wrong}"), &[("origin", origin)])
            .await;
    assert!(headers.get("access-control-allow-origin").is_none());

    // The devtools drawer presents the capability preview_open handed
    // it and keeps its credentialed cross-origin poll.
    let (status, headers, body) = http_get(
        proxy,
        &format!("/__chatmux__/status?capability={capability}"),
        &[("origin", origin)],
    )
    .await;
    assert_eq!(status, 200);
    assert_eq!(body, "{\"targetConnected\":false}");
    assert_eq!(
        headers.get("access-control-allow-origin").and_then(|value| value.to_str().ok()),
        Some(origin),
    );
    assert_eq!(
        headers.get("access-control-allow-credentials").and_then(|value| value.to_str().ok()),
        Some("true"),
    );
    assert_eq!(headers.get("vary").and_then(|value| value.to_str().ok()), Some("Origin"));

    // Even with the capability, an origin the devtools admission
    // refuses (a public website against the loopback listener) gets no
    // grant.
    let (_, headers, _) = http_get(
        proxy,
        &format!("/__chatmux__/status?capability={capability}"),
        &[("origin", "https://evil.example")],
    )
    .await;
    assert!(headers.get("access-control-allow-origin").is_none());

    // Same-origin probes (no Origin header) stay plain.
    let (status, headers, body) = http_get(proxy, "/__chatmux__/status", &[]).await;
    assert_eq!(status, 200);
    assert_eq!(body, "{\"targetConnected\":false}");
    assert!(headers.get("access-control-allow-origin").is_none());

    // The tunneled drawer (public Host, https Origin) keeps its grant
    // when it presents the capability...
    let head = raw_response_head(
            proxy,
            &format!(
                "GET /__chatmux__/status?capability={capability} HTTP/1.1\r\nHost: p1.preview.test\r\nOrigin: https://chatmux.dev\r\nConnection: close\r\n\r\n"
            ),
        )
        .await;
    assert!(head.contains("access-control-allow-origin: https://chatmux.dev"), "{head}");
    // ...and a preflight is gated exactly like the read.
    let head = raw_response_head(
            proxy,
            &format!(
                "OPTIONS /__chatmux__/status?capability={capability} HTTP/1.1\r\nHost: localhost\r\nOrigin: {origin}\r\nAccess-Control-Request-Headers: x-requested-with\r\nConnection: close\r\n\r\n"
            ),
        )
        .await;
    assert!(head.starts_with("http/1.1 204"), "{head}");
    assert!(head.contains(&format!("access-control-allow-origin: {origin}")), "{head}");
    assert!(head.contains("access-control-allow-headers: x-requested-with"), "{head}");
    let head = raw_response_head(
            proxy,
            &format!(
                "OPTIONS /__chatmux__/status HTTP/1.1\r\nHost: localhost\r\nOrigin: {origin}\r\nConnection: close\r\n\r\n"
            ),
        )
        .await;
    assert!(head.starts_with("http/1.1 204"), "{head}");
    assert!(!head.contains("access-control-allow-origin"), "{head}");
    registry.shutdown().await;
}

#[tokio::test]
async fn serves_the_vendored_connector_bundle() {
    let registry = PreviewRegistry::new();
    let target = spawn_target().await;
    let proxy = open_proxy(&registry, target).await;
    let (status, headers, body) = http_get(proxy, "/__chatmux__/target.js", &[]).await;
    assert_eq!(status, 200);
    assert!(
        headers
            .get("content-type")
            .and_then(|value| value.to_str().ok())
            .is_some_and(|value| value.starts_with("application/javascript")),
    );
    assert!(body.contains("chobitsu"));
    assert!(body.contains("/__chatmux__/page"));
    assert!(body.contains("searchParams.get('capability')"));
    registry.shutdown().await;
}

async fn connect_ws(
    port: u16,
    path: &str,
    capability: &str,
) -> tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>> {
    let (socket, _) = tokio_tungstenite::connect_async(format!(
        "ws://127.0.0.1:{port}{path}?capability={capability}"
    ))
    .await
    .expect("ws connect");
    socket
}

async fn next_text<S>(socket: &mut S, what: &str) -> String
where
    S: futures_util::Stream<Item = Result<Message, tungstenite::Error>> + Unpin,
{
    loop {
        let message = tokio::time::timeout(Duration::from_secs(10), socket.next())
            .await
            .unwrap_or_else(|_| panic!("no {what} within 10s"))
            .unwrap_or_else(|| panic!("{what}: socket ended"))
            .unwrap_or_else(|error| panic!("{what}: {error}"));
        match message {
            Message::Text(text) => return text.as_str().to_owned(),
            Message::Close(frame) => panic!("{what}: closed early: {frame:?}"),
            _ => {}
        }
    }
}

#[tokio::test]
async fn pipes_page_and_devtools_tees_the_ring_and_replaces_stale_pages() {
    let registry = PreviewRegistry::new();
    let target = spawn_target().await;
    let (proxy, capability) = open_proxy_credentials(&registry, target).await;

    // Fake CDP page peer: the proxy enables its tee domains first.
    let mut page = connect_ws(proxy, "/__chatmux__/page", &capability).await;
    let mut enabled = Vec::new();
    for _ in 0..3 {
        let frame: Value = serde_json::from_str(&next_text(&mut page, "enable command").await)
            .expect("enable json");
        assert!(frame["id"].as_i64().expect("id") >= PROXY_CDP_ID_BASE);
        enabled.push(frame["method"].as_str().unwrap_or_default().to_owned());
        page.send(Message::text(format!("{{\"id\":{},\"result\":{{}}}}", frame["id"])))
            .await
            .expect("ack enable");
    }
    assert!(enabled.contains(&"Runtime.enable".to_owned()));
    assert!(enabled.contains(&"Network.enable".to_owned()));

    // The status endpoint now reports the page.
    let (_, _, body) = http_get(proxy, "/__chatmux__/status", &[]).await;
    assert_eq!(body, "{\"targetConnected\":true}");

    // DevTools frontend speaks through the proxy to the page...
    let mut devtools = connect_ws(proxy, "/__chatmux__/devtools", &capability).await;
    devtools
        .send(Message::text("{\"id\":1,\"method\":\"Runtime.evaluate\"}"))
        .await
        .expect("devtools send");
    let seen = next_text(&mut page, "piped devtools command").await;
    assert!(seen.contains("Runtime.evaluate"));
    // ...and answers flow back (the proxy's own enable acks never do).
    page.send(Message::text("{\"id\":1,\"result\":{\"value\":7}}")).await.expect("page reply");
    let reply = next_text(&mut devtools, "piped page reply").await;
    assert!(reply.contains("\"value\":7"));

    // Console + network events tee into the preview_console_tail ring.
    let console = serde_json::json!({
        "method": "Runtime.consoleAPICalled",
        "params": {"type": "error", "args": [
            {"type": "string", "value": "boom"},
            {"type": "object", "description": "Error: bad"},
        ]},
    });
    page.send(Message::text(console.to_string())).await.expect("console event");
    let network_sent = serde_json::json!({
        "method": "Network.requestWillBeSent",
        "params": {"requestId": "r1", "request": {"method": "GET", "url": "http://x/api"}},
    });
    let network_done = serde_json::json!({
        "method": "Network.responseReceived",
        "params": {"requestId": "r1", "response": {"status": 500}},
    });
    page.send(Message::text(network_sent.to_string())).await.expect("network sent");
    page.send(Message::text(network_done.to_string())).await.expect("network done");
    // Both also pipe to devtools (console first).
    assert!(next_text(&mut devtools, "console pipe").await.contains("consoleAPICalled"));
    let tail = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let body = registry.tail(None).expect("tail");
            let wire::WorkspaceResultBody::PreviewConsoleTail(result) = &body else {
                panic!("wrong body");
            };
            if result.events.len() >= 2 {
                break result.events.clone();
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("ring filled");
    let has_console = tail.iter().any(|event| match event {
        wire::PreviewEvent::Console(console) => {
            console.text.contains("boom") && console.text.contains("Error: bad")
        }
        wire::PreviewEvent::Network(_) => false,
    });
    let has_network = tail.iter().any(|event| match event {
        wire::PreviewEvent::Network(network) => {
            network.url == "http://x/api" && network.status == Some(500) && !network.ok
        }
        wire::PreviewEvent::Console(_) => false,
    });
    assert!(has_console, "console teed: {tail:?}");
    assert!(has_network, "network teed: {tail:?}");

    // Latest page connection wins; the earlier one gets a close frame.
    let mut replacement = connect_ws(proxy, "/__chatmux__/page", &capability).await;
    let closed = tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            match page.next().await {
                Some(Ok(Message::Close(frame))) => break frame,
                Some(Ok(_)) => {}
                other => panic!("stale page ended without a close frame: {other:?}"),
            }
        }
    })
    .await
    .expect("close frame within 10s")
    .expect("close carries a frame");
    assert_eq!(u16::from(closed.code), REPLACED_CLOSE_CODE);
    // The replacement is now the live page (it gets fresh enables).
    let fresh: Value =
        serde_json::from_str(&next_text(&mut replacement, "enable").await).expect("enable json");
    assert!(fresh["id"].as_i64().expect("id") >= PROXY_CDP_ID_BASE);
}

pub(super) type TestSocket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

pub(super) async fn ws_handshake(
    port: u16,
    path: &str,
    capability: Option<&str>,
    headers: &[(&str, &str)],
) -> Result<TestSocket, tungstenite::Error> {
    use tokio_tungstenite::tungstenite::client::IntoClientRequest as _;
    let path = capability
        .map(|capability| format!("{path}?capability={capability}"))
        .unwrap_or_else(|| path.to_owned());
    let mut request =
        format!("ws://127.0.0.1:{port}{path}").into_client_request().expect("ws request");
    for (name, value) in headers {
        request.headers_mut().insert(
            hyper::header::HeaderName::from_bytes(name.as_bytes()).expect("header name"),
            hyper::header::HeaderValue::from_str(value).expect("header value"),
        );
    }
    tokio_tungstenite::connect_async(request).await.map(|(socket, _)| socket)
}

pub(super) fn refused_with_forbidden(outcome: Result<TestSocket, tungstenite::Error>) -> bool {
    matches!(outcome, Err(tungstenite::Error::Http(response)) if response.status() == 403)
}

#[tokio::test]
async fn control_sockets_refuse_cross_site_browser_origins() {
    let registry = PreviewRegistry::with_public_host_suffixes(["preview.test"]);
    let target = spawn_target().await;
    let (proxy, capability) = open_proxy_credentials(&registry, target).await;

    // A public web page the user visits can dial the loopback port; its
    // browser stamps the page's Origin on the handshake.
    for path in ["/__chatmux__/page", "/__chatmux__/devtools"] {
        for origin in ["https://evil.example", "http://evil.example", "null"] {
            let outcome = ws_handshake(proxy, path, Some(&capability), &[("origin", origin)]).await;
            assert!(refused_with_forbidden(outcome), "{path} accepted Origin {origin}");
        }
    }
    // DNS rebinding: a plain-http page whose name now resolves to
    // loopback. Its Host is its own name, and it cannot present TLS.
    let rebinding_host = format!("rebind.example:{proxy}");
    let rebinding_origin = format!("http://{rebinding_host}");
    let outcome = ws_handshake(
        proxy,
        "/__chatmux__/devtools",
        Some(&capability),
        &[("host", &rebinding_host), ("origin", &rebinding_origin)],
    )
    .await;
    assert!(refused_with_forbidden(outcome), "rebinding origin accepted");
    // Through the TLS tunnel the page channel stays same-origin only.
    let outcome = ws_handshake(
        proxy,
        "/__chatmux__/page",
        Some(&capability),
        &[("host", "p1.preview.test"), ("origin", "https://chatmux.dev")],
    )
    .await;
    assert!(refused_with_forbidden(outcome), "cross-origin page accepted");
    // A sibling preview can present a valid HTTPS Origin, but cannot know
    // this preview's capability and therefore cannot attach its DevTools.
    let outcome = ws_handshake(
        proxy,
        "/__chatmux__/devtools",
        None,
        &[("host", "p1.preview.test"), ("origin", "https://q1.preview.test")],
    )
    .await;
    assert!(refused_with_forbidden(outcome), "sibling preview attached without capability");
    // A guessed capability of the right shape is refused on both
    // control sockets.
    let wrong_capability = "0".repeat(capability.len());
    for path in ["/__chatmux__/page", "/__chatmux__/devtools"] {
        let outcome = ws_handshake(proxy, path, Some(&wrong_capability), &[]).await;
        assert!(refused_with_forbidden(outcome), "{path} accepted a guessed capability");
    }

    // The legitimate peers still connect: the injected connector on the
    // proxy's own origin, a local DevTools frontend, the tunneled page,
    // the chatmux web app's DevTools drawer, and non-browser clients.
    let local_origin = format!("http://127.0.0.1:{proxy}");
    ws_handshake(proxy, "/__chatmux__/page", Some(&capability), &[("origin", &local_origin)])
        .await
        .expect("same-origin loopback page");
    ws_handshake(
        proxy,
        "/__chatmux__/devtools",
        Some(&capability),
        &[("origin", "http://localhost:3000")],
    )
    .await
    .expect("loopback devtools");
    ws_handshake(
        proxy,
        "/__chatmux__/page",
        Some(&capability),
        &[("host", "p1.preview.test"), ("origin", "https://p1.preview.test")],
    )
    .await
    .expect("tunneled same-origin page");
    ws_handshake(
        proxy,
        "/__chatmux__/devtools",
        Some(&capability),
        &[("host", "p1.preview.test"), ("origin", "https://chatmux.dev")],
    )
    .await
    .expect("tunneled devtools drawer");
    ws_handshake(proxy, "/__chatmux__/devtools", Some(&capability), &[])
        .await
        .expect("originless client");
    registry.shutdown().await;
}
