//! Real-socket tests of the preview proxy's access rules
//! (`preview_access`): the Host allowlist, the proxied-path capability,
//! credential stripping and same-origin writes.

use std::time::Duration;

use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

use super::tests::{
    open_proxy_credentials, raw_response_head, refused_with_forbidden, spawn_upgrade_target,
    ws_handshake,
};
use super::*;
use crate::preview_access::CAPABILITY_QUERY;

/// Dev-server double: "/echo" answers what the dev server sees of the
/// request (query, every Cookie value, Referer and the capability header,
/// one per line); every other path is HTML.
async fn spawn_echo_target() -> u16 {
    let listener = tokio::net::TcpListener::bind(("127.0.0.1", 0)).await.expect("target bind");
    let port = listener.local_addr().expect("target addr").port();
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { break };
            tokio::spawn(async move {
                let io = hyper_util::rt::TokioIo::new(stream);
                let service = hyper::service::service_fn(|request| async move {
                    if request.uri().path() == "/echo" {
                        // What the dev server sees of the request: the
                        // query, every Cookie value and the capability
                        // header, one per line.
                        let mut seen =
                            format!("query={}\n", request.uri().query().unwrap_or_default());
                        for value in request.headers().get_all(hyper::header::COOKIE) {
                            seen.push_str(&format!(
                                "cookie={}\n",
                                String::from_utf8_lossy(value.as_bytes())
                            ));
                        }
                        for value in request.headers().get_all(hyper::header::REFERER) {
                            seen.push_str(&format!(
                                "referer={}\n",
                                value.to_str().unwrap_or_default()
                            ));
                        }
                        for value in request.headers().get_all("x-chatmux-capability") {
                            seen.push_str(&format!(
                                "header={}\n",
                                value.to_str().unwrap_or_default()
                            ));
                        }
                        let mut response = hyper::Response::new(full_body(seen.into_bytes()));
                        response.headers_mut().insert(
                            hyper::header::CONTENT_TYPE,
                            hyper::header::HeaderValue::from_static("text/plain"),
                        );
                        return Ok::<_, std::convert::Infallible>(response);
                    }
                    let mut response = hyper::Response::new(full_body(
                        b"<html><head><title>t</title></head><body></body></html>".to_vec(),
                    ));
                    response.headers_mut().insert(
                        hyper::header::CONTENT_TYPE,
                        hyper::header::HeaderValue::from_static("text/html"),
                    );
                    Ok::<_, std::convert::Infallible>(response)
                });
                let _ =
                    hyper::server::conn::http1::Builder::new().serve_connection(io, service).await;
            });
        }
    });
    port
}

/// The full raw HTTP/1.1 response (head and body) of one request that
/// asks the proxy to close the connection.
async fn raw_exchange(port: u16, request: &str) -> String {
    let mut stream =
        tokio::net::TcpStream::connect(("127.0.0.1", port)).await.expect("connect preview proxy");
    stream.write_all(request.as_bytes()).await.expect("write raw request");
    let mut response = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), stream.read_to_end(&mut response))
        .await
        .expect("raw exchange timeout")
        .expect("read raw exchange");
    String::from_utf8(response).expect("raw exchange utf8")
}

fn get_request(path: &str, host: &str, extra: &str) -> String {
    format!("GET {path} HTTP/1.1\r\nHost: {host}\r\n{extra}Connection: close\r\n\r\n")
}

fn upgrade_request(path: &str, host: &str, extra: &str) -> String {
    format!(
        "GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n{extra}\r\n"
    )
}

#[tokio::test]
async fn proxied_requests_and_upgrades_require_the_preview_capability() {
    let registry = PreviewRegistry::new();
    let target = spawn_echo_target().await;
    let (proxy, capability) = open_proxy_credentials(&registry, target).await;
    let host = format!("localhost:{proxy}");
    let cookie = format!("__chatmux_preview_{proxy}");
    let wrong = "0".repeat(capability.len());

    // Missing and wrong capabilities: no byte of the dev server leaks.
    for extra in [
        String::new(),
        format!("x-chatmux-capability: {wrong}\r\n"),
        format!("Cookie: {cookie}={wrong}\r\n"),
    ] {
        let response = raw_exchange(proxy, &get_request("/", &host, &extra)).await;
        assert!(response.starts_with("HTTP/1.1 401"), "{extra:?}: {response}");
        assert!(!response.contains("<title>t</title>"), "{extra:?} leaked the page");
    }
    let response =
        raw_exchange(proxy, &get_request(&format!("/?__chatmux_capability={wrong}"), &host, ""))
            .await;
    assert!(response.starts_with("HTTP/1.1 401"), "wrong bootstrap: {response}");

    // A valid header passes.
    let response = raw_exchange(
        proxy,
        &get_request("/", &host, &format!("x-chatmux-capability: {capability}\r\n")),
    )
    .await;
    assert!(response.starts_with("HTTP/1.1 200"), "header: {response}");
    assert!(response.contains("<title>t</title>"));

    // The navigation bootstrap trades the query capability for an
    // HttpOnly cookie and drops it from the visible URL.
    let response = raw_exchange(
        proxy,
        &get_request(&format!("/app?__chatmux_capability={capability}&x=1"), &host, ""),
    )
    .await;
    let lower = response.to_ascii_lowercase();
    assert!(lower.starts_with("http/1.1 302"), "bootstrap: {response}");
    assert!(lower.contains("\r\nlocation: /app?x=1\r\n"), "bootstrap: {response}");
    let set_cookie = lower
        .lines()
        .find(|line| line.starts_with("set-cookie:"))
        .expect("bootstrap sets a cookie")
        .to_owned();
    assert!(set_cookie.contains(&format!("{cookie}={capability}")), "{set_cookie}");
    assert!(set_cookie.contains("httponly"), "{set_cookie}");
    assert!(set_cookie.contains("path=/"), "{set_cookie}");

    // The cookie passes, and the dev server never sees the credential
    // (other cookies of the app still reach it).
    let response = raw_exchange(
        proxy,
        &get_request("/", &host, &format!("Cookie: {cookie}={capability}\r\n")),
    )
    .await;
    assert!(response.starts_with("HTTP/1.1 200"), "cookie: {response}");
    let response = raw_exchange(
        proxy,
        &get_request(
            "/echo?a=1",
            &host,
            &format!(
                "Cookie: app=1; {cookie}={capability}; theme=dark\r\nx-chatmux-capability: {capability}\r\n"
            ),
        ),
    )
    .await;
    assert!(response.starts_with("HTTP/1.1 200"), "echo: {response}");
    assert!(!response.contains(&capability), "the dev server saw the capability: {response}");
    assert!(response.contains("cookie=app=1; theme=dark"), "{response}");
    assert!(response.contains("query=a=1"), "{response}");

    // Upstream WebSocket upgrades (a dev server's HMR socket) need it too.
    let upgrade_target = spawn_upgrade_target().await;
    let (upgrade_proxy, upgrade_capability) =
        open_proxy_credentials(&registry, upgrade_target).await;
    let upgrade_host = format!("localhost:{upgrade_proxy}");
    let upgrade_cookie = format!("__chatmux_preview_{upgrade_proxy}");
    for extra in [String::new(), format!("Cookie: {upgrade_cookie}={wrong}\r\n")] {
        let head =
            raw_response_head(upgrade_proxy, &upgrade_request("/hmr", &upgrade_host, &extra)).await;
        assert!(head.starts_with("http/1.1 401"), "upgrade {extra:?}: {head}");
    }
    let head = raw_response_head(
        upgrade_proxy,
        &upgrade_request(
            "/hmr",
            &upgrade_host,
            &format!("Cookie: {upgrade_cookie}={upgrade_capability}\r\n"),
        ),
    )
    .await;
    assert!(head.starts_with("http/1.1 101"), "upgrade with cookie: {head}");
    registry.shutdown().await;
}

#[tokio::test]
async fn a_rebinding_host_is_refused_on_every_path() {
    let registry = PreviewRegistry::new();
    let target = spawn_echo_target().await;
    let (proxy, capability) = open_proxy_credentials(&registry, target).await;
    let cookie = format!("__chatmux_preview_{proxy}");
    let credential = format!("x-chatmux-capability: {capability}\r\n");
    let rebinding = format!("rebind.example:{proxy}");

    // A DNS-rebound page sends its own name as Host. Even a request that
    // carries the capability (a cookie the browser would not send to
    // that name anyway) is refused on proxied and control paths.
    for path in ["/", "/plain", "/__chatmux__/status", "/__chatmux__/target.js"] {
        let response = raw_exchange(proxy, &get_request(path, &rebinding, &credential)).await;
        assert!(response.starts_with("HTTP/1.1 403"), "{path}: {response}");
    }
    for host in ["rebind.example", "localhost.rebind.example", "evil@localhost"] {
        let response = raw_exchange(proxy, &get_request("/", host, &credential)).await;
        assert!(response.starts_with("HTTP/1.1 403"), "{host}: {response}");
    }
    let response =
        raw_exchange(proxy, &format!("GET / HTTP/1.1\r\n{credential}Connection: close\r\n\r\n"))
            .await;
    assert!(!response.starts_with("HTTP/1.1 200"), "a request without Host: {response}");
    let response = raw_exchange(
        proxy,
        &format!(
            "GET / HTTP/1.1\r\nHost: localhost\r\nHost: rebind.example\r\n{credential}Connection: close\r\n\r\n"
        ),
    )
    .await;
    assert!(!response.starts_with("HTTP/1.1 200"), "two Host headers: {response}");

    // Rebinding on a WebSocket upgrade: the dev server's HMR socket and
    // both control sockets (an originless handshake included).
    let upgrade_target = spawn_upgrade_target().await;
    let (upgrade_proxy, upgrade_capability) =
        open_proxy_credentials(&registry, upgrade_target).await;
    let head = raw_response_head(
        upgrade_proxy,
        &upgrade_request(
            "/hmr",
            &format!("rebind.example:{upgrade_proxy}"),
            &format!("Cookie: __chatmux_preview_{upgrade_proxy}={upgrade_capability}\r\n"),
        ),
    )
    .await;
    assert!(head.starts_with("http/1.1 403"), "hmr upgrade: {head}");
    for path in ["/__chatmux__/page", "/__chatmux__/devtools"] {
        let outcome = ws_handshake(proxy, path, Some(&capability), &[("host", &rebinding)]).await;
        assert!(refused_with_forbidden(outcome), "{path} accepted a rebinding Host");
    }

    // Loopback names and address literals stay allowed.
    for host in [
        format!("localhost:{proxy}"),
        format!("app.localhost:{proxy}"),
        format!("127.0.0.1:{proxy}"),
        format!("[::1]:{proxy}"),
        "localhost.".to_owned(),
        format!("10.0.0.5:{proxy}"),
    ] {
        let response = raw_exchange(
            proxy,
            &get_request("/", &host, &format!("Cookie: {cookie}={capability}\r\n")),
        )
        .await;
        assert!(response.starts_with("HTTP/1.1 200"), "{host}: {response}");
    }
    registry.shutdown().await;
}

#[tokio::test]
async fn public_preview_hosts_pass_only_under_the_configured_suffixes() {
    let registry = PreviewRegistry::with_public_host_suffixes([".Preview.Test."]);
    let target = spawn_echo_target().await;
    let (proxy, capability) = open_proxy_credentials(&registry, target).await;
    let credential = format!("{CAPABILITY_HEADER}: {capability}\r\n");
    for host in ["p1.preview.test", "P1.Preview.Test:443", "preview.test", "p1.preview.test."] {
        let response = raw_exchange(proxy, &get_request("/", host, &credential)).await;
        assert!(response.starts_with("HTTP/1.1 200"), "{host}: {response}");
    }
    for host in ["xpreview.test", "p1.preview.test.evil.example", "preview.chatmux.dev"] {
        let response = raw_exchange(proxy, &get_request("/", host, &credential)).await;
        assert!(response.starts_with("HTTP/1.1 403"), "{host}: {response}");
    }
    // The tunnel bootstrap marks the cookie Secure (the tunnel is https).
    let response = raw_exchange(
        proxy,
        &get_request(&format!("/?{CAPABILITY_QUERY}={capability}"), "p1.preview.test", ""),
    )
    .await
    .to_ascii_lowercase();
    assert!(response.starts_with("http/1.1 302"), "{response}");
    assert!(response.contains("\r\nlocation: /\r\n"), "{response}");
    let set_cookie = response.lines().find(|line| line.starts_with("set-cookie:")).expect("cookie");
    assert!(set_cookie.contains("; secure"), "{set_cookie}");
    assert!(set_cookie.contains("samesite=lax"), "{set_cookie}");
    registry.shutdown().await;
    // A one-label suffix is ignored: it would admit a public TLD.
    let registry = PreviewRegistry::with_public_host_suffixes(["test"]);
    let (proxy, capability) = open_proxy_credentials(&registry, target).await;
    let response = raw_exchange(
        proxy,
        &get_request("/", "rebind.test", &format!("{CAPABILITY_HEADER}: {capability}\r\n")),
    )
    .await;
    assert!(response.starts_with("HTTP/1.1 403"), "{response}");
    registry.shutdown().await;
    // The default registry serves the chatmux tunnel's domain.
    let registry = PreviewRegistry::new();
    let (proxy, capability) = open_proxy_credentials(&registry, target).await;
    let response = raw_exchange(
        proxy,
        &get_request(
            "/",
            "abc.preview.chatmux.dev",
            &format!("{CAPABILITY_HEADER}: {capability}\r\n"),
        ),
    )
    .await;
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    registry.shutdown().await;
}

#[tokio::test]
async fn the_capability_never_lingers_in_the_url_or_reaches_the_dev_server() {
    let registry = PreviewRegistry::new();
    let target = spawn_echo_target().await;
    let (proxy, capability) = open_proxy_credentials(&registry, target).await;
    let host = format!("localhost:{proxy}");
    let cookie = format!("{CAPABILITY_COOKIE_PREFIX}{proxy}={capability}");
    let location = |response: &str| {
        response
            .to_ascii_lowercase()
            .lines()
            .find_map(|line| line.strip_prefix("location: ").map(str::to_owned))
            .unwrap_or_default()
    };

    // A second visit of the capability link (cookie already set) still
    // takes the 302, so the URL and later Referers drop it.
    let response = raw_exchange(
        proxy,
        &get_request(
            &format!("/?{CAPABILITY_QUERY}={capability}"),
            &host,
            &format!("Cookie: {cookie}\r\n"),
        ),
    )
    .await;
    assert!(response.starts_with("HTTP/1.1 302"), "{response}");

    // A percent-encoded name is the same parameter.
    let wrong = "0".repeat(capability.len());
    let response =
        raw_exchange(proxy, &get_request(&format!("/?%5F_chatmux_capability={wrong}"), &host, ""))
            .await;
    assert!(response.starts_with("HTTP/1.1 401"), "{response}");
    let response = raw_exchange(
        proxy,
        &get_request(&format!("/echo?%5F_chatmux_capability={capability}&a=1"), &host, ""),
    )
    .await;
    assert!(response.starts_with("HTTP/1.1 302"), "{response}");
    assert_eq!(location(&response), "/echo?a=1");

    // The bootstrap never redirects off the host.
    for path in ["//evil.example/x", "/\\evil.example/x", "///evil.example/x"] {
        let response = raw_exchange(
            proxy,
            &get_request(&format!("{path}?{CAPABILITY_QUERY}={capability}"), &host, ""),
        )
        .await;
        assert!(response.starts_with("HTTP/1.1 302"), "{path}: {response}");
        assert_eq!(location(&response), "/evil.example/x", "{path}");
    }

    // The dev server sees no preview cookie (sibling previews' cookies
    // included, since cookies are not port-scoped), keeps the app's
    // non-ASCII cookie, and gets a Referer without the capability.
    let response = raw_exchange(
        proxy,
        &get_request(
            "/echo",
            &host,
            &format!(
                "Cookie: {CAPABILITY_COOKIE_PREFIX}1=sibling; app=caf\u{e9}; {cookie}\r\nReferer: http://{host}/page?{CAPABILITY_QUERY}={capability}&b=2\r\n"
            ),
        ),
    )
    .await;
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");
    assert!(!response.contains(&capability), "{response}");
    assert!(!response.contains("sibling"), "{response}");
    assert!(response.contains("cookie=app=caf\u{e9}"), "{response}");
    assert!(response.contains(&format!("referer=http://{host}/page?b=2")), "{response}");
    registry.shutdown().await;
}

#[tokio::test]
async fn a_sibling_origin_cannot_write_or_open_a_socket_with_the_cookie() {
    let registry = PreviewRegistry::new();
    let target = spawn_echo_target().await;
    let (proxy, capability) = open_proxy_credentials(&registry, target).await;
    let host = format!("localhost:{proxy}");
    let cookie = format!("Cookie: {CAPABILITY_COOKIE_PREFIX}{proxy}={capability}\r\n");
    let post = |origin: &str| {
        format!(
            "POST /echo HTTP/1.1\r\nHost: {host}\r\nOrigin: {origin}\r\n{cookie}Content-Length: 0\r\nConnection: close\r\n\r\n"
        )
    };
    // Another localhost page is same-site, so its browser sends the
    // cookie; the proxy still refuses its writes.
    let response = raw_exchange(proxy, &post("http://localhost:1")).await;
    assert!(response.starts_with("HTTP/1.1 403"), "{response}");
    let response = raw_exchange(proxy, &post("null")).await;
    assert!(response.starts_with("HTTP/1.1 403"), "{response}");
    let response = raw_exchange(proxy, &post(&format!("http://{host}"))).await;
    assert!(response.starts_with("HTTP/1.1 200"), "{response}");

    let upgrade_target = spawn_upgrade_target().await;
    let (upgrade_proxy, upgrade_capability) =
        open_proxy_credentials(&registry, upgrade_target).await;
    let upgrade_host = format!("localhost:{upgrade_proxy}");
    let upgrade_cookie =
        format!("Cookie: {CAPABILITY_COOKIE_PREFIX}{upgrade_proxy}={upgrade_capability}\r\n");
    let head = raw_response_head(
        upgrade_proxy,
        &upgrade_request(
            "/hmr",
            &upgrade_host,
            &format!("{upgrade_cookie}Origin: http://localhost:1\r\n"),
        ),
    )
    .await;
    assert!(head.starts_with("http/1.1 403"), "sibling upgrade: {head}");
    let head = raw_response_head(
        upgrade_proxy,
        &upgrade_request(
            "/hmr",
            &upgrade_host,
            &format!("{upgrade_cookie}Origin: http://{upgrade_host}\r\n"),
        ),
    )
    .await;
    assert!(head.starts_with("http/1.1 101"), "same-origin upgrade: {head}");
    registry.shutdown().await;
}
