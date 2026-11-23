use super::*;
use std::thread;

#[derive(Default)]
struct RecordingWire {
    sent: Mutex<Vec<Value>>,
}

impl CdpWire for Arc<RecordingWire> {
    fn send(&self, message: &str) -> io::Result<()> {
        self.sent.lock().unwrap().push(serde_json::from_str(message).unwrap());
        Ok(())
    }
}

#[test]
fn a_provider_relay_connection_maps_its_page_alias_to_no_session() {
    let wire = Arc::new(RecordingWire::default());
    let conn = CdpConnection::page_rooted(Box::new(wire.clone()), "root");
    let events = Arc::new(Mutex::new(Vec::new()));
    let seen = events.clone();
    conn.set_event_handler(Arc::new(move |event| seen.lock().unwrap().push(event)));
    let caller = conn.clone();
    let call = thread::spawn(move || {
        caller.call(Some("root"), "Page.enable", json!({}), Duration::from_secs(5))
    });
    let child = conn.clone();
    let child_call = thread::spawn(move || {
        child.call(Some("frame-1"), "Runtime.enable", json!({}), Duration::from_secs(5))
    });
    while wire.sent.lock().unwrap().len() < 2 {
        thread::yield_now();
    }
    let sent = wire.sent.lock().unwrap().clone();
    let page = sent.iter().find(|m| m["method"] == "Page.enable").unwrap();
    assert!(page.get("sessionId").is_none(), "{page}");
    let frame = sent.iter().find(|m| m["method"] == "Runtime.enable").unwrap();
    assert_eq!(frame["sessionId"], "frame-1");
    for message in &sent {
        let id = &message["id"];
        conn.receive(&json!({"id": id, "result": {}}).to_string());
    }
    call.join().unwrap().unwrap();
    child_call.join().unwrap().unwrap();
    // Page events come back under the alias; child events keep theirs.
    conn.receive(&json!({"method": "Page.loadEventFired", "params": {}}).to_string());
    conn.receive(
        &json!({"method": "Runtime.executionContextCreated", "sessionId": "frame-1", "params": {}})
            .to_string(),
    );
    let events = events.lock().unwrap();
    assert_eq!(events[0].session_id.as_deref(), Some("root"));
    assert_eq!(events[1].session_id.as_deref(), Some("frame-1"));
    // No browser target behind a relayed tab: browser-level calls fail at once.
    let error =
        conn.call(None, "Target.getTargets", json!({}), Duration::from_secs(5)).unwrap_err();
    assert_eq!(error.code, ErrorCode::Unsupported, "{error}");
    assert_eq!(wire.sent.lock().unwrap().len(), 2, "nothing was sent for it");
}

fn connection() -> (Arc<CdpConnection>, Arc<RecordingWire>) {
    let wire = Arc::new(RecordingWire::default());
    (CdpConnection::new(Box::new(wire.clone())), wire)
}

fn wait_for_sent(wire: &RecordingWire, count: usize) -> Vec<Value> {
    for _ in 0..2000 {
        let sent = wire.sent.lock().unwrap().clone();
        if sent.len() >= count {
            return sent;
        }
        thread::yield_now();
        thread::sleep(Duration::from_millis(1));
    }
    panic!("expected {count} sent messages");
}

#[test]
fn replies_match_calls_by_id_and_carry_session() {
    let (conn, wire) = connection();
    let caller = {
        let conn = conn.clone();
        thread::spawn(move || {
            conn.call(
                Some("S1"),
                "Page.navigate",
                json!({"url": "about:blank"}),
                Duration::from_secs(5),
            )
        })
    };
    let sent = wait_for_sent(&wire, 1);
    assert_eq!(sent[0]["method"], "Page.navigate");
    assert_eq!(sent[0]["sessionId"], "S1");
    let id = sent[0]["id"].as_u64().unwrap();
    conn.receive(&json!({"id": id + 100, "result": {"wrong": true}}).to_string());
    conn.receive(&json!({"id": id, "result": {"frameId": "F"}}).to_string());
    assert_eq!(caller.join().unwrap().unwrap(), json!({"frameId": "F"}));
}

#[test]
fn protocol_errors_map_to_driver_codes() {
    let (conn, wire) = connection();
    let caller = {
        let conn = conn.clone();
        thread::spawn(move || conn.call(None, "DOM.resolveNode", json!({}), Duration::from_secs(5)))
    };
    let id = wait_for_sent(&wire, 1)[0]["id"].as_u64().unwrap();
    conn.receive(
        &json!({"id": id, "error": {"code": -32000, "message": "No node with given id found"}})
            .to_string(),
    );
    assert_eq!(caller.join().unwrap().unwrap_err().code, ErrorCode::Stale);
    assert_eq!(protocol_error(&json!({"message": "Target closed"})).code, ErrorCode::Closed);
    assert_eq!(
        protocol_error(&json!({"message": "Cannot find context with specified id"})).code,
        ErrorCode::NotFound
    );
    assert_eq!(
        protocol_error(&json!({"message": "Invalid parameters", "data": "x"})).message,
        "Invalid parameters: x"
    );
}

#[test]
fn events_reach_the_handler_with_their_session() {
    let (conn, _wire) = connection();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let sink = seen.clone();
    conn.set_event_handler(Arc::new(move |event| sink.lock().unwrap().push(event)));
    conn.receive(
        &json!({"method": "Page.loadEventFired", "params": {"timestamp": 1}, "sessionId": "S"})
            .to_string(),
    );
    conn.receive("not json");
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].method, "Page.loadEventFired");
    assert_eq!(seen[0].session_id.as_deref(), Some("S"));
}

#[test]
fn close_fails_pending_and_later_calls() {
    let (conn, wire) = connection();
    let caller = {
        let conn = conn.clone();
        thread::spawn(move || {
            conn.call(None, "Browser.getVersion", json!({}), Duration::from_secs(5))
        })
    };
    wait_for_sent(&wire, 1);
    conn.close("browser exited");
    let error = caller.join().unwrap().unwrap_err();
    assert_eq!(error.code, ErrorCode::Closed);
    assert_eq!(error.message, "browser exited");
    let later =
        conn.call(None, "Browser.getVersion", json!({}), Duration::from_secs(5)).unwrap_err();
    assert_eq!(later.code, ErrorCode::Closed);
}

/// A detached session never answers: its pending calls fail at once
/// (Closed), not at their deadline; other sessions' calls stay pending.
#[test]
fn a_detached_session_fails_its_pending_calls_at_once() {
    let (conn, wire) = connection();
    let call_on = |session: &'static str| {
        let conn = conn.clone();
        thread::spawn(move || {
            let started = std::time::Instant::now();
            let result =
                conn.call(Some(session), "Runtime.evaluate", json!({}), Duration::from_secs(20));
            (result, started.elapsed())
        })
    };
    let detached = call_on("S1");
    wait_for_sent(&wire, 1);
    let other = call_on("S2");
    let sent = wait_for_sent(&wire, 2);
    conn.receive(
        &json!({"method": "Target.detachedFromTarget", "params": {"sessionId": "S1"}}).to_string(),
    );
    let (result, took) = detached.join().unwrap();
    let error = result.unwrap_err();
    assert_eq!(error.code, ErrorCode::Closed, "{error}");
    assert!(took < Duration::from_secs(10), "it waited for its deadline: {took:?}");
    let other_id = sent.iter().find(|m| m["sessionId"] == "S2").unwrap()["id"].clone();
    assert_eq!(conn.pending.lock().unwrap().len(), 1, "the other session's call is pending");
    conn.receive(&json!({"id": other_id, "result": {"ok": true}}).to_string());
    assert_eq!(other.join().unwrap().0.unwrap(), json!({"ok": true}));
}

#[test]
fn calls_time_out_and_forget_the_waiter() {
    let (conn, _wire) = connection();
    let error = conn.call(None, "Page.enable", json!({}), Duration::from_millis(10)).unwrap_err();
    assert_eq!(error.code, ErrorCode::Timeout);
    assert!(conn.pending.lock().unwrap().is_empty());
}
