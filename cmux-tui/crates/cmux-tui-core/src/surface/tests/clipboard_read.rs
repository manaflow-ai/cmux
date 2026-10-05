//! Hosted surface side of the clipboard-read broker: a negotiated host's
//! `ClipboardReadRequest` becomes the surface's pending read, and the reply
//! goes back on the owner connection once.

use super::*;
use crate::terminal_host_protocol::{MAX_FRAME_PAYLOAD, read_frame, write_frame};
use ghostty_vt::{ClipboardLocation, ClipboardReadRequest};

#[test]
fn hosted_clipboard_read_is_pending_until_one_reply_is_sent() {
    let mux = Mux::new_for_test("hosted-clipboard-read", SurfaceOptions::default());
    let workspace = mux.create_empty_workspace(None, None, None).unwrap();
    let (mut attachment, mut host) = crate::terminal_host_runtime::input_ack_surface_fixture();
    attachment.negotiate_clipboard_reads_for_test();
    let terminal_id = attachment.record.terminal_id.clone();
    attachment.record.workspace_key = workspace.key.clone();
    mux.seed_launching_terminal_for_test(&terminal_id, &workspace.key).unwrap();
    let surface = Surface::spawn_hosted(
        1,
        SurfaceOptions::default(),
        Arc::downgrade(&mux),
        HostedSurfaceLaunch {
            attachment,
            kitty_reservation: None,
            terminate_on_error: false,
            defer_launch_activation: false,
            lifetime: PtyLifetime::SessionOwned,
            terminal_public_id: None,
            resource_identity: None,
        },
    )
    .unwrap();
    host.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    host.set_write_timeout(Some(Duration::from_secs(1))).unwrap();

    assert!(surface.clipboard_reads_negotiated());
    assert_eq!(surface.pending_clipboard_read(), None);
    assert!(!surface.complete_clipboard_read(7, None).unwrap(), "no read is pending");

    let mut payload = 7u64.to_le_bytes().to_vec();
    payload.push(2);
    write_frame(&mut host, &Frame::new(MessageKind::ClipboardReadRequest, payload)).unwrap();
    let expected = ClipboardReadRequest { token: 7, location: ClipboardLocation::Primary };
    let deadline = Instant::now() + Duration::from_secs(2);
    while surface.pending_clipboard_read() != Some(expected) {
        assert!(Instant::now() < deadline, "the request never reached the surface");
        std::thread::sleep(Duration::from_millis(1));
    }

    assert!(surface.complete_clipboard_read(7, Some(b"hi".to_vec())).unwrap());
    let reply = loop {
        let frame = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
        if frame.kind == MessageKind::ClipboardReadReply {
            break frame;
        }
    };
    assert_eq!((reply.request_id, reply.sequence, reply.flags), (0, 0, 0));
    let mut expected_payload = 7u64.to_le_bytes().to_vec();
    expected_payload.extend_from_slice(&[1, 2, 0, 0, 0, b'h', b'i']);
    assert_eq!(reply.payload, expected_payload);
    assert_eq!(surface.pending_clipboard_read(), None);
    assert!(!surface.complete_clipboard_read(7, None).unwrap(), "a read completes once");
}
