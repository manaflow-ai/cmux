//! Transport framing, readers and writers, initialization, and disconnect.

use super::*;

#[cfg(unix)]
#[test]
fn json_line_reader_returns_complete_messages_without_delimiters() {
    let (client, mut server) = UnixStream::pair().unwrap();
    server.write_all(b"{\"fragmented\":").unwrap();
    server.write_all(b"true}\n{\"crlf\":true}\r\n{\"final\":true}").unwrap();
    server.shutdown(Shutdown::Write).unwrap();

    let mut reader = JsonLineReader { inner: BufReader::new(Box::new(client)) };
    assert_eq!(reader.receive().unwrap().as_deref(), Some("{\"fragmented\":true}"));
    assert_eq!(reader.receive().unwrap().as_deref(), Some("{\"crlf\":true}"));
    assert_eq!(reader.receive().unwrap().as_deref(), Some("{\"final\":true}"));
    assert_eq!(reader.receive().unwrap(), None);
}

#[cfg(unix)]
#[test]
fn json_line_writer_appends_exactly_one_delimiter_per_message() {
    let (client, mut server) = UnixStream::pair().unwrap();
    let mut writer = JsonLineWriter { inner: Box::new(client) };

    writer.send("{\"first\":1}").unwrap();
    writer.send("{\"second\":2}").unwrap();
    writer.close().unwrap();

    let mut bytes = String::new();
    server.read_to_string(&mut bytes).unwrap();
    assert_eq!(bytes, "{\"first\":1}\n{\"second\":2}\n");
}

#[derive(Clone, Copy, Debug)]
enum InitializationFailure {
    IdentifyRejected,
    WrongApp,
    WrongProtocol,
    ClientInfoRejected,
    SubscribeRejected,
}

struct ScriptedInitializationReader {
    responses: Receiver<String>,
}

impl RemoteMessageReader for ScriptedInitializationReader {
    fn receive(&mut self) -> io::Result<Option<String>> {
        Ok(self.responses.recv().ok())
    }
}

struct ScriptedInitializationWriter {
    responses: Sender<String>,
    failure: InitializationFailure,
    closed: Arc<AtomicBool>,
}

impl RemoteMessageWriter for ScriptedInitializationWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
        let command = request
            .get("cmd")
            .and_then(Value::as_str)
            .ok_or_else(|| io::Error::other("remote request omitted its command"))?;
        if command == "set-client-info" {
            assert!(
                request["capabilities"].as_array().is_some_and(|capabilities| {
                    capabilities.iter().any(|capability| {
                        capability.as_str() == Some(GUARDED_BROWSER_POINTER_CAPABILITY)
                    })
                }),
                "a client using guarded browser commands must advertise that capability"
            );
        }
        let response = match (self.failure, command) {
            (InitializationFailure::IdentifyRejected, "identify") => {
                json!({"id": id, "ok": false, "error": "identify rejected"})
            }
            (InitializationFailure::WrongApp, "identify") => json!({
                "id": id,
                "ok": true,
                "data": {"app": "not-cmux-tui", "protocol": SUPPORTED_PROTOCOL_VERSION},
            }),
            (InitializationFailure::WrongProtocol, "identify") => json!({
                "id": id,
                "ok": true,
                "data": {"app": "cmux-tui", "protocol": SUPPORTED_PROTOCOL_VERSION - 1},
            }),
            (InitializationFailure::ClientInfoRejected, "set-client-info") => {
                json!({"id": id, "ok": false, "error": "client info rejected"})
            }
            (InitializationFailure::SubscribeRejected, "subscribe") => {
                json!({"id": id, "ok": false, "error": "subscribe rejected"})
            }
            (_, "identify") => json!({
                "id": id,
                "ok": true,
                "data": {
                    "app": "cmux-tui",
                    "protocol": SUPPORTED_PROTOCOL_VERSION,
                    "capabilities": ["browser-pointer-frame-guard-v1"],
                },
            }),
            (_, "set-client-info" | "subscribe") => {
                json!({"id": id, "ok": true, "data": null})
            }
            (_, command) => {
                return Err(io::Error::other(format!(
                    "unexpected initialization command: {command}"
                )));
            }
        };
        self.responses
            .send(response.to_string())
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "reader exited"))
    }

    fn close(&mut self) -> io::Result<()> {
        self.closed.store(true, Ordering::Release);
        Ok(())
    }
}

fn scripted_initialization_transport(
    failure: InitializationFailure,
    closed: Arc<AtomicBool>,
) -> RemoteTransport {
    let (responses, received_responses) = channel();
    RemoteTransport::new(
        Box::new(ScriptedInitializationReader { responses: received_responses }),
        Box::new(ScriptedInitializationWriter { responses, failure, closed }),
        Arc::new(NoopTransportAbort),
    )
}

#[test]
fn oversized_remote_reader_message_is_zeroized_before_disconnect() {
    let mut message = "secret remote payload".to_string();
    let reason = remote_reader_message_too_large(&mut message);

    assert_eq!(
        reason,
        format!(
            "remote session message exceeds the \
             {REMOTE_SESSION_MESSAGE_MAX_BYTES}-byte limit"
        )
    );
    assert!(message.bytes().all(|byte| byte == 0));
}

#[test]
fn guarded_pointer_timeout_uses_transport_disconnect_lifecycle() {
    let closed = Arc::new(AtomicBool::new(false));
    let session = test_session(Box::new(CloseTrackingWriter { closed: closed.clone() }));

    assert!(
        session
            .request_guarded_pointer(
                json!({
                    "cmd": "browser-mouse-guarded",
                    "kind": "down"
                }),
                GuardedPointerLifecycle::CaptureMutation
            )
            .unwrap_err()
            .downcast_ref::<RemoteRequestError>()
            .is_some_and(RemoteRequestError::is_timeout)
    );
    assert!(session.shutdown.load(Ordering::Acquire));
    assert!(closed.load(Ordering::Acquire));
}

#[test]
fn guarded_pointer_hover_timeout_preserves_the_transport() {
    let closed = Arc::new(AtomicBool::new(false));
    let session = test_session(Box::new(CloseTrackingWriter { closed: closed.clone() }));

    assert!(
        session
            .request_guarded_pointer(
                json!({
                    "cmd": "browser-mouse-guarded",
                    "kind": "move"
                }),
                GuardedPointerLifecycle::Motion
            )
            .unwrap_err()
            .downcast_ref::<RemoteRequestError>()
            .is_some_and(RemoteRequestError::is_timeout)
    );
    assert!(!session.shutdown.load(Ordering::Acquire));
    assert!(!closed.load(Ordering::Acquire));
}

#[test]
fn initialization_failures_after_reader_spawn_close_the_transport() {
    for (failure, expected_error) in [
        (InitializationFailure::IdentifyRejected, "identify rejected"),
        (InitializationFailure::WrongApp, "socket endpoint is not a cmux-tui session"),
        (InitializationFailure::WrongProtocol, "unsupported cmux-tui protocol"),
        (InitializationFailure::ClientInfoRejected, "client info rejected"),
        (InitializationFailure::SubscribeRejected, "subscribe rejected"),
    ] {
        let closed = Arc::new(AtomicBool::new(false));
        let result = RemoteSession::connect_transport(scripted_initialization_transport(
            failure,
            closed.clone(),
        ));

        let error = result.err().expect("scripted initialization should fail");
        assert!(
            error.to_string().contains(expected_error),
            "{failure:?} returned unexpected error: {error}"
        );
        assert!(closed.load(Ordering::Acquire), "{failure:?} did not close its transport");
    }
}

#[test]
fn deferred_surface_initialization_skips_the_unfiltered_subscription() {
    let closed = Arc::new(AtomicBool::new(false));

    let session = RemoteSession::connect_transport_with_initial_subscription(
        scripted_initialization_transport(InitializationFailure::SubscribeRejected, closed.clone()),
        false,
    )
    .expect("deferred initialization must not send subscribe");

    assert!(!session.subscription_started.load(Ordering::Acquire));
    assert!(!closed.load(Ordering::Acquire));
}
