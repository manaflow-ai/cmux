//! Hosted surface side of the clipboard-read broker: a negotiated host's
//! `ClipboardReadRequest` becomes the surface's pending read, and the reply
//! goes back on the owner connection once.

use super::*;
use crate::terminal_host_protocol::{MAX_FRAME_PAYLOAD, read_frame, write_frame};
use ghostty_vt::{ClipboardLocation, ClipboardReadRequest};
use std::os::unix::net::UnixStream;

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

/// A host cancel that crosses the reply is stale: the surface keeps the
/// connection, sends no second reply, and takes the next read.
#[test]
fn a_cancel_after_the_reply_is_ignored() {
    let mux = Mux::new_for_test("hosted-clipboard-cancel", SurfaceOptions::default());
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
    let request = |host: &mut UnixStream, token: u64| {
        let mut payload = token.to_le_bytes().to_vec();
        payload.push(0);
        write_frame(host, &Frame::new(MessageKind::ClipboardReadRequest, payload)).unwrap();
    };
    let wait_pending = |token: u64| {
        let deadline = Instant::now() + Duration::from_secs(2);
        while surface.pending_clipboard_read().map(|read| read.token) != Some(token) {
            assert!(Instant::now() < deadline, "read {token} never reached the surface");
            std::thread::sleep(Duration::from_millis(1));
        }
    };
    let next_reply_token = |host: &mut UnixStream| loop {
        let frame = read_frame(host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
        if frame.kind == MessageKind::ClipboardReadReply {
            break u64::from_le_bytes(frame.payload[..8].try_into().unwrap());
        }
    };

    request(&mut host, 7);
    wait_pending(7);
    assert!(surface.complete_clipboard_read(7, Some(b"hi".to_vec())).unwrap());
    assert_eq!(next_reply_token(&mut host), 7);
    write_frame(
        &mut host,
        &Frame::new(MessageKind::ClipboardReadCancel, 7u64.to_le_bytes().to_vec()),
    )
    .unwrap();
    request(&mut host, 8);
    wait_pending(8);
    assert!(surface.complete_clipboard_read(8, None).unwrap());
    assert_eq!(next_reply_token(&mut host), 8, "no second reply for the cancelled read");
}
