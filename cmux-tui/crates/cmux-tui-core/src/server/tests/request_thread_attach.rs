//! A sized browser attach waits for the browser host's resize, another
//! process: a work item attaches and answers, never the request thread
//! (p02-threads 220). Each test runs the request on a thread that disallows
//! blocking, in panic mode: a wait left on that thread fails the test at its
//! call site.

use super::*;
use crate::server::request_thread_tests::{next_reply, on_request_thread_with};

#[test]
fn a_sized_browser_attach_waits_for_the_resize_off_the_request_thread() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (80, 24));
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let hello = json!({"id": 1, "cmd": "set-client-info",
                       "capabilities": [GUARDED_BROWSER_POINTER_CAPABILITY]});
    assert!(handle_message(&mux, client, &hello.to_string(), &writer));
    let attach = json!({"id": 2, "cmd": "attach-surface", "surface": surface.id,
                        "cols": 100, "rows": 30})
    .to_string();
    assert!(on_request_thread_with(&mux, move |mux| {
        handle_message(mux, client, &attach, &writer)
    }));
    let reply = loop {
        let reply = next_reply(&outbound);
        if reply["id"] == 2 {
            break reply;
        }
    };
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(surface.size(), (100, 30), "the attach answered before the host resized");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

#[test]
fn a_sized_resource_browser_attach_waits_for_the_resize_off_the_request_thread() {
    let mux = test_mux();
    let surface = sizing_browser(&mux, (80, 24));
    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let browser = snapshot["browsers"][0]["id"].as_str().expect("browser id").to_owned();
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let stream_id = "stream_00000000000000000000000000000220";
    let attach = resource_request(
        "browser-attach-sized",
        "browser.attach",
        json!({"machine": "current", "session": "current", "browser": browser,
               "stream_id": stream_id, "width_px": 1000, "height_px": 600}),
        None,
    );
    assert!(on_request_thread_with(&mux, move |mux| {
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        handle_connection_message(mux, client, &attach, &writer, &scheduler)
    }));
    let reply = loop {
        let reply = next_reply(&outbound);
        if reply["id"] == "browser-attach-sized" {
            break reply;
        }
    };
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(reply["result"]["stream_id"], stream_id, "{reply}");
    assert_ne!(surface.size(), (80, 24), "the attach answered before the host resized");
    disconnect_client(&mux, client, false);
    mux.shutdown();
}
