use super::*;

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
