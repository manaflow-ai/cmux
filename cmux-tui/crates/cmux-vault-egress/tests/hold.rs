//! Hold and retry of model requests toward the hub, against a scripted fake hub.

mod common;

use std::collections::{HashMap, VecDeque};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use bytes::Bytes;
use cmux_vault_egress::{Authority, Config, Hold, HostPattern, Policy, Resolver, Secret, Timings};
use common::{pem_cert, roots, tunnel};
use http_body_util::{BodyExt, Full};
use hyper_util::rt::TokioIo;
use rcgen::{BasicConstraints, CertificateParams, CertifiedIssuer, IsCa, KeyPair, KeyUsagePurpose};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer, ServerName};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use zeroize::Zeroizing;

const KEY: &str = "hub-machine-credential-3d9e";
const BODY: &str =
    r#"{"model":"claude","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}"#;
const STREAM_BODY: &str = r#"{"model":"claude","stream":true,"messages":[]}"#;
const SSE: &str = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n";

/// What the fake hub does with one request.
#[derive(Clone)]
enum Step {
    Status(u16, Option<&'static str>, &'static str),
    Ok(&'static str),
    Sse,
    /// Read the request and close the connection: no answer.
    Reset,
}

/// What the fake hub received: (x-api-key, body) per request.
type Seen = Arc<Mutex<Vec<(String, String)>>>;

/// A TLS server for hub.test that answers per `script`, then 200 "ok" forever.
async fn hub(script: Vec<Step>) -> (SocketAddr, CertificateDer<'static>, Seen) {
    let mut ca = CertificateParams::new(Vec::<String>::new()).unwrap();
    ca.is_ca = IsCa::Ca(BasicConstraints::Unconstrained);
    ca.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::DigitalSignature];
    let issuer = CertifiedIssuer::self_signed(ca, KeyPair::generate().unwrap()).unwrap();
    let ca_der = pem_cert(&issuer.pem());
    let key = KeyPair::generate().unwrap();
    let cert = CertificateParams::new(vec!["hub.test".to_owned(), "other.test".to_owned()])
        .unwrap()
        .signed_by(&key, &issuer)
        .unwrap();
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::ring::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(
        vec![cert.der().clone()],
        PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key.serialize_der())),
    )
    .unwrap();
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let script = Arc::new(Mutex::new(VecDeque::from(script)));
    let seen: Seen = Arc::default();
    let seen_out = seen.clone();
    tokio::spawn(async move {
        loop {
            let Ok((tcp, _)) = listener.accept().await else { return };
            let (acceptor, script, seen) = (acceptor.clone(), script.clone(), seen.clone());
            tokio::spawn(async move {
                let Ok(mut tls) = acceptor.accept(tcp).await else { return };
                loop {
                    let mut head = Vec::new();
                    let mut byte = [0u8; 1];
                    while !head.ends_with(b"\r\n\r\n") {
                        if tls.read_exact(&mut byte).await.is_err() {
                            return;
                        }
                        head.push(byte[0]);
                    }
                    let head = String::from_utf8_lossy(&head).to_ascii_lowercase();
                    let header = |name: &str| {
                        head.lines()
                            .find_map(|l| l.strip_prefix(&format!("{name}: ")).map(str::to_owned))
                            .unwrap_or_default()
                    };
                    let length: usize = header("content-length").parse().unwrap_or(0);
                    let mut body = vec![0u8; length];
                    if tls.read_exact(&mut body).await.is_err() {
                        return;
                    }
                    seen.lock()
                        .unwrap()
                        .push((header("x-api-key"), String::from_utf8_lossy(&body).into_owned()));
                    let step = script.lock().unwrap().pop_front().unwrap_or(Step::Ok("ok"));
                    let (code, extra, ctype, text) = match step {
                        Step::Reset => return,
                        Step::Ok(text) => (200, None, "application/json", text),
                        Step::Sse => (200, None, "text/event-stream", SSE),
                        Step::Status(code, retry, text) => (code, retry, "application/json", text),
                    };
                    let mut out = format!(
                        "HTTP/1.1 {code} X\r\ncontent-type: {ctype}\r\ncontent-length: {}\r\n",
                        text.len()
                    );
                    if let Some(r) = extra {
                        out.push_str(&format!("retry-after: {r}\r\n"));
                    }
                    out.push_str("\r\n");
                    out.push_str(text);
                    if tls.write_all(out.as_bytes()).await.is_err() {
                        return;
                    }
                }
            });
        }
    });
    (addr, ca_der, seen_out)
}

fn quick() -> Timings {
    Timings {
        budget: Duration::from_secs(3),
        stream_cap: Duration::from_secs(3),
        client_slack: Duration::ZERO,
        step: Duration::from_millis(200),
        floor: Duration::from_millis(30),
        net_step: Duration::from_millis(30),
        commit: Duration::from_secs(60),
        ping: Duration::from_millis(20),
        max_body: 1 << 20,
        drain: Duration::from_secs(1),
    }
}

struct Proxy {
    addr: SocketAddr,
    authority: Arc<Authority>,
}

/// The proxy holding hub.test's requests; `up` is where hub.test and other.test resolve.
async fn proxy(up: SocketAddr, hub_ca: CertificateDer<'static>, timings: Timings) -> Proxy {
    let authority = Arc::new(Authority::generate().unwrap());
    let policy = Arc::new(Policy::new(vec![
        Secret::new(
            "HUB",
            Zeroizing::new(KEY.to_owned()),
            vec![HostPattern::parse("hub.test").unwrap()],
        ),
        Secret::new(
            "OTHER",
            Zeroizing::new("other".to_owned()),
            vec![HostPattern::parse("other.test").unwrap()],
        ),
    ]));
    let fixed: HashMap<(String, u16), SocketAddr> =
        ["hub.test", "other.test"].into_iter().map(|h| ((h.to_owned(), 443), up)).collect();
    let config = Arc::new(Config {
        policy: Arc::new(move || policy.clone()),
        authority: authority.clone(),
        upstream_tls: cmux_vault_egress::upstream_tls_with_roots(roots(hub_ca)).unwrap(),
        resolver: Resolver::Fixed(fixed),
        hold: Some(Hold { applies: Arc::new(|h, p| h == "hub.test" && p == 443), timings }),
    });
    let listener = cmux_vault_egress::bind().await.unwrap();
    let addr = listener.local_addr().unwrap();
    tokio::spawn(cmux_vault_egress::serve(listener, config));
    Proxy { addr, authority }
}

struct Answer {
    status: u16,
    headers: http::HeaderMap,
    body: String,
}

/// One request through the proxy as Claude Code sends it.
async fn send(p: &Proxy, host: &str, method: &str, body: &str) -> Answer {
    let stream = tunnel(p.addr, host).await.unwrap();
    let tls =
        cmux_vault_egress::upstream_tls_with_roots(roots(pem_cert(p.authority.pem()))).unwrap();
    let tls = tokio_rustls::TlsConnector::from(tls)
        .connect(ServerName::try_from(host.to_owned()).unwrap(), stream)
        .await
        .unwrap();
    let (mut sender, conn) =
        hyper::client::conn::http1::handshake(TokioIo::new(tls)).await.unwrap();
    tokio::spawn(conn);
    let secret = if host == "hub.test" { "HUB" } else { "OTHER" };
    let req = hyper::Request::builder()
        .method(method)
        .uri("/v1/messages")
        .header("host", host)
        .header("x-api-key", format!("cmux-secret://{secret}"))
        .header("x-stainless-timeout", "600")
        .header("content-length", body.len().to_string())
        .body(Full::new(Bytes::from(body.to_owned())))
        .unwrap();
    let response = sender.send_request(req).await.unwrap();
    let status = response.status().as_u16();
    let headers = response.headers().clone();
    let bytes = response.into_body().collect().await.unwrap().to_bytes();
    Answer { status, headers, body: String::from_utf8(bytes.to_vec()).unwrap() }
}

fn assert_same_request_each_try(seen: &Seen, tries: usize, body: &str) {
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), tries, "{seen:?}");
    for (key, sent) in seen.iter() {
        assert_eq!(key, KEY, "the credential goes out substituted on every try");
        assert_eq!(sent, body, "the body is replayed as it came");
    }
}

#[tokio::test]
async fn a_429_is_held_then_answered() {
    let rate = r#"{"type":"error","error":{"type":"rate_limit_error","message":"x"}}"#;
    let (up, ca, seen) = hub(vec![Step::Status(429, Some("0"), rate), Step::Ok("answer")]).await;
    let p = proxy(up, ca, quick()).await;
    let a = send(&p, "hub.test", "POST", BODY).await;
    assert_eq!((a.status, a.body.as_str()), (200, "answer"));
    assert_same_request_each_try(&seen, 2, BODY);
}

#[tokio::test]
async fn a_529_is_held_then_answered() {
    let over = r#"{"type":"error","error":{"type":"overloaded_error","message":"x"}}"#;
    let (up, ca, seen) =
        hub(vec![Step::Status(529, None, over), Step::Status(503, None, "no"), Step::Ok("answer")])
            .await;
    let p = proxy(up, ca, quick()).await;
    let a = send(&p, "hub.test", "POST", BODY).await;
    assert_eq!((a.status, a.body.as_str()), (200, "answer"));
    assert_same_request_each_try(&seen, 3, BODY);
}

#[tokio::test]
async fn a_reset_is_held_then_answered_on_a_new_connection() {
    let (up, ca, seen) = hub(vec![Step::Reset, Step::Ok("answer")]).await;
    let p = proxy(up, ca, quick()).await;
    let a = send(&p, "hub.test", "POST", BODY).await;
    assert_eq!((a.status, a.body.as_str()), (200, "answer"));
    assert_same_request_each_try(&seen, 2, BODY);
}

#[tokio::test]
async fn a_hold_that_runs_out_hands_up_the_last_answer() {
    let over = r#"{"type":"error","error":{"type":"overloaded_error","message":"busy"}}"#;
    let (up, ca, seen) = hub(vec![Step::Status(529, Some("0"), over); 1000]).await;
    let timings = Timings { budget: Duration::from_millis(400), ..quick() };
    let started = std::time::Instant::now();
    let p = proxy(up, ca, timings).await;
    let a = send(&p, "hub.test", "POST", BODY).await;
    assert_eq!((a.status, a.body.as_str()), (529, over));
    assert_eq!(a.headers.get("x-cmux-egress").unwrap(), "give-up");
    assert!(started.elapsed() < Duration::from_secs(2), "{:?}", started.elapsed());
    let tries = seen.lock().unwrap().len();
    assert!(tries >= 2, "held before giving up: {tries}");
    assert_same_request_each_try(&seen, tries, BODY);
}

#[tokio::test]
async fn an_unreachable_hub_is_held_then_given_up_as_overloaded() {
    // A port nothing listens on: the CONNECT is still accepted, each try fails to connect.
    let closed = TcpListener::bind("127.0.0.1:0").await.unwrap().local_addr().unwrap();
    let (_, ca, _) = hub(vec![]).await;
    let timings = Timings { budget: Duration::from_millis(300), ..quick() };
    let p = proxy(closed, ca, timings).await;
    let a = send(&p, "hub.test", "POST", BODY).await;
    assert_eq!(a.status, 529);
    assert_eq!(a.headers.get("retry-after").unwrap(), "5");
    assert!(a.body.contains("overloaded_error"), "{}", a.body);
}

#[tokio::test]
async fn a_long_held_stream_is_answered_and_pinged_then_gets_the_hub_stream() {
    let over = r#"{"type":"error","error":{"type":"overloaded_error","message":"x"}}"#;
    let (up, ca, seen) = hub(vec![
        Step::Status(529, Some("0.1"), over),
        Step::Status(529, Some("0.1"), over),
        Step::Sse,
    ])
    .await;
    let timings = Timings { commit: Duration::from_millis(50), ..quick() };
    let p = proxy(up, ca, timings).await;
    let a = send(&p, "hub.test", "POST", STREAM_BODY).await;
    assert_eq!(a.status, 200);
    assert_eq!(a.headers.get("content-type").unwrap(), "text/event-stream");
    assert!(a.body.contains("event: ping\n"), "{}", a.body);
    assert!(a.body.ends_with(SSE), "{}", a.body);
    assert_same_request_each_try(&seen, 3, STREAM_BODY);
}

#[tokio::test]
async fn a_committed_stream_whose_hold_runs_out_ends_with_an_sse_error() {
    let rate = r#"{"type":"error","error":{"type":"rate_limit_error","message":"x"}}"#;
    let (up, ca, _) = hub(vec![Step::Status(429, Some("0.1"), rate); 1000]).await;
    let timings = Timings {
        commit: Duration::from_millis(50),
        stream_cap: Duration::from_millis(500),
        ..quick()
    };
    let p = proxy(up, ca, timings).await;
    let a = send(&p, "hub.test", "POST", STREAM_BODY).await;
    assert_eq!(a.status, 200);
    assert!(a.body.ends_with("\n\n") && a.body.contains("event: error\n"), "{}", a.body);
    assert!(a.body.contains("rate_limit_error"), "{}", a.body);
}

#[tokio::test]
async fn other_hosts_and_methods_are_not_held() {
    let over = r#"{"type":"error","error":{"type":"overloaded_error","message":"x"}}"#;
    let (up, ca, seen) =
        hub(vec![Step::Status(529, None, over), Step::Status(529, None, over)]).await;
    let p = proxy(up, ca, quick()).await;
    assert_eq!(send(&p, "other.test", "POST", BODY).await.status, 529);
    assert_eq!(send(&p, "hub.test", "PUT", BODY).await.status, 529);
    assert_eq!(seen.lock().unwrap().len(), 2);
}
