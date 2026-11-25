//! Control waits (termination, Kitty quota adoption) on a host that closed
//! its link before the daemon set or restored the link's read timeout.

use super::*;

#[test]
fn termination_reads_the_exit_of_a_host_that_already_closed_its_link() {
    let (mut attachment, mut host) = input_ack_surface_fixture();
    let exit = TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 17 },
        exited_at_ms: 1,
    };
    // The host queues its exit and closes its sending direction. The legacy
    // Terminate then closes the daemon's sending direction. Both directions
    // of the link are now shut down, as after the host process ended: macOS
    // refuses SO_RCVTIMEO on that socket with EINVAL.
    write_frame(&mut host, &Frame::new(MessageKind::Exit, encode_terminal_exit(&exit))).unwrap();
    host.shutdown(std::net::Shutdown::Write).unwrap();

    let record = attachment
        .terminate_and_wait_for_exit()
        .expect("a host that closed its link after its exit frame still reports its exit");

    assert_eq!(record, TerminalHostExitRecord::new(&attachment.identity(), exit));
    let request = read_required_frame(&mut host, "terminate request").unwrap();
    assert_eq!(request.kind, MessageKind::Terminate);
}

#[test]
fn kitty_quota_adoption_reads_the_ack_of_a_host_that_already_closed_its_link() {
    let (mut attachment, _unused_host) = input_ack_surface_fixture();
    // The request goes out on a link that stays open; the reader link is a
    // separate socket whose host queued its acknowledgement and then closed,
    // as a host that ended right after it applied the limits. macOS refuses
    // SO_RCVTIMEO on that reader socket with EINVAL.
    let (request_link, mut request_peer) = UnixStream::pair().unwrap();
    let (reader_link, mut closed_host) = UnixStream::pair().unwrap();
    let limits = KittyGraphicsLimits {
        image_bytes: 4_000,
        inflight_bytes: 4_000,
        images: 40,
        placements: 80,
    };
    let mut payload = Vec::new();
    encode_kitty_graphics_limits(&mut payload, limits).unwrap();
    let mut ack = Frame::new(MessageKind::KittyGraphicsLimitsAck, payload);
    ack.request_id = attachment.next_request.load(Ordering::Relaxed);
    write_frame(&mut closed_host, &ack).unwrap();
    drop(closed_host);
    attachment.writer = Arc::new(Mutex::new(request_link));
    attachment.reader = Some(reader_link);

    attachment
        .reconfigure_kitty_graphics_for_adoption(limits)
        .expect("a host that closed its link after its acknowledgement still applied the limits");

    let request = read_required_frame(&mut request_peer, "Kitty limits request").unwrap();
    assert_eq!(request.kind, MessageKind::SetKittyGraphicsLimits);
    assert_eq!(request.request_id, ack.request_id);
}
