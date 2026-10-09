//! Clear-history requests and their capability gates.

use super::*;

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
