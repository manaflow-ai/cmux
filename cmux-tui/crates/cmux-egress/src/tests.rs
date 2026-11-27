use super::*;

#[test]
fn the_audit_keeps_allowed_and_refused_connections() {
    set_mode(Mode::Enforce);
    assert!(check("https://cloud-api.cmux.dev/v1", "cmux_egress::tests::audit").is_ok());
    assert!(check("audit-gate-test.org", "cmux_egress::tests::audit").is_err());
    assert!(check("cloud-api.cmux.dev", "cmux_egress::tests::audit").is_ok());
    let mine: Vec<AuditEntry> =
        audit().into_iter().filter(|e| e.site == "cmux_egress::tests::audit").collect();
    assert_eq!(
        mine,
        vec![
            AuditEntry {
                host: "audit-gate-test.org".into(),
                site: "cmux_egress::tests::audit",
                verdict: Verdict::Unlisted,
                refused: true,
            },
            AuditEntry {
                host: "cloud-api.cmux.dev".into(),
                site: "cmux_egress::tests::audit",
                verdict: Verdict::Listed,
                refused: false,
            },
        ]
    );
}

#[test]
fn an_audit_line_is_one_json_object() {
    let entry = AuditEntry {
        host: "a\"b".into(),
        site: "s",
        verdict: Verdict::Unlisted,
        refused: true,
    };
    assert_eq!(
        audit_line(&entry, Mode::Enforce, 7),
        "{\"ts\":7,\"host\":\"a\\\"b\",\"site\":\"s\",\"verdict\":\"unlisted\",\"mode\":\"enforce\",\"refused\":true}\n"
    );
}

#[test]
fn listed_hosts_and_patterns_pass() {
    assert_eq!(verdict("cloud-api.cmux.dev"), Verdict::Listed);
    assert_eq!(verdict("https://Cloud-API.cmux.dev:443/v1/x?y"), Verdict::Listed);
    assert_eq!(verdict("acme.atlassian.net"), Verdict::Listed);
    assert_eq!(verdict("atlassian.net"), Verdict::Unlisted);
    assert_eq!(verdict("a.b.atlassian.net"), Verdict::Unlisted);
    assert_eq!(verdict("cmux-api-preview-42.debussy.workers.dev"), Verdict::Listed);
    assert_eq!(verdict("other-42.debussy.workers.dev"), Verdict::Unlisted);
    assert_eq!(verdict("ts.net.evil-gate-test.org"), Verdict::Unlisted);
}

#[test]
fn local_and_reserved_pass() {
    for host in [
        "127.0.0.1",
        "http://[::1]:8080/",
        "localhost",
        "app.localhost",
        "x.test",
        "example.com",
        "mac-mini",
        "http://devbox:3000/",
        "mac.tail1234.ts.net",
        "git.corp.internal",
        "nas.lan",
    ] {
        assert_eq!(verdict(host), Verdict::Local, "{host}");
    }
}

#[test]
fn named_hosts_pass_and_the_rest_are_refused() {
    set_mode(Mode::Enforce);
    assert_eq!(verdict("git.self-hosted-gate-test.org"), Verdict::Unlisted);
    let refused = check("https://evil-gate-test.org/x", "cmux_egress::tests").unwrap_err();
    assert_eq!(refused.host, "evil-gate-test.org");
    assert!(unlisted().contains(&("evil-gate-test.org".to_owned(), "cmux_egress::tests")));
    allow_named("https://user@git.self-hosted-gate-test.org:8443/repo");
    assert_eq!(verdict("git.self-hosted-gate-test.org"), Verdict::Named);
    set_mode(Mode::Log);
    assert!(check("evil-gate-test.org", "cmux_egress::tests").is_ok());
    set_mode(Mode::Enforce);
}

#[test]
fn star_matches_within_one_label() {
    assert!(label_matches("cmux-api-preview-*", "cmux-api-preview-7"));
    assert!(!label_matches("cmux-api-preview-*", "cmux-api-preview-"));
    assert!(label_matches("*", "anything"));
    assert!(!label_matches("*", ""));
    assert!(label_matches("a*b*c", "a-x-b-y-c"));
    assert!(!label_matches("a*b*c", "a-x-c"));
}

#[tokio::test]
async fn a_gated_client_refuses_before_resolving() {
    set_mode(Mode::Enforce);
    let client = client_builder("cmux_egress::tests").build().unwrap();
    let err = client.get("https://refused-gate-test.org/").send().await.unwrap_err();
    let mut source: Option<&(dyn Error + 'static)> = Some(&err);
    let mut found = false;
    while let Some(e) = source {
        found |= e.downcast_ref::<Refused>().is_some();
        source = e.source();
    }
    assert!(found, "{err:?}");
}

#[tokio::test]
async fn a_wrapped_resolver_is_asked_only_for_passing_hosts() {
    use std::sync::atomic::AtomicUsize;
    #[derive(Clone)]
    struct Counting(Arc<AtomicUsize>);
    impl Resolve for Counting {
        fn resolve(&self, _: Name) -> Resolving {
            self.0.fetch_add(1, Ordering::SeqCst);
            Box::pin(async { Ok(Box::new(Vec::new().into_iter()) as Addrs) })
        }
    }
    set_mode(Mode::Enforce);
    let asked = Arc::new(AtomicUsize::new(0));
    let client =
        client_builder_with("cmux_egress::tests", Counting(asked.clone())).build().unwrap();
    assert!(client.get("https://refused-wrap-test.org/").send().await.is_err());
    assert_eq!(asked.load(Ordering::SeqCst), 0);
    let _ = client.get("https://cloud-api.cmux.dev/").send().await;
    assert_eq!(asked.load(Ordering::SeqCst), 1);
}

fn test_env(pairs: &[(&str, &str)]) -> Env {
    let pairs: Vec<(String, String)> =
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    Arc::new(move |name| pairs.iter().find(|(k, _)| k == name).map(|(_, v)| v.clone()))
}

#[test]
fn the_proxy_is_picked_only_for_passing_hosts() {
    set_mode(Mode::Enforce);
    let env = test_env(&[
        ("HTTPS_PROXY", "http://proxy.corp-gate-test.org:3128"),
        ("http_proxy", "proxy.corp-gate-test.org:8080"),
        ("NO_PROXY", "localhost, .cmux.dev ,example.com"),
    ]);
    let site = "cmux_egress::tests";
    let url = |u: &str| reqwest::Url::parse(u).unwrap();
    let refused = gated_proxy(&url("https://refused-proxy-test.org/x"), site, &env).unwrap();
    assert_eq!(refused.host_str(), Some(REFUSED_PROXY_HOST));
    let picked = gated_proxy(&url("https://api.github.com/x"), site, &env).unwrap();
    assert_eq!(picked.as_str(), "http://proxy.corp-gate-test.org:3128/");
    let picked = gated_proxy(&url("http://api.github.com/x"), site, &env).unwrap();
    assert_eq!(picked.port(), Some(8080));
    assert_eq!(gated_proxy(&url("https://cloud-api.cmux.dev/"), site, &env), None);
    assert_eq!(gated_proxy(&url("http://example.com/"), site, &env), None);
    assert_eq!(gated_proxy(&url("https://api.github.com/"), site, &test_env(&[])), None);
    // NO_PROXY never sends a refused host direct.
    let star = test_env(&[("NO_PROXY", "*"), ("ALL_PROXY", "socks5://127.0.0.1:1080")]);
    let refused = gated_proxy(&url("https://refused-proxy-test.org/"), site, &star).unwrap();
    assert_eq!(refused.host_str(), Some(REFUSED_PROXY_HOST));
}

#[tokio::test]
async fn a_proxied_client_never_sends_a_refused_request_to_the_proxy() {
    use std::sync::atomic::AtomicUsize;
    set_mode(Mode::Enforce);
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let proxy = format!("http://{}", listener.local_addr().unwrap());
    let accepted = Arc::new(AtomicUsize::new(0));
    let counter = accepted.clone();
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            counter.fetch_add(1, Ordering::SeqCst);
            drop(stream);
        }
    });
    let site = "cmux_egress::tests";
    let env = test_env(&[("HTTPS_PROXY", &proxy)]);
    // A proxy the caller adds after the gate's must not see the refused host either.
    let client = reqwest::Client::builder()
        .dns_resolver(Arc::new(Gate::new(site)))
        .proxy(gated_proxy_matcher(site, env.clone()))
        .proxy(reqwest::Proxy::all(&proxy).unwrap())
        .build()
        .unwrap();
    let err = client.get("https://refused-proxied-test.org/").send().await.unwrap_err();
    let mut source: Option<&(dyn Error + 'static)> = Some(&err);
    let mut found = false;
    while let Some(e) = source {
        found |= e.downcast_ref::<Refused>().is_some();
        source = e.source();
    }
    assert!(found, "{err:?}");
    assert_eq!(accepted.load(Ordering::SeqCst), 0);
    // A listed host does go to the proxy (which hangs up).
    let _ = client.get("https://api.github.com/").send().await;
    assert!(accepted.load(Ordering::SeqCst) >= 1);
}

#[test]
fn a_session_host_passes_only_while_its_guard_lives() {
    let presigned = "https://bucket.minio.session-gate-test.org/obj?X-Amz-Signature=s";
    assert_eq!(verdict(presigned), Verdict::Unlisted);
    let guard = allow_session(presigned, "https://cloud-api.cmux.dev");
    assert!(guard.granted());
    let again = allow_session("bucket.minio.session-gate-test.org", "cloud-api.cmux.dev");
    assert_eq!(verdict(presigned), Verdict::Session);
    drop(guard);
    assert_eq!(verdict(presigned), Verdict::Session);
    drop(again);
    assert_eq!(verdict(presigned), Verdict::Unlisted);
    // An answer from a host the gate refuses grants nothing.
    let forged = allow_session(presigned, "https://evil-session-test.org");
    assert!(!forged.granted());
    assert_eq!(verdict(presigned), Verdict::Unlisted);
}

#[tokio::test]
async fn a_websocket_to_an_unlisted_host_is_refused_before_connecting() {
    set_mode(Mode::Enforce);
    let err = ws::connect_async("wss://refused-ws-test.org/socket", "cmux_egress::tests")
        .await
        .unwrap_err();
    let text = err.to_string();
    assert!(text.contains("refused-ws-test.org"), "{text}");
    assert!(ws::checked("ws://127.0.0.1:9/x", "cmux_egress::tests").is_ok());
}
