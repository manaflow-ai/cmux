//! Unit tests for the browser surface runtime: shared helpers here, one
//! child module per concern.

use super::{
    AUTHORITY_CAPTURE_ATTEMPTS, BROWSER_COMMAND_QUEUE_CAPACITY, BrowserCaptureOptions,
    BrowserCommand, BrowserFrame, BrowserSession, BrowserSource, BrowserStatus,
    MAX_RECONFIGURE_WAITERS_PER_RESERVATION, SequencedBrowserCommand, capture_scale_for,
    handle_frame_navigated, handle_same_document_navigated, new_surface, normalize_url,
    runtime_endpoint, scaled_pixels, start_surface_thread, take_latest_worker_commands,
};

use crate::lock_rank::Mutex;
use crate::{Mux, MuxEvent, Surface, SurfaceOptions};
use serde_json::{Value, json};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Weak, mpsc};
use std::thread;
use std::time::{Duration, Instant};
use tungstenite::{Message, accept};

const BROWSER_TEST_EVENT_TIMEOUT: Duration = Duration::from_secs(5);
/// Real time that only ends a failing run: a passing run never waits
/// for it, so a slow thread under full-suite load is not a failure.
const BROWSER_TEST_SAFETY_BOUND: Duration = Duration::from_secs(30);

fn test_frame(seq: u64) -> BrowserFrame {
    BrowserFrame {
        session_id: "session-test".to_string(),
        data_b64: "AAAA".to_string(),
        css_width: 80,
        css_height: 48,
        image_width: 80,
        image_height: 48,
        seq,
    }
}

fn runtime_rejecting_one_mouse_dispatch() -> (Arc<super::BrowserRuntime>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

        let mouse = read_ws_json(&mut ws);
        assert_eq!(mouse["method"], "Input.dispatchMouseEvent");
        write_ws_json(
            &mut ws,
            json!({
                "id": mouse["id"],
                "error": {"message": "CDP call Input.dispatchMouseEvent timed out"}
            }),
        );
    });
    let runtime = super::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    (runtime, server)
}

fn runtime_rejecting_then_observing_mouse_retry()
-> (Arc<super::BrowserRuntime>, thread::JoinHandle<()>, mpsc::Receiver<bool>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (observed_tx, observed_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

        let mouse = read_ws_json(&mut ws);
        assert_eq!(mouse["method"], "Input.dispatchMouseEvent");
        write_ws_json(
            &mut ws,
            json!({
                "id": mouse["id"],
                "error": {"message": "CDP call Input.dispatchMouseEvent timed out"}
            }),
        );

        ws.get_mut().set_read_timeout(Some(BROWSER_TEST_EVENT_TIMEOUT)).unwrap();
        let retry = loop {
            match ws.read() {
                Ok(Message::Text(text)) => break serde_json::from_str::<Value>(&text).ok(),
                Ok(Message::Binary(bytes)) => {
                    break serde_json::from_slice::<Value>(&bytes).ok();
                }
                Ok(_) => {}
                Err(_) => break None,
            }
        };
        let observed =
            retry.as_ref().is_some_and(|retry| retry["method"] == "Input.dispatchMouseEvent");
        if let Some(retry) = retry {
            write_ws_json(&mut ws, json!({"id": retry["id"], "result": {}}));
        }
        observed_tx.send(observed).unwrap();
    });
    let runtime = super::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    (runtime, server, observed_rx)
}

fn runtime_accepting_mouse_dispatches(
    expected_types: Vec<&'static str>,
) -> (Arc<super::BrowserRuntime>, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

        for expected_type in expected_types {
            let mouse = read_ws_json(&mut ws);
            assert_eq!(mouse["method"], "Input.dispatchMouseEvent");
            assert_eq!(mouse["params"]["type"], expected_type);
            write_ws_json(&mut ws, json!({"id": mouse["id"], "result": {}}));
        }
    });
    let runtime = super::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    (runtime, server)
}

fn runtime_recording_key_dispatches() -> (
    Arc<super::BrowserRuntime>,
    thread::JoinHandle<()>,
    mpsc::Receiver<Vec<String>>,
    mpsc::Sender<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (observed_tx, observed_rx) = mpsc::channel();
    let (start_tx, start_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(BROWSER_TEST_EVENT_TIMEOUT)).unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));

        start_rx.recv().unwrap();
        let mut event_types = Vec::new();
        while event_types.len() < 2 {
            let request = match ws.read() {
                Ok(Message::Text(text)) => serde_json::from_str::<Value>(&text).ok(),
                Ok(Message::Binary(bytes)) => serde_json::from_slice::<Value>(&bytes).ok(),
                Ok(_) => None,
                Err(tungstenite::Error::Io(error))
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    break;
                }
                Err(_) => break,
            };
            let Some(request) = request else { continue };
            if request["method"] == "Input.dispatchKeyEvent" {
                event_types.push(request["params"]["type"].as_str().unwrap().to_string());
            }
            write_ws_json(&mut ws, json!({"id": request["id"], "result": {}}));
        }
        observed_tx.send(event_types).unwrap();
    });
    let runtime = super::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    (runtime, server, observed_rx, start_tx)
}

fn runtime_recording_mouse_dispatches()
-> (Arc<super::BrowserRuntime>, thread::JoinHandle<()>, mpsc::Receiver<Value>, mpsc::Sender<()>) {
    const ONE_PIXEL_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (events_tx, events_rx) = mpsc::channel();
    let (stop_tx, stop_rx) = mpsc::channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let discover = read_ws_json(&mut ws);
        assert_eq!(discover["method"], "Target.setDiscoverTargets");
        write_ws_json(&mut ws, json!({"id": discover["id"], "result": {}}));
        // The short timeout only paces the stop check below. Set before
        // the handshake, it failed the handshake whenever the client
        // took longer than 50 ms to connect under load.
        ws.get_mut().set_read_timeout(Some(Duration::from_millis(50))).unwrap();

        loop {
            if stop_rx.try_recv().is_ok() {
                break;
            }
            let request = match ws.read() {
                Ok(Message::Text(text)) => serde_json::from_str::<Value>(&text).ok(),
                Ok(Message::Binary(bytes)) => serde_json::from_slice::<Value>(&bytes).ok(),
                Ok(_) => None,
                Err(tungstenite::Error::Io(error))
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    continue;
                }
                Err(_) => break,
            };
            let Some(request) = request else { continue };
            if request["method"] == "Input.dispatchMouseEvent" {
                events_tx.send(request.clone()).unwrap();
            }
            let result = match request["method"].as_str().unwrap() {
                "Page.createIsolatedWorld" => json!({"executionContextId": 41}),
                "Runtime.evaluate" => {
                    json!({"result": {"type": "number", "value": 10_000.0}})
                }
                "Page.getFrameTree" => json!({
                    "frameTree": {
                        "frame": {
                            "id": "main-frame",
                            "loaderId": "loader-1",
                            "url": "https://example.test/#recovery"
                        }
                    }
                }),
                "Page.captureScreenshot" => json!({"data": ONE_PIXEL_PNG}),
                _ => json!({}),
            };
            write_ws_json(&mut ws, json!({"id": request["id"], "result": result}));
        }
    });
    let runtime = super::BrowserRuntime::connect_to_endpoint(
        &format!("ws://{addr}/devtools/browser/fake"),
        BrowserSource::External,
    )
    .unwrap();
    (runtime, server, events_rx, stop_tx)
}

fn test_surface() -> Arc<Surface> {
    let opts = SurfaceOptions::default();
    new_surface(1, "https://example.test".into(), (10, 5), (8, 16), &opts, Weak::new()).unwrap()
}

fn acknowledge_local_presentation(browser: &super::BrowserSurface, frame_seq: u64) {
    assert!(
        browser.acknowledge_pointer_frame(frame_seq),
        "test frame {frame_seq} must belong to the current pointer route"
    );
}

fn read_ws_json(ws: &mut tungstenite::WebSocket<TcpStream>) -> Value {
    loop {
        match ws.read().unwrap() {
            Message::Text(text) => return serde_json::from_str(&text).unwrap(),
            Message::Binary(bytes) => return serde_json::from_slice(&bytes).unwrap(),
            _ => {}
        }
    }
}

fn write_ws_json(ws: &mut tungstenite::WebSocket<TcpStream>, value: Value) {
    ws.send(Message::Text(value.to_string().into())).unwrap();
}

mod document_authority;
mod navigation_barriers;
mod pointer_capture;
mod reconfigure_and_attach;
mod runtime_routes;
mod worker_and_input_mapping;
