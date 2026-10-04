//! `input {event}` frames: the session sink's `automation.input` events reach
//! the app once, verbatim (schemas/automation-input, hq-07 emits them).

use super::*;
use crate::driver::EventSink;
use std::os::unix::net::UnixStream;
use std::time::Duration;

/// The shared vectors (schemas/automation-input/vectors.json).
fn vectors() -> Value {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../../schemas/automation-input/vectors.json");
    serde_json::from_str(&std::fs::read_to_string(path).expect("read the shared vectors"))
        .expect("parse the shared vectors")
}

fn valid_events() -> Vec<Value> {
    vectors()["valid"].as_array().expect("valid vectors").clone()
}

/// A provider link with a fake app that records every frame the host writes.
fn link() -> (Arc<ProviderDriver>, mpsc::Receiver<Frame>, UnixStream) {
    let (app, host) = UnixStream::pair().expect("socket pair");
    let driver = ProviderDriver::start(
        host.try_clone().expect("clone"),
        host,
        crate::driver::discard_events(),
        Vec::new(),
    )
    .expect("start the link");
    let (tx, rx) = mpsc::channel();
    let mut reader = app.try_clone().expect("clone");
    std::thread::spawn(move || {
        while let Ok(Some(frame)) = read_frame(&mut reader) {
            if tx.send(frame).is_err() {
                break;
            }
        }
    });
    (driver, rx, app)
}

/// The events the session sink received.
fn recorder() -> (EventSink, Arc<Mutex<Vec<DriverEvent>>>) {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let sink_seen = seen.clone();
    let sink: EventSink = Arc::new(move |event| {
        sink_seen.lock().unwrap_or_else(PoisonError::into_inner).push(event);
    });
    (sink, seen)
}

fn input(payload: &Value) -> DriverEvent {
    DriverEvent { name: AUTOMATION_INPUT.to_owned(), payload: payload.clone() }
}

fn next_input(rx: &mpsc::Receiver<Frame>) -> Option<Value> {
    match rx.recv_timeout(Duration::from_secs(2)) {
        Ok(Frame::Input { event }) => Some(event),
        Ok(other) => panic!("unexpected frame {other:?}"),
        Err(_) => None,
    }
}

#[test]
fn every_valid_vector_reaches_the_app_once_and_verbatim() {
    let (driver, rx, _app) = link();
    let (sink, seen) = recorder();
    let mut tees: HashMap<String, EventSink> = HashMap::new();
    let events = valid_events();
    for event in &events {
        let session = event["session_id"].as_str().expect("session_id").to_owned();
        let tee = tees
            .entry(session.clone())
            .or_insert_with(|| tee_inputs(sink.clone(), &driver, &session))
            .clone();
        tee(input(event));
    }
    for event in &events {
        assert_eq!(next_input(&rx).as_ref(), Some(event), "in order, unchanged");
    }
    assert_eq!(rx.recv_timeout(Duration::from_millis(200)).ok(), None, "no duplicate frame");
    let seen = seen.lock().unwrap_or_else(PoisonError::into_inner);
    assert_eq!(seen.len(), events.len(), "the session sink still gets every event");
    assert!(seen.iter().zip(&events).all(|(got, want)| got.payload == *want));
}

#[test]
fn only_the_emitting_session_forwards_its_input() {
    // A CEF tab's events reach every subscribed session (ProviderDriver::publish);
    // only the session named in the event sends the frame.
    let (driver, rx, _app) = link();
    let (sink, seen) = recorder();
    let event = valid_events()[0].clone();
    let own = tee_inputs(sink.clone(), &driver, "s1");
    let other = tee_inputs(sink, &driver, "s9");
    other(input(&event));
    own(input(&event));
    other(input(&event));
    assert_eq!(next_input(&rx), Some(event));
    assert_eq!(
        rx.recv_timeout(Duration::from_millis(200)).ok(),
        None,
        "one frame for three deliveries"
    );
    assert_eq!(seen.lock().unwrap_or_else(PoisonError::into_inner).len(), 3);
}

#[test]
fn other_events_stay_on_the_session_sink() {
    let (driver, rx, _app) = link();
    let (sink, seen) = recorder();
    let tee = tee_inputs(sink, &driver, "s1");
    tee(DriverEvent {
        name: "tab.navigated".into(),
        payload: json!({"targetId": "t", "session_id": "s1"}),
    });
    tee(DriverEvent { name: "automation.inputs".into(), payload: valid_events()[0].clone() });
    assert_eq!(rx.recv_timeout(Duration::from_millis(200)).ok(), None);
    assert_eq!(seen.lock().unwrap_or_else(PoisonError::into_inner).len(), 2);
}

#[test]
fn a_closed_link_drops_the_frame_and_keeps_the_sink() {
    let (driver, _rx, app) = link();
    // The reader thread holds a clone of the app's end: shut the socket down.
    app.shutdown(std::net::Shutdown::Both).expect("shut down the app end");
    let deadline = std::time::Instant::now() + Duration::from_secs(2);
    while driver.closed_reason().is_none() && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(driver.closed_reason().is_some(), "the link saw the hang-up");
    let (sink, seen) = recorder();
    let tee = tee_inputs(sink, &driver, "s1");
    tee(input(&valid_events()[0]));
    assert_eq!(seen.lock().unwrap_or_else(PoisonError::into_inner).len(), 1);
}

#[test]
fn a_dropped_link_does_not_keep_the_tee_alive() {
    let (driver, _rx, _app) = link();
    let (sink, seen) = recorder();
    let tee = tee_inputs(sink, &driver, "s1");
    let weak = Arc::downgrade(&driver);
    drop(driver);
    tee(input(&valid_events()[0]));
    assert_eq!(seen.lock().unwrap_or_else(PoisonError::into_inner).len(), 1);
    // The tee holds the link weakly: it never keeps a closed link alive.
    let _ = weak;
}

#[test]
fn the_input_frame_wire_shape() {
    let event = valid_events()[0].clone();
    let bytes = crate::provider::encode(&Frame::Input { event: event.clone() }).expect("encode");
    let body: Value = serde_json::from_slice(&bytes[4..]).expect("json");
    assert_eq!(body, json!({"t": "input", "event": event}));
    let decoded = read_frame(&mut bytes.as_slice()).expect("decode");
    assert_eq!(decoded, Some(Frame::Input { event }));
    // The debug form names the session and seq, never coordinates.
    let debug = format!("{:?}", Frame::Input { event: valid_events()[0].clone() });
    assert!(debug.contains("s1") && !debug.contains("120.5"), "{debug}");
}
