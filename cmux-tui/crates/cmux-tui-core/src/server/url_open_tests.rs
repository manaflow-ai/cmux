use super::super::tests::captured_writer;
use super::*;

const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";

#[test]
fn url_open_has_no_headless_or_wrong_terminal_queue() {
    let broker = URLRequests::default();
    assert!(broker.prepare(TERMINAL, "https://github.com/login/device").is_none());
    let (writer, _) = captured_writer();
    broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
    assert!(broker.prepare("term_other", "https://example.com").is_none());
}

#[test]
fn url_open_requires_claim_and_actual_delivery_ack() {
    let broker = URLRequests::default();
    let (writer, _) = captured_writer();
    broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
    let (id, receiver) = broker.prepare(TERMINAL, "https://example.com/?code=abc").unwrap();
    assert!(!broker.complete(&id, true));
    assert!(broker.claim(&id));
    assert!(!broker.claim(&id));
    assert!(broker.complete(&id, true));
    assert!(receiver.recv().unwrap());
    assert!(!broker.claim(&id));
}

#[test]
fn url_open_does_not_guess_between_frontends() {
    let broker = URLRequests::default();
    let (first, _) = captured_writer();
    let (second, _) = captured_writer();
    broker.subscribe(1, vec![TERMINAL.into()], first).unwrap();
    broker.subscribe(2, vec![TERMINAL.into()], second).unwrap();
    assert!(broker.prepare(TERMINAL, "https://example.com").is_none());
    broker.disconnect(2);
    assert!(broker.prepare(TERMINAL, "https://example.com").is_some());
}

#[test]
fn url_open_disconnect_deadline_and_capacity_are_bounded() {
    let broker = URLRequests::default();
    let (writer, _) = captured_writer();
    broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
    let mut requests = Vec::new();
    for _ in 0..CAPACITY {
        requests.push(broker.prepare(TERMINAL, "https://example.com").unwrap());
    }
    assert!(broker.prepare(TERMINAL, "https://example.com").is_none());
    broker.0.lock().recover_poison().pending.get_mut(&requests[0].0).unwrap().deadline =
        Instant::now();
    assert!(!broker.claim(&requests[0].0));
    broker.disconnect(1);
    for (_, receiver) in requests {
        assert!(receiver.recv().is_err());
    }
    assert!(broker.0.lock().recover_poison().pending.is_empty());
}

#[test]
fn url_open_validates_without_rewriting_auth_url_bytes() {
    assert!(validate_url("HTTPS://github.com/login/device?state=AbC%2F%2b#fragment"));
    for url in [
        "file:///tmp/file",
        "javascript:alert(1)",
        "https://",
        "https://foo/\ncommand",
        "https://foo/a b",
    ] {
        assert!(!validate_url(url));
    }
    assert!(!validate_url(&format!("https://example.com/{}", "a".repeat(16_384))));
}
