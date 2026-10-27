use std::sync::mpsc;

use super::super::tests::captured_writer;
use super::*;

/// An answer and where it arrives.
fn answer() -> (Answer<bool>, mpsc::Receiver<bool>) {
    let (sender, receiver) = mpsc::channel();
    (
        Answer::new(
            move |opened| {
                let _ = sender.send(opened);
            },
            || false,
        ),
        receiver,
    )
}

/// `prepare` with a fresh answer.
fn prepare(
    broker: &URLRequests,
    terminal: &str,
    url: &str,
) -> (Option<String>, mpsc::Receiver<bool>) {
    let (reply, answered) = answer();
    (broker.prepare(terminal, url, reply), answered)
}

const TERMINAL: &str = "term_0123456789abcdef0123456789abcdef";

#[test]
fn url_open_has_no_headless_or_wrong_terminal_queue() {
    let broker = URLRequests::default();
    let (id, answered) = prepare(&broker, TERMINAL, "https://github.com/login/device");
    assert!(id.is_none());
    assert_eq!(answered.try_recv(), Ok(false), "a refused request answers at once");
    let (writer, _) = captured_writer();
    broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
    assert!(prepare(&broker, "term_other", "https://example.com").0.is_none());
}

#[test]
fn url_open_requires_claim_and_actual_delivery_ack() {
    let broker = URLRequests::default();
    let (writer, _) = captured_writer();
    broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
    let (id, answered) = prepare(&broker, TERMINAL, "https://example.com/?code=abc");
    let id = id.unwrap();
    assert!(!broker.complete(&id, true));
    assert!(broker.claim(&id));
    assert!(!broker.claim(&id));
    assert!(answered.try_recv().is_err(), "no answer before the acknowledgement");
    assert!(broker.complete(&id, true));
    assert_eq!(answered.try_recv(), Ok(true));
    assert!(!broker.claim(&id));
}

#[test]
fn url_open_does_not_guess_between_frontends() {
    let broker = URLRequests::default();
    let (first, _) = captured_writer();
    let (second, _) = captured_writer();
    broker.subscribe(1, vec![TERMINAL.into()], first).unwrap();
    broker.subscribe(2, vec![TERMINAL.into()], second).unwrap();
    assert!(prepare(&broker, TERMINAL, "https://example.com").0.is_none());
    broker.disconnect(2);
    assert!(prepare(&broker, TERMINAL, "https://example.com").0.is_some());
}

#[test]
fn url_open_disconnect_deadline_and_capacity_are_bounded() {
    let broker = URLRequests::default();
    let (writer, _) = captured_writer();
    broker.subscribe(1, vec![TERMINAL.into()], writer).unwrap();
    let mut requests = Vec::new();
    for _ in 0..CAPACITY {
        let (id, answered) = prepare(&broker, TERMINAL, "https://example.com");
        requests.push((id.unwrap(), answered));
    }
    assert!(prepare(&broker, TERMINAL, "https://example.com").0.is_none());
    broker.0.lock().recover_poison().pending.get_mut(&requests[0].0).unwrap().deadline =
        Instant::now();
    assert!(!broker.claim(&requests[0].0));
    // The deadline item cancels it: answered unopened.
    broker.cancel(&requests[0].0);
    assert_eq!(requests[0].1.try_recv(), Ok(false));
    broker.disconnect(1);
    for (_, answered) in &requests[1..] {
        assert_eq!(answered.try_recv(), Ok(false), "a disconnect answers every request");
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
