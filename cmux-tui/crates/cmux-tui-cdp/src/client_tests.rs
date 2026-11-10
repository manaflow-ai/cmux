use std::io::Write;
use std::net::TcpListener;
use std::sync::mpsc::sync_channel;
use std::sync::{Arc, Barrier};
use std::thread;
use std::time::{Duration, Instant};

use tungstenite::{Message, accept, accept_hdr};

use super::*;

#[test]
#[allow(clippy::result_large_err)]
fn bearer_auth_is_sent_on_the_websocket_upgrade() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (header_tx, header_rx) = channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let _ws =
            accept_hdr(stream, |request: &tungstenite::handshake::server::Request, response| {
                header_tx
                    .send(
                        request
                            .headers()
                            .get(AUTHORIZATION)
                            .and_then(|value| value.to_str().ok())
                            .map(str::to_string),
                    )
                    .unwrap();
                Ok(response)
            })
            .unwrap();
    });
    let (event_tx, _event_rx) = sync_channel(1);
    let _client = CdpClient::connect_with_bearer(
        &format!("ws://{addr}/devtools/browser/fake"),
        Some("test-secret"),
        event_tx,
    )
    .unwrap();
    assert_eq!(
        header_rx.recv_timeout(Duration::from_secs(1)).unwrap().as_deref(),
        Some("Bearer test-secret")
    );
    server.join().unwrap();
}

#[test]
fn snapshot_main_frame_rejects_values_invalidated_by_navigation() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (respond_tx, respond_rx) = channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let request = loop {
            match ws.read().unwrap() {
                Message::Text(text) => break serde_json::from_str::<Value>(&text).unwrap(),
                Message::Binary(bytes) => {
                    break serde_json::from_slice::<Value>(&bytes).unwrap();
                }
                _ => {}
            }
        };
        assert_eq!(request["method"], "Page.getFrameTree");
        ws.send(Message::Text(
            json!({
                "method": "Page.frameNavigated",
                "sessionId": "session-1",
                "params": {
                    "frame": {
                        "id": "new-frame",
                        "loaderId": "new-loader",
                        "url": "https://new.example.test"
                    }
                }
            })
            .to_string()
            .into(),
        ))
        .unwrap();
        respond_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        ws.send(Message::Text(
            json!({
                "id": request["id"],
                "result": {
                    "frameTree": {
                        "frame": {
                            "id": "stale-frame",
                            "loaderId": "stale-loader",
                            "url": "https://stale.example.test"
                        }
                    }
                }
            })
            .to_string()
            .into(),
        ))
        .unwrap();
    });
    let (event_tx, event_rx) = sync_channel(1);
    let client =
        CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
    let frame_epoch = Arc::new(FrameEpoch::default());
    client.register_frame_epoch("session-1", frame_epoch.clone());
    let snapshot_client = client.clone();
    let snapshot = thread::spawn(move || snapshot_client.snapshot_main_frame("session-1"));

    assert!(matches!(
        event_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
        CdpEvent::FrameNavigated { frame_epoch: 1, .. }
    ));
    assert_eq!(frame_epoch.current(), 1);
    respond_tx.send(()).unwrap();
    let result = snapshot.join().unwrap();
    assert!(
        result.is_err(),
        "a frame-tree response invalidated by navigation returned stale authority: {result:?}"
    );

    drop(client);
    server.join().unwrap();
}

#[test]
fn seed_main_frame_retries_snapshot_invalidated_by_navigation() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let mut ws = accept(stream).unwrap();
        let first = loop {
            match ws.read().unwrap() {
                Message::Text(text) => break serde_json::from_str::<Value>(&text).unwrap(),
                Message::Binary(bytes) => {
                    break serde_json::from_slice::<Value>(&bytes).unwrap();
                }
                _ => {}
            }
        };
        assert_eq!(first["method"], "Page.getFrameTree");
        ws.send(Message::Text(
            json!({
                "method": "Page.frameNavigated",
                "sessionId": "session-1",
                "params": {
                    "frame": {
                        "id": "new-frame",
                        "loaderId": "new-loader",
                        "url": "https://new.example.test"
                    }
                }
            })
            .to_string()
            .into(),
        ))
        .unwrap();
        ws.send(Message::Text(
            json!({
                "id": first["id"],
                "result": {
                    "frameTree": {
                        "frame": {
                            "id": "stale-frame",
                            "loaderId": "stale-loader",
                            "url": "https://stale.example.test"
                        }
                    }
                }
            })
            .to_string()
            .into(),
        ))
        .unwrap();

        let retry = loop {
            match ws.read() {
                Ok(Message::Text(text)) => {
                    break Some(serde_json::from_str::<Value>(&text).unwrap());
                }
                Ok(Message::Binary(bytes)) => {
                    break Some(serde_json::from_slice::<Value>(&bytes).unwrap());
                }
                Ok(_) => {}
                Err(tungstenite::Error::Io(error))
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    break None;
                }
                Err(_) => break None,
            }
        };
        let Some(retry) = retry else { return false };
        assert_eq!(retry["method"], "Page.getFrameTree");
        ws.send(Message::Text(
            json!({
                "id": retry["id"],
                "result": {
                    "frameTree": {
                        "frame": {
                            "id": "new-frame",
                            "loaderId": "new-loader",
                            "url": "https://new.example.test"
                        }
                    }
                }
            })
            .to_string()
            .into(),
        ))
        .unwrap();
        true
    });
    let (event_tx, _event_rx) = sync_channel(2);
    let client =
        CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
    client.register_frame_epoch("session-1", Arc::new(FrameEpoch::default()));

    let result = client.seed_main_frame("session-1");

    drop(client);
    let retried = server.join().unwrap();
    assert!(
        result.is_ok(),
        "bootstrap rejected a snapshot invalidated by normal navigation: {result:?}"
    );
    assert!(retried, "bootstrap did not request a fresh post-navigation snapshot");
}

#[test]
fn screenshot_authority_is_bracketed_by_the_committed_loader() {
    const ONE_PIXEL_PNG: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=";
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        for post_loader in ["loader-1", "loader-2"] {
            for expected in ["Page.getFrameTree", "Page.captureScreenshot", "Page.getFrameTree"] {
                let request = loop {
                    match ws.read().unwrap() {
                        Message::Text(text) => {
                            break serde_json::from_str::<Value>(&text).unwrap();
                        }
                        Message::Binary(bytes) => {
                            break serde_json::from_slice::<Value>(&bytes).unwrap();
                        }
                        _ => {}
                    }
                };
                assert_eq!(request["method"], expected);
                let result = match expected {
                    "Page.getFrameTree" => {
                        let loader_id = if request["id"].as_u64().unwrap().is_multiple_of(3) {
                            post_loader
                        } else {
                            "loader-1"
                        };
                        json!({
                            "frameTree": {
                                "frame": {
                                    "id": "main-frame",
                                    "loaderId": loader_id,
                                    "url": "https://example.test"
                                }
                            }
                        })
                    }
                    "Page.captureScreenshot" => json!({"data": ONE_PIXEL_PNG}),
                    _ => unreachable!(),
                };
                ws.send(Message::Text(
                    json!({"id": request["id"], "result": result}).to_string().into(),
                ))
                .unwrap();
            }
        }
    });
    let (event_tx, _event_rx) = sync_channel(1);
    let client =
        CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();

    let frame =
        client.capture_main_frame_for_loader("session-1", "main-frame", "loader-1").unwrap();
    assert_eq!((frame.css_width, frame.css_height), (1, 1));
    let error =
        client.capture_main_frame_for_loader("session-1", "main-frame", "loader-1").unwrap_err();
    assert!(error.to_string().contains("main document changed"), "{error:#}");

    drop(client);
    server.join().unwrap();
}

#[test]
fn screencast_restart_rejects_delayed_frame_captured_before_barrier() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        for expected in [
            "Page.stopScreencast",
            "Page.createIsolatedWorld",
            "Runtime.evaluate",
            "Page.startScreencast",
        ] {
            let request = ws.read().unwrap();
            let Message::Text(request) = request else { panic!("expected text request") };
            let request: Value = serde_json::from_str(&request).unwrap();
            assert_eq!(request["method"], expected);
            if expected == "Page.createIsolatedWorld" {
                assert_eq!(request["params"]["frameId"], "main-frame");
                assert_eq!(request["params"]["grantUniversalAccess"], false);
                assert!(request["params"].get("grantUniveralAccess").is_none());
            } else if expected == "Runtime.evaluate" {
                assert_eq!(request["params"]["contextId"], 41);
                assert_eq!(request["params"]["expression"], "globalThis.Date.now()");
            }
            let result = match expected {
                "Page.createIsolatedWorld" => json!({"executionContextId": 41}),
                "Runtime.evaluate" => {
                    json!({"result": {"type": "number", "value": 10_000.0}})
                }
                _ => json!({}),
            };
            ws.send(Message::Text(
                json!({"id": request["id"], "result": result}).to_string().into(),
            ))
            .unwrap();
        }
        ws.send(Message::Text(
            json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "AAAA",
                    "sessionId": 7,
                    "metadata": {
                        "deviceWidth": 80,
                        "deviceHeight": 24,
                        "timestamp": 10.0
                    }
                }
            })
            .to_string()
            .into(),
        ))
        .unwrap();
        let ack = ws.read().unwrap();
        let Message::Text(ack) = ack else { panic!("expected text ack") };
        let ack: Value = serde_json::from_str(&ack).unwrap();
        assert_eq!(ack["method"], "Page.screencastFrameAck");
        ws.send(Message::Text(
            json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "AQ==",
                    "sessionId": 8,
                    "metadata": {
                        "deviceWidth": 80,
                        "deviceHeight": 24,
                        "timestamp": 10.002
                    }
                }
            })
            .to_string()
            .into(),
        ))
        .unwrap();
        let ack = ws.read().unwrap();
        let Message::Text(ack) = ack else { panic!("expected text ack") };
        let ack: Value = serde_json::from_str(&ack).unwrap();
        assert_eq!(ack["method"], "Page.screencastFrameAck");
    });
    let (event_tx, event_rx) = sync_channel(2);
    let client =
        CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
    client.register_frame_epoch("session-1", Arc::new(FrameEpoch::default()));
    client.inner.frame_epochs.lock().unwrap().get_mut("session-1").unwrap().main_frame_id =
        Some("main-frame".to_string());

    client.stop_screencast("session-1").unwrap();
    client.start_screencast_with_frame_barrier("session-1", 80, 24).unwrap();

    let first = event_rx.recv_timeout(Duration::from_millis(200));
    assert!(
        matches!(
            first,
            Ok(CdpEvent::ScreencastFrame(ScreencastFrame {
                ref data_b64,
                frame_epoch: 1,
                ..
            })) if data_b64 == "AQ=="
        ),
        "the Chrome-domain barrier did not reject the delayed capture and admit the new one: \
             {first:?}"
    );
    server.join().unwrap();
}

#[test]
fn unavailable_screencast_clock_probe_requests_loader_verified_capture() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        ws.get_mut().set_read_timeout(Some(Duration::from_secs(1))).unwrap();

        let request = ws.read().unwrap();
        let Message::Text(request) = request else { panic!("expected text request") };
        let request: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(request["method"], "Page.createIsolatedWorld");
        ws.send(Message::Text(
            json!({
                "id": request["id"],
                "error": {"message": "scripts unavailable"}
            })
            .to_string()
            .into(),
        ))
        .unwrap();

        let request = ws.read().unwrap();
        let Message::Text(request) = request else { panic!("expected text request") };
        let request: Value = serde_json::from_str(&request).unwrap();
        assert_eq!(request["method"], "Page.startScreencast");
        ws.send(Message::Text(json!({"id": request["id"], "result": {}}).to_string().into()))
            .unwrap();

        ws.send(Message::Text(
            json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "not-base64",
                    "sessionId": 7,
                    "metadata": {
                        "deviceWidth": 80,
                        "deviceHeight": 24,
                        "timestamp": 10.0
                    }
                }
            })
            .to_string()
            .into(),
        ))
        .unwrap();
        let ack = ws.read().unwrap();
        let Message::Text(ack) = ack else { panic!("expected text ack") };
        let ack: Value = serde_json::from_str(&ack).unwrap();
        assert_eq!(ack["method"], "Page.screencastFrameAck");
    });
    let (event_tx, event_rx) = sync_channel(1);
    let client =
        CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
    client.register_frame_epoch("session-1", Arc::new(FrameEpoch::default()));
    {
        let mut frame_sessions = client.inner.frame_epochs.lock().unwrap();
        let frame_session = frame_sessions.get_mut("session-1").unwrap();
        frame_session.main_frame_id = Some("main-frame".to_string());
        frame_session.main_loader_id = Some("loader-1".to_string());
    }

    let result = client.start_screencast_with_frame_barrier("session-1", 80, 24);
    let event =
        result.as_ref().ok().and_then(|_| event_rx.recv_timeout(Duration::from_millis(200)).ok());

    drop(client);
    let server_result = server.join();
    assert!(
        result.is_ok(),
        "an unavailable optional clock probe must not prevent screencast restart: {result:?}"
    );
    server_result.unwrap();
    assert!(
        matches!(
            event,
            Some(CdpEvent::ScreencastFrameCaptureRequested {
                ref session_id,
                ref frame_id,
                ref loader_id,
                frame_epoch: 1,
                navigation_epoch: 0,
                ..
            }) if session_id == "session-1"
                && frame_id == "main-frame"
                && loader_id == "loader-1"
        ),
        "a streamed frame without a trustworthy cutoff bypassed loader verification: {event:?}"
    );
}

#[test]
fn loader_verified_capture_recovers_timestamped_screencast_stream() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (recovered_tx, recovered_rx) = sync_channel(1);
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        ws.get_mut().set_read_timeout(Some(Duration::from_secs(1))).unwrap();

        for expected in ["Page.createIsolatedWorld", "Runtime.evaluate"] {
            let Ok(Message::Text(request)) = ws.read() else {
                return false;
            };
            let request: Value = serde_json::from_str(&request).unwrap();
            assert_eq!(request["method"], expected);
            let result = match expected {
                "Page.createIsolatedWorld" => json!({"executionContextId": 41}),
                "Runtime.evaluate" => {
                    json!({"result": {"type": "number", "value": 10_000.0}})
                }
                _ => unreachable!(),
            };
            ws.send(Message::Text(
                json!({"id": request["id"], "result": result}).to_string().into(),
            ))
            .unwrap();
        }
        if recovered_rx.recv_timeout(Duration::from_secs(1)).is_err() {
            return false;
        }
        ws.send(Message::Text(
            json!({
                "method": "Page.screencastFrame",
                "sessionId": "session-1",
                "params": {
                    "data": "AAAA",
                    "sessionId": 8,
                    "metadata": {
                        "deviceWidth": 80,
                        "deviceHeight": 24,
                        "timestamp": 10.002
                    }
                }
            })
            .to_string()
            .into(),
        ))
        .unwrap();
        let Ok(Message::Text(ack)) = ws.read() else {
            return false;
        };
        let ack: Value = serde_json::from_str(&ack).unwrap();
        ack["method"] == "Page.screencastFrameAck"
    });
    let (event_tx, event_rx) = sync_channel(1);
    let client =
        CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
    client.register_frame_epoch("session-1", Arc::new(FrameEpoch::default()));
    {
        let mut frame_sessions = client.inner.frame_epochs.lock().unwrap();
        let frame_session = frame_sessions.get_mut("session-1").unwrap();
        frame_session.main_frame_id = Some("main-frame".to_string());
        frame_session.main_loader_id = Some("loader-1".to_string());
        frame_session.screencast_barrier = Some(ScreencastBarrier::LoaderVerifiedCapture);
        frame_session.pending_timestampless_capture = Some(PendingTimestamplessCapture {
            request_id: 7,
            frame_epoch: 0,
            navigation_epoch: 0,
        });
    }

    let settled = client.settle_timestampless_screencast_capture("session-1", 7, 0, 0);
    let _ = recovered_tx.send(());
    let event = event_rx.recv_timeout(Duration::from_millis(250));

    drop(client);
    let probe_completed = server.join().unwrap();
    assert!(settled);
    assert!(
        probe_completed,
        "a verified capture must retry the clock probe before returning to streamed frames"
    );
    assert!(
        matches!(
            event,
            Ok(CdpEvent::ScreencastFrame(ScreencastFrame { ack_id: 8, frame_epoch: 0, .. }))
        ),
        "a recovered timestamp barrier did not restore the streamed frame rate: {event:?}"
    );
}

#[test]
fn http_discovery_rejects_response_over_limit() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream.write_all(b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n").unwrap();
        stream.write_all(&vec![b'x'; 65 * 1024]).unwrap();
    });
    let mut stream = TcpStream::connect(addr).unwrap();

    let error = read_http_response(&mut stream).unwrap_err();
    assert!(error.to_string().contains("exceeds size limit"), "{error:#}");
    server.join().unwrap();
}

#[test]
fn http_discovery_enforces_absolute_deadline() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        for byte in b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" {
            if stream.write_all(&[*byte]).is_err() {
                break;
            }
            thread::sleep(Duration::from_millis(20));
        }
    });
    let mut stream = TcpStream::connect(addr).unwrap();

    let started = Instant::now();
    let error = read_http_response_with_limits(&mut stream, 64 * 1024, Duration::from_millis(100))
        .unwrap_err();
    assert!(error.to_string().contains("deadline exceeded"), "{error:#}");
    assert!(started.elapsed() < Duration::from_millis(500));
    server.join().unwrap();
}

#[test]
fn http_discovery_retries_idle_timeout_before_absolute_deadline() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream.write_all(b"HTTP/1.1 200 OK\r\n").unwrap();
        thread::sleep(Duration::from_millis(600));
        stream.write_all(b"Content-Length: 2\r\n\r\n{}").unwrap();
    });
    let mut stream = TcpStream::connect(addr).unwrap();

    let response =
        read_http_response_with_limits(&mut stream, 64 * 1024, Duration::from_secs(2)).unwrap();
    assert!(response.ends_with("{}"));
    server.join().unwrap();
}

#[test]
fn concurrent_calls_complete_while_reader_receives_events() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    const CALLS: usize = 12;
    const EMULATION_DEADLINE: Duration = Duration::from_secs(120);

    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        ws.get_ref().set_read_timeout(Some(Duration::from_millis(20))).unwrap();
        ws.get_ref().set_write_timeout(Some(EMULATION_DEADLINE)).unwrap();
        let deadline = Instant::now() + EMULATION_DEADLINE;
        let mut responses = 0usize;

        while responses < CALLS && Instant::now() < deadline {
            ws.send(Message::Text(
                json!({
                    "method": "Target.targetInfoChanged",
                    "params": {
                        "targetInfo": {
                            "targetId": "target-busy",
                            "title": "busy",
                            "url": "https://busy.test"
                        }
                    }
                })
                .to_string()
                .into(),
            ))
            .unwrap();

            match ws.read() {
                Ok(Message::Text(text)) => {
                    let request: Value = serde_json::from_str(&text).unwrap();
                    let id = request["id"].clone();
                    ws.send(Message::Text(
                        json!({"id": id, "result": {"method": request["method"]}})
                            .to_string()
                            .into(),
                    ))
                    .unwrap();
                    responses += 1;
                }
                Ok(Message::Binary(bytes)) => {
                    let request: Value = serde_json::from_slice(&bytes).unwrap();
                    let id = request["id"].clone();
                    ws.send(Message::Text(
                        json!({"id": id, "result": {"method": request["method"]}})
                            .to_string()
                            .into(),
                    ))
                    .unwrap();
                    responses += 1;
                }
                Ok(Message::Ping(_))
                | Ok(Message::Pong(_))
                | Ok(Message::Frame(_))
                | Ok(Message::Close(_)) => {}
                Err(WsError::Io(err))
                    if matches!(
                        err.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) => {}
                Err(err) => panic!("server websocket read failed: {err}"),
            }
        }

        assert_eq!(responses, CALLS);
    });

    let (event_tx, _event_rx) = sync_channel(64);
    let client =
        CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
    let barrier = Arc::new(Barrier::new(CALLS));
    let mut workers = Vec::new();
    for idx in 0..CALLS {
        let client = client.clone();
        let barrier = barrier.clone();
        workers.push(thread::spawn(move || {
            barrier.wait();
            let result = client.call("Test.concurrent", json!({ "idx": idx }), None).unwrap();
            assert_eq!(result["method"], "Test.concurrent");
        }));
    }

    for worker in workers {
        worker.join().unwrap();
    }
    server.join().unwrap();
}

#[test]
fn undrained_event_sink_does_not_block_command_responses() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (stop_tx, stop_rx) = channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let request = ws.read().unwrap();
        let Message::Text(request) = request else { panic!("expected text request") };
        let request: Value = serde_json::from_str(&request).unwrap();
        ws.send(Message::Text(
            json!({
                "method": "Target.targetInfoChanged",
                "params": {
                    "targetInfo": {
                        "targetId": "target-1",
                        "title": "busy",
                        "url": "https://example.test"
                    }
                }
            })
            .to_string()
            .into(),
        ))
        .unwrap();
        ws.send(Message::Text(
            json!({
                "id": request["id"],
                "result": {"userAgent": "Mozilla/5.0 Chrome/136.0 Safari/537.36"}
            })
            .to_string()
            .into(),
        ))
        .unwrap();
        let _ = stop_rx.recv();
    });
    let (event_tx, event_rx) = sync_channel(0);
    let client =
        CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
    let (result_tx, result_rx) = channel();
    let call_client = client.clone();
    let call = thread::spawn(move || {
        result_tx.send(call_client.browser_version()).unwrap();
    });

    let result = result_rx.recv_timeout(Duration::from_millis(200));
    let retained_event = event_rx.recv_timeout(Duration::from_millis(200));
    drop(client);
    stop_tx.send(()).unwrap();
    server.join().unwrap();
    call.join().unwrap();
    assert!(result.is_ok(), "undrained event sink blocked command response: {result:?}");
    assert!(
        matches!(retained_event, Ok(CdpEvent::TargetInfoChanged(_))),
        "final replaceable event was lost: {retained_event:?}"
    );
}

#[test]
fn saturated_event_sink_preserves_critical_event_and_response() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    let (stop_tx, stop_rx) = channel();
    let server = thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut ws = accept(stream).unwrap();
        let request = ws.read().unwrap();
        let Message::Text(request) = request else { panic!("expected text request") };
        let request: Value = serde_json::from_str(&request).unwrap();
        ws.send(Message::Text(
            json!({
                "method": "Page.javascriptDialogOpening",
                "sessionId": "session-1",
                "params": {"type": "alert", "message": "blocked"}
            })
            .to_string()
            .into(),
        ))
        .unwrap();
        ws.send(Message::Text(
            json!({
                "id": request["id"],
                "result": {"userAgent": "Mozilla/5.0 Chrome/136.0 Safari/537.36"}
            })
            .to_string()
            .into(),
        ))
        .unwrap();
        let _ = stop_rx.recv();
    });
    let (event_tx, event_rx) = sync_channel(0);
    let client =
        CdpClient::connect(&format!("ws://{addr}/devtools/browser/fake"), event_tx).unwrap();
    let (result_tx, result_rx) = channel();
    let call_client = client.clone();
    let call = thread::spawn(move || {
        result_tx.send(call_client.browser_version()).unwrap();
    });

    let result = result_rx.recv_timeout(Duration::from_millis(200));
    let retained_event = event_rx.recv_timeout(Duration::from_millis(200));
    drop(client);
    stop_tx.send(()).unwrap();
    server.join().unwrap();
    call.join().unwrap();
    assert!(matches!(result, Ok(Ok(_))), "critical event blocked command progress: {result:?}");
    assert!(
        matches!(retained_event, Ok(CdpEvent::Other { .. })),
        "critical event was lost: {retained_event:?}"
    );
}
