//! Transport framing, readers and writers, initialization, and disconnect.

use super::*;

#[test]
fn local_shutdown_does_not_preserve_reader_error() {
    let session =
        test_session(Box::new(CloseTrackingWriter { closed: Arc::new(AtomicBool::new(false)) }));

    session.disconnect_transport();
    session.disconnect_transport_with_reason(Some("peer reset".into()));

    assert_eq!(session.transport_disconnect_reason(), None);
}
