//! Clear-history requests and their capability gates.

use super::*;

#[test]
fn clear_history_shortcut_requires_active_surface_support() {
    let session = test_session_with_provider_context(
        Box::new(UnexpectedWriteWriter),
        HashSet::from([
            CLEAR_HISTORY_CAPABILITY.to_string(),
            CLEAR_HISTORY_KEY_CAPABILITY.to_string(),
        ]),
        None,
    );
    session.tree.lock().unwrap().replace(
        parse_tree(&json!({
            "workspaces": [{
                "id": 1,
                "active": true,
                "screens": [{
                    "id": 2,
                    "active": true,
                    "active_pane": 3,
                    "layout": {"type": "leaf", "pane": 3},
                    "panes": [{
                        "id": 3,
                        "active_tab": 0,
                        "tabs": [
                            {
                                "surface": 7,
                                "supports_clear_history_key_fallback": false
                            },
                            {
                                "surface": 8,
                                "supports_clear_history_key_fallback": true
                            }
                        ]
                    }]
                }]
            }]
        })),
        0,
    );

    assert!(!session.supports_clear_history_key_fallback(7));
    assert!(session.supports_clear_history_key_fallback(8));
    assert!(!session.supports_clear_history_key_fallback(9));
}

#[test]
fn older_remote_server_reports_unencodable_command_shortcut() {
    let session_slot = Arc::new(Mutex::new(None));
    let requests = Arc::new(Mutex::new(Vec::new()));
    let session = test_session(Box::new(RecordingAcknowledgingWriter {
        session: session_slot.clone(),
        requests: requests.clone(),
    }));
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
    session.surfaces.lock().unwrap().insert(7, test_remote_pty_surface(7, 80, 24, (8, 16)));
    let fallback = KeyInput {
        key: ghostty_vt::sys::GHOSTTY_KEY_K,
        mods: Mods::SUPER,
        unshifted_codepoint: 'k' as u32,
        action: Some(KeyAction::Press),
        ..Default::default()
    };

    assert!(session.clear_history_or_send_key_classified(7, &fallback).is_err());
    assert!(requests.lock().unwrap().is_empty());
}

#[test]
fn intermediate_remote_server_keeps_plain_clear_but_rejects_shortcut() {
    let session_slot = Arc::new(Mutex::new(None));
    let requests = Arc::new(Mutex::new(Vec::new()));
    let session = test_session_with_provider_context(
        Box::new(RecordingAcknowledgingWriter {
            session: session_slot.clone(),
            requests: requests.clone(),
        }),
        HashSet::from([CLEAR_HISTORY_CAPABILITY.to_string()]),
        None,
    );
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
    session.clear_history_classified(7).unwrap();

    let recorded = requests.lock().unwrap();
    assert_eq!(recorded.len(), 1);
    assert_eq!(recorded[0]["cmd"], "clear-history");
    assert_eq!(recorded[0]["surface"], 7);
    assert_eq!(recorded[0]["fallback_key"], Value::Null);
}

#[test]
fn clear_history_transport_failure_is_ambiguous() {
    struct FailingWriter;

    impl RemoteMessageWriter for FailingWriter {
        fn send(&mut self, _message: &str) -> io::Result<()> {
            Err(io::Error::new(io::ErrorKind::BrokenPipe, "socket closed"))
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    let session = test_session_with_provider_context(
        Box::new(FailingWriter),
        HashSet::from([CLEAR_HISTORY_CAPABILITY.to_string()]),
        None,
    );

    let failure = session.clear_history_classified(7).unwrap_err();

    assert_eq!(failure.delivery(), ClearHistoryDelivery::Ambiguous);
}

#[test]
fn clear_history_rejection_preserves_known_not_delivered_delivery() {
    struct RejectingWriter {
        session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    }

    impl RemoteMessageWriter for RejectingWriter {
        fn send(&mut self, message: &str) -> io::Result<()> {
            let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
            let id = request
                .get("id")
                .and_then(Value::as_u64)
                .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
            let session = self
                .session
                .lock()
                .unwrap()
                .as_ref()
                .and_then(Weak::upgrade)
                .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
            let response = session
                .pending
                .lock()
                .unwrap()
                .remove(&id)
                .ok_or_else(|| io::Error::other("remote request was not pending"))?;
            response
                .response
                .send(json!({
                    "id": id,
                    "ok": false,
                    "error": "active terminal input extends into retained history",
                    "error_delivery": "known-not-delivered",
                }))
                .map_err(|_| io::Error::other("remote response receiver was dropped"))
        }

        fn close(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    let session_slot = Arc::new(Mutex::new(None));
    let session = test_session_with_provider_context(
        Box::new(RejectingWriter { session: session_slot.clone() }),
        HashSet::from([CLEAR_HISTORY_CAPABILITY.to_string()]),
        None,
    );
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));

    let failure = session.clear_history_classified(7).unwrap_err();

    assert_eq!(failure.delivery(), ClearHistoryDelivery::KnownNotDelivered);
}
