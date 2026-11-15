use super::*;

#[test]
fn a_sign_in_challenge_names_its_realm() {
    assert_eq!(realm("Basic realm=\"parity\", charset=\"UTF-8\""), "parity");
    assert_eq!(realm("Digest realm=intranet, qop=auth"), "intranet");
    assert_eq!(realm("Bearer"), "");
}

#[test]
fn a_request_reports_its_response_and_end() {
    let mut tab = TabState::new("S1".into(), String::new(), String::new(), None);
    let sent = json!({"requestId": "r1", "type": "Fetch",
            "request": {"url": "http://a.test/api/data", "method": "GET", "headers": {"accept": "*/*"}}});
    let request = event(&mut tab, "T1", "Network.requestWillBeSent", &sent).unwrap();
    assert_eq!(request.name, "request");
    assert_eq!(
        (
            &request.payload["method"],
            &request.payload["resourceType"],
            &request.payload["targetId"]
        ),
        (&json!("GET"), &json!("fetch"), &json!("T1"))
    );
    let response = event(
        &mut tab,
        "T1",
        "Network.responseReceived",
        &json!({"requestId": "r1", "response": {"status": 200, "headers": {}}}),
    )
    .unwrap();
    assert_eq!((response.name.as_str(), &response.payload["status"]), ("response", &json!(200)));
    assert_eq!(response.payload["url"], "http://a.test/api/data");
    let done =
        event(&mut tab, "T1", "Network.loadingFinished", &json!({"requestId": "r1"})).unwrap();
    assert_eq!(done.name, "requestfinished");
    assert!(tab.requests.is_empty() && tab.request_order.is_empty());
    assert!(
        event(&mut tab, "T1", "Network.loadingFailed", &json!({"requestId": "r1"})).is_none(),
        "an unknown request has no event"
    );
}

/// HOP-ADDRESS (ff, 2026-10-05): a manual redirect's address comes from
/// the next `requestWillBeSent`'s `redirectResponse` (Chromium sends one
/// even though the fetch does not follow), so the host's rebinding check
/// of the hop does not wait out its 1 s for a response event that never
/// comes (Testbox spike, Chromium 143).
#[test]
fn a_redirect_response_records_its_address() {
    let mut tab = TabState::new("S1".into(), String::new(), String::new(), None);
    let sent = json!({"requestId": "r1", "type": "Fetch",
            "request": {"url": "http://127.0.0.1:8000/final", "method": "GET"},
            "redirectResponse": {"url": "http://127.0.0.1:8000/redirect", "status": 302,
                "remoteIPAddress": "127.0.0.1"}});
    event(&mut tab, "T1", "Network.requestWillBeSent", &sent);
    assert!(
        tab.responses
            .iter()
            .any(|(url, ip)| url == "http://127.0.0.1:8000/redirect" && ip == "127.0.0.1"),
        "{:?}",
        tab.responses
    );
}

#[test]
fn open_requests_are_bounded() {
    let mut tab = TabState::new("S1".into(), String::new(), String::new(), None);
    for i in 0..(MAX_OPEN_REQUESTS + 5) {
        let sent = json!({"requestId": format!("r{i}"), "type": "XHR", "request": {"url": "http://a.test/", "method": "GET"}});
        event(&mut tab, "T1", "Network.requestWillBeSent", &sent);
    }
    assert_eq!(tab.requests.len(), MAX_OPEN_REQUESTS);
    assert!(!tab.requests.contains_key("r0"));
}
