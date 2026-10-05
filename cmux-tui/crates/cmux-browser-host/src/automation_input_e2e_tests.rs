//! End to end on a provider (cef) session: one gate `driver_call` gives the
//! app exactly one `input` frame through `tee_inputs` (worker 5c's
//! consumer), and the session sink the same event once.

use crate::driver::{Driver, EventSink};
use crate::gate::{Gate, Grants};
use crate::lease::LeaseCaller;
use crate::protocol::DriverEvent;
use crate::provider::{Frame, read_frame};
use crate::provider_engine::ProviderEngine;
use crate::provider_link::{ProviderDriver, tee_inputs};
use crate::vm::VmHost;
use serde_json::json;
use std::os::unix::net::UnixStream;
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

#[test]
fn one_input_call_gives_the_app_exactly_one_input_frame() {
    let (app, host) = UnixStream::pair().expect("socket pair");
    let provider = ProviderDriver::start(
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
    let seen: Arc<Mutex<Vec<DriverEvent>>> = Arc::default();
    let sink_seen = seen.clone();
    let session_sink: EventSink = Arc::new(move |event| sink_seen.lock().unwrap().push(event));
    // What HostEngines::provider builds for a cef session named "lease-s".
    let lease = LeaseCaller {
        session: "lease-s".into(),
        actor: "agent-1".into(),
        on_behalf_of: None,
        origin: "mux".into(),
        label: "lease-s".into(),
        implicit_session: false,
        engine: "cef".into(),
    };
    let engine = ProviderEngine::new(
        provider.clone(),
        "cef",
        Arc::from(""),
        tee_inputs(session_sink.clone(), &provider, "lease-s"),
        lease,
    )
    .expect("engine");
    let driver: Arc<dyn Driver> = Arc::new(engine);
    let gate = Gate::new(driver, Grants::default()).with_input_events("lease-s", session_sink);

    // The app has no tab c1, so the call fails after the gate published the
    // input; the frame count is what matters here.
    let _ = gate.driver_call(
        "input.mouse",
        json!({"targetId": "c1", "type": "move", "x": 3, "y": 4, "url": "https://leak.test/"}),
    );

    let mut inputs = Vec::new();
    while let Ok(frame) = rx.recv_timeout(Duration::from_millis(500)) {
        if let Frame::Input { event } = frame {
            inputs.push(event);
        }
    }
    assert_eq!(inputs.len(), 1, "exactly one input frame: {inputs:?}");
    let event = &inputs[0];
    assert_eq!(event["session_id"], "lease-s");
    assert_eq!(event["target_id"], "c1");
    assert_eq!(event["seq"], 0);
    assert_eq!(event["kind"], "move");
    assert!(!event.to_string().contains("leak.test"), "{event}");
    let seen = seen.lock().unwrap();
    let delivered: Vec<_> = seen.iter().filter(|e| e.name == "automation.input").collect();
    assert_eq!(delivered.len(), 1, "the session sink gets it once too");
    assert_eq!(&delivered[0].payload, event, "the app gets it verbatim");
}
