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

struct RecordingMessageWriter {
    messages: Arc<Mutex<Vec<String>>>,
}

impl RemoteMessageWriter for RecordingMessageWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        assert!(!message.contains(['\r', '\n']), "actor leaked transport framing");
        self.messages.lock().unwrap().push(message.to_string());
        Ok(())
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn interactive_actor_sends_complete_messages_without_transport_delimiters() {
    let messages = Arc::new(Mutex::new(Vec::new()));
    let session = test_session(Box::new(RecordingMessageWriter { messages: messages.clone() }));

    session.send_bytes(9, b"x").unwrap();
    session.disconnect_transport();

    let messages = messages.lock().unwrap();
    assert_eq!(messages.len(), 1);
    let request: Value = serde_json::from_str(&messages[0]).unwrap();
    assert_eq!(request["cmd"], "send");
    assert_eq!(request["bytes"], "eA==");
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
fn clear_history_shortcut_rejects_older_remote_server() {
    let session_slot = Arc::new(Mutex::new(None));
    let requests = Arc::new(Mutex::new(Vec::new()));
    let session = test_session(Box::new(RecordingAcknowledgingWriter {
        session: session_slot.clone(),
        requests: requests.clone(),
    }));
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
    session.surfaces.lock().unwrap().insert(7, test_remote_pty_surface(7, 80, 24, (8, 16)));
    let fallback = KeyInput {
        key: ghostty_vt::sys::GHOSTTY_KEY_L,
        mods: Mods::CTRL,
        unshifted_codepoint: 'l' as u32,
        action: Some(KeyAction::Press),
        ..Default::default()
    };

    let error =
        session.clear_history_or_send_key_classified(7, &fallback).unwrap_err().into_error();

    assert_eq!(error.to_string(), CLEAR_HISTORY_UNSUPPORTED_ERROR);
    assert!(requests.lock().unwrap().is_empty());
}

fn acknowledging_provider_session() -> Arc<RemoteSession> {
    let session_slot = Arc::new(Mutex::new(None));
    let session = test_session_with_provider_context(
        Box::new(AcknowledgingWriter { session: session_slot.clone(), requests: None }),
        HashSet::from([
            cmux_tui_core::server::PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY.to_string()
        ]),
        Some(BearerToken::new("acknowledged-provider-workspace-authority").unwrap()),
    );
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
    session
}

#[test]
fn remote_reader_end_reason_distinguishes_eof_from_read_failure() {
    let eof: io::Result<Option<String>> = Ok(None);
    assert_eq!(remote_reader_end_reason(&eof).as_deref(), Some("the daemon closed the connection"));

    let failure = Err(io::Error::new(io::ErrorKind::ConnectionReset, "peer reset"));
    assert_eq!(remote_reader_end_reason(&failure).as_deref(), Some("peer reset"));

    let message = Ok(Some("{}".to_string()));
    assert!(remote_reader_end_reason(&message).is_none());
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
fn json_reader_preserves_non_eof_read_errors() {
    struct FailingReader;

    impl Read for FailingReader {
        fn read(&mut self, _buffer: &mut [u8]) -> io::Result<usize> {
            Err(io::Error::new(io::ErrorKind::ConnectionReset, "peer reset"))
        }
    }

    let mut reader = BufReader::new(FailingReader);
    let result = read_json_line_with_progress(&mut reader, &mut |_| {});
    assert_eq!(result.as_ref().unwrap_err().to_string(), "peer reset");
    assert_eq!(remote_reader_end_reason(&result).as_deref(), Some("peer reset"));
}

#[test]
fn remote_terminal_dimensions_are_bounded_by_dimension_and_total_cells() {
    assert_eq!(remote_terminal_size(&json!({})), Some((80, 24)));
    assert_eq!(remote_terminal_size(&json!({"cols": 4096, "rows": 256})), Some((4096, 256)));
    for value in [
        json!({"cols": 0, "rows": 24}),
        json!({"cols": 65_535, "rows": 24}),
        json!({"cols": 4096, "rows": 257}),
        json!({"cols": -1, "rows": 24}),
        json!({"cols": "80", "rows": 24}),
    ] {
        assert_eq!(remote_terminal_size(&value), None, "accepted {value}");
    }
}

#[test]
fn provider_guard_state_changes_only_after_the_remote_acknowledges() {
    let session = crate::session::Session::Remote(acknowledging_provider_session());

    assert!(!session.workspaces_are_provider_managed());
    session.mark_workspaces_provider_managed().unwrap();
    assert!(session.workspaces_are_provider_managed());
}

#[test]
fn transport_disconnect_closes_the_transport_writer() {
    let closed = Arc::new(AtomicBool::new(false));
    let session = test_session(Box::new(CloseTrackingWriter { closed: closed.clone() }));

    session.disconnect_transport();

    assert!(session.shutdown.load(Ordering::Acquire));
    assert!(closed.load(Ordering::Acquire));
}

#[test]
fn transport_disconnect_reason_is_first_writer_wins() {
    let session =
        test_session(Box::new(CloseTrackingWriter { closed: Arc::new(AtomicBool::new(false)) }));

    session.disconnect_transport_with_reason(Some("the daemon closed the connection".into()));
    session.disconnect_transport_with_reason(Some("peer reset".into()));

    assert_eq!(
        session.transport_disconnect_reason().as_deref(),
        Some("the daemon closed the connection")
    );
}

#[test]
fn local_shutdown_does_not_preserve_reader_error() {
    let session =
        test_session(Box::new(CloseTrackingWriter { closed: Arc::new(AtomicBool::new(false)) }));

    session.disconnect_transport();
    session.disconnect_transport_with_reason(Some("peer reset".into()));

    assert_eq!(session.transport_disconnect_reason(), None);
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
