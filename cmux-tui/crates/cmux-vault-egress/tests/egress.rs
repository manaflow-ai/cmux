//! End to end on loopback: a client goes through the proxy to a TLS
//! upstream that echoes the credentials it received.

mod common;

use std::sync::Arc;

use base64::Engine as _;
use cmux_vault_egress::{HostPattern, Policy, Secret};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use zeroize::Zeroizing;

use common::*;

#[tokio::test]
async fn a_placeholder_becomes_the_value_only_for_an_allowed_host() {
    let h = harness().await;
    let auth =
        [("authorization", "Bearer cmux-secret://TOKEN"), ("x-api-key", "cmux-secret://TOKEN")];

    let stream = tunnel(h.proxy, "allowed.test").await.unwrap();
    let (code, body) =
        get(stream, "allowed.test", proxy_roots(&h), "allowed.test", &auth).await.unwrap();
    assert_eq!(code, 200);
    assert_eq!(body, format!("Bearer {VALUE}\n{VALUE}"));

    // A host no secret allows is a blind tunnel: the client talks TLS with the
    // real server, which gets the placeholder.
    let stream = tunnel(h.proxy, "denied.test").await.unwrap();
    let (code, body) =
        get(stream, "denied.test", roots(h.upstream_ca.clone()), "denied.test", &auth)
            .await
            .unwrap();
    assert_eq!(code, 200);
    assert_eq!(body, "Bearer cmux-secret://TOKEN\ncmux-secret://TOKEN");
    // ...and the proxy's CA is not used there (no interception at all).
    let stream = tunnel(h.proxy, "denied.test").await.unwrap();
    assert!(get(stream, "denied.test", proxy_roots(&h), "denied.test", &auth).await.is_err());

    // A host another secret allows is intercepted, but TOKEN stays a placeholder there.
    let stream = tunnel(h.proxy, "other.test").await.unwrap();
    let (code, body) = get(
        stream,
        "other.test",
        proxy_roots(&h),
        "other.test",
        &[("authorization", "Bearer cmux-secret://TOKEN"), ("x-api-key", "cmux-secret://OTHER")],
    )
    .await
    .unwrap();
    assert_eq!(code, 200);
    assert_eq!(body, format!("Bearer cmux-secret://TOKEN\n{OTHER_VALUE}"));
}

#[tokio::test]
async fn basic_credentials_are_substituted_for_git() {
    let h = harness().await;
    let engine = base64::engine::general_purpose::STANDARD;
    let basic = format!("Basic {}", engine.encode("x-access-token:cmux-secret://TOKEN"));
    let stream = tunnel(h.proxy, "allowed.test").await.unwrap();
    let (_, body) =
        get(stream, "allowed.test", proxy_roots(&h), "allowed.test", &[("authorization", &basic)])
            .await
            .unwrap();
    let expected = format!("Basic {}", engine.encode(format!("x-access-token:{VALUE}")));
    assert_eq!(body.lines().next().unwrap(), expected);
}

#[tokio::test]
async fn a_request_for_another_host_on_an_allowed_connection_is_refused() {
    let h = harness().await;
    let stream = tunnel(h.proxy, "allowed.test").await.unwrap();
    let (code, body) = get(
        stream,
        "allowed.test",
        proxy_roots(&h),
        "denied.test",
        &[("authorization", "Bearer cmux-secret://TOKEN")],
    )
    .await
    .unwrap();
    assert_eq!(code, 421);
    assert!(!body.contains(VALUE));

    // A matching Host with a second one behind it is refused too: a front
    // end could route by the second.
    let stream = tunnel(h.proxy, "allowed.test").await.unwrap();
    let (code, body) = get(
        stream,
        "allowed.test",
        proxy_roots(&h),
        "allowed.test",
        &[("host", "denied.test"), ("authorization", "Bearer cmux-secret://TOKEN")],
    )
    .await
    .unwrap();
    assert_eq!(code, 421);
    assert!(!body.contains(VALUE));
}

#[tokio::test]
async fn a_revoked_secret_stops_on_the_next_request() {
    let h = harness().await;
    let auth = [("authorization", "Bearer cmux-secret://TOKEN")];
    let stream = tunnel(h.proxy, "allowed.test").await.unwrap();
    let (_, body) =
        get(stream, "allowed.test", proxy_roots(&h), "allowed.test", &auth).await.unwrap();
    assert!(body.starts_with(&format!("Bearer {VALUE}")));
    *h.policy.lock().unwrap() = Arc::new(Policy::new(vec![Secret::new(
        "OTHER",
        Zeroizing::new(OTHER_VALUE.to_owned()),
        vec![HostPattern::parse("allowed.test").unwrap()],
    )]));
    let stream = tunnel(h.proxy, "allowed.test").await.unwrap();
    let (_, body) =
        get(stream, "allowed.test", proxy_roots(&h), "allowed.test", &auth).await.unwrap();
    assert!(body.starts_with("Bearer cmux-secret://TOKEN"), "{body}");
}

#[tokio::test]
async fn plain_http_and_bad_targets_are_refused() {
    let h = harness().await;
    let mut stream = TcpStream::connect(h.proxy).await.unwrap();
    stream
        .write_all(b"GET http://allowed.test/ HTTP/1.1\r\nHost: allowed.test\r\n\r\n")
        .await
        .unwrap();
    let mut buf = [0u8; 12];
    stream.read_exact(&mut buf).await.unwrap();
    assert_eq!(&buf, b"HTTP/1.1 405");
    assert!(tunnel(h.proxy, "unknown.test").await.unwrap_err().starts_with("HTTP/1.1 502"));
}
