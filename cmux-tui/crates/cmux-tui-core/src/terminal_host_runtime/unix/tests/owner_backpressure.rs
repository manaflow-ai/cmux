//! The daemon's own mirror backpressures the PTY reader instead of being cut
//! off 8 MiB behind (terminal-throughput cut 1, CMUX-571); every other client
//! keeps the cutoff.

use super::*;

fn tap_pair(backpressure: bool) -> (HostTap, Receiver<Arc<Frame>>, UnixStream) {
    let (host_socket, client_socket) = UnixStream::pair().unwrap();
    let (sender, receiver) = mpsc_channel();
    let tap = HostTap::new(sender, Arc::new(host_socket), MAX_HOST_CLIENT_QUEUED_BYTES);
    let tap = if backpressure { tap.with_backpressure() } else { tap };
    (tap, receiver, client_socket)
}

fn fill_output_queue(tap: &HostTap) {
    let frame = MAX_HOST_CLIENT_OUTPUT_QUEUED_BYTES - crate::terminal_host_protocol::HEADER_LEN;
    assert!(tap.try_send(Frame::new(MessageKind::Output, vec![b'x'; frame])));
}

#[test]
fn a_full_mirror_holds_the_reader_until_its_writer_frees_room() {
    let smart = Arc::new(SmartStreamState::new());
    let (tap, receiver, _client) = tap_pair(true);
    fill_output_queue(&tap);
    smart.taps.lock().unwrap().insert(1, tap.clone());

    let writer = thread::spawn(move || {
        thread::sleep(Duration::from_millis(100));
        let frame = receiver.recv().unwrap();
        tap.release(&frame);
        receiver
    });
    let started = Instant::now();
    smart.wait_for_owner_room_until(1024, Instant::now() + Duration::from_secs(10));
    let waited = started.elapsed();
    assert!(waited >= Duration::from_millis(90), "the reader did not wait: {waited:?}");
    assert!(waited < Duration::from_secs(5), "the release did not wake the reader: {waited:?}");
    let _receiver = writer.join().unwrap();
    // The room it waited for is there: the next Output is admitted, not cut off.
    let tap = smart.taps.lock().unwrap().get(&1).cloned().unwrap();
    assert!(tap.try_send(Frame::new(MessageKind::Output, vec![b'y'; 1024])));
}

#[test]
fn a_full_foreign_client_never_holds_the_reader_and_is_still_cut_off() {
    let smart = SmartStreamState::new();
    let (tap, _receiver, mut client) = tap_pair(false);
    fill_output_queue(&tap);
    smart.taps.lock().unwrap().insert(1, tap);

    let started = Instant::now();
    smart.wait_for_owner_room_until(1024, Instant::now() + Duration::from_secs(10));
    assert!(started.elapsed() < Duration::from_secs(1));
    smart.publish(Frame::new(MessageKind::Output, vec![b'y'; 1024]));
    assert!(smart.taps.lock().unwrap().is_empty(), "the full foreign client stayed subscribed");
    client.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    let mut rest = Vec::new();
    let _ = client.read_to_end(&mut rest);
}

#[test]
fn a_stuck_mirror_holds_the_reader_only_until_the_deadline_then_is_cut_off() {
    let smart = SmartStreamState::new();
    let (tap, _receiver, _client) = tap_pair(true);
    fill_output_queue(&tap);
    smart.taps.lock().unwrap().insert(1, tap);

    let started = Instant::now();
    smart.wait_for_owner_room_until(1024, Instant::now() + Duration::from_millis(50));
    let waited = started.elapsed();
    assert!(waited >= Duration::from_millis(45) && waited < Duration::from_secs(5), "{waited:?}");
    smart.publish(Frame::new(MessageKind::Output, vec![b'y'; 1024]));
    assert!(smart.taps.lock().unwrap().is_empty(), "the stuck mirror was not cut off");
}

#[test]
fn a_mirror_that_leaves_ends_the_wait() {
    let smart = Arc::new(SmartStreamState::new());
    let (tap, _receiver, _client) = tap_pair(true);
    fill_output_queue(&tap);
    smart.taps.lock().unwrap().insert(1, tap);

    let leaver = smart.clone();
    let leave = thread::spawn(move || {
        thread::sleep(Duration::from_millis(50));
        leaver.remove(1);
    });
    let started = Instant::now();
    smart.wait_for_owner_room_until(1024, Instant::now() + Duration::from_secs(10));
    assert!(started.elapsed() < Duration::from_secs(5));
    leave.join().unwrap();
}

#[test]
fn only_the_surface_owner_connection_backpressures() {
    for (rights, backpressure) in [
        (CapabilityRights::ADMIN | CapabilityRights::CLIPBOARD_READ, true),
        (CapabilityRights::ADMIN, false),
    ] {
        let host = exited_host_fixture();
        let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
        client_stream.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
        let server_host = host.clone();
        let server = thread::spawn(move || serve_client(server_host, server_stream));
        let mut hello = ClientHello {
            min_version: PROTOCOL_VERSION,
            max_version: PROTOCOL_VERSION,
            role: ClientRole::Admin,
            requested_rights: rights,
            terminal_id: host.terminal_id,
            token: host.owner_token,
        }
        .into_frame(1);
        hello.flags = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS;
        write_frame(&mut client_stream, &hello).unwrap();
        for kind in
            [MessageKind::HostHello, MessageKind::Snapshot, MessageKind::Colors, MessageKind::Ready]
        {
            assert_eq!(read_required_frame(&mut client_stream, "handshake").unwrap().kind, kind);
        }
        let taps = host.smart.taps.lock().unwrap();
        assert_eq!(taps.len(), 1);
        assert_eq!(taps.values().next().unwrap().room.is_some(), backpressure, "{rights:?}");
        drop(taps);
        drop(client_stream);
        let _ = server.join().unwrap();
    }
}
