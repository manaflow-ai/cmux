use std::os::fd::AsFd;
use std::os::unix::net::UnixStream;

use super::*;

fn pair() -> (UnixStream, UnixStream) {
    UnixStream::pair().expect("socketpair")
}

fn read_frame(reader: &mut FrameReader, socket: &UnixStream) -> Frame {
    loop {
        if let Some(frame) = reader.next_frame().expect("frame") {
            return frame;
        }
        assert!(reader.fill(socket.as_raw_fd()).expect("read") > 0, "end of stream");
    }
}

fn segment() -> OwnedFd {
    crate::shm::create_segment(4096).expect("segment")
}

#[test]
fn events_round_trip() {
    let (a, b) = pair();
    let events = [
        Event::Hello { version: WIRE_VERSION, sandbox: SandboxMechanism::Seatbelt, pid: 77 },
        Event::Parsed { id: 3, offset: 1 << 40, frame: 9 },
        Event::PtyWrite { id: 3, bytes: b"\x1b[?62;22c".to_vec() },
        Event::Title { id: 3, title: "vim — main.rs".to_owned() },
        Event::Pwd { id: 3, pwd: "file:///tmp".to_owned() },
        Event::Bell { id: 3, count: 2 },
        Event::Lapped { id: 3, from: 10, oldest: 20 },
        Event::PageTooSmall { id: 3, needed: 99_000 },
        Event::AttachFailed { id: 3, reason: AttachFailure::Ring },
    ];
    for event in &events {
        send_event(a.as_raw_fd(), event).expect("send");
    }
    let mut reader = FrameReader::default();
    for event in events {
        assert_eq!(decode_event(read_frame(&mut reader, &b)).expect("event"), event);
    }
}

#[test]
fn a_long_pty_answer_goes_in_frames_the_reader_accepts() {
    let (a, b) = pair();
    let bytes = vec![b'x'; MAX_EVENT_TEXT * 2 + 5];
    let writer = std::thread::spawn({
        let bytes = bytes.clone();
        move || send_event(a.as_raw_fd(), &Event::PtyWrite { id: 1, bytes }).expect("send")
    });
    let mut reader = FrameReader::default();
    let mut got = Vec::new();
    while got.len() < bytes.len() {
        match decode_event(read_frame(&mut reader, &b)).expect("event") {
            Event::PtyWrite { id: 1, bytes } => got.extend_from_slice(&bytes),
            other => panic!("unexpected {other:?}"),
        }
    }
    writer.join().expect("writer");
    assert_eq!(got, bytes);
}

#[test]
fn commands_round_trip_with_their_descriptors() {
    let (a, b) = pair();
    let geometry = Geometry { cols: 80, rows: 24, cell_width: 8, cell_height: 16 };
    send_command(a.as_raw_fd(), &Command::Bootstrap(SandboxPolicy::Seatbelt(vec![1, 2, 3])))
        .expect("bootstrap");
    send_command(
        a.as_raw_fd(),
        &Command::Attach(Attach {
            id: 5,
            start: 100,
            ring: segment(),
            ring_capacity: 1 << 20,
            page: segment(),
            page_len: 4096,
            scrollback: 10_000_000,
            geometry,
        }),
    )
    .expect("attach");
    send_command(a.as_raw_fd(), &Command::Advance { id: 5, end: 200 }).expect("advance");
    send_command(a.as_raw_fd(), &Command::Resize { id: 5, geometry, page: None }).expect("resize");
    send_command(
        a.as_raw_fd(),
        &Command::Resize { id: 5, geometry, page: Some((segment(), 8192)) },
    )
    .expect("resize with page");
    let mut colors = Colors {
        fg: Some(Rgb { r: 1, g: 2, b: 3 }),
        cursor_style: Some(CursorShape::Underline),
        cursor_blink: Some(false),
        ..Colors::default()
    };
    colors.palette[17] = Some(Rgb { r: 9, g: 8, b: 7 });
    send_command(a.as_raw_fd(), &Command::Colors { id: 5, colors: colors.clone() })
        .expect("colors");
    send_command(a.as_raw_fd(), &Command::Detach { id: 5 }).expect("detach");

    let mut reader = FrameReader::default();
    let mut next = || decode_command(read_frame(&mut reader, &b)).expect("command");
    assert!(
        matches!(next(), Command::Bootstrap(SandboxPolicy::Seatbelt(bytes)) if bytes == [1, 2, 3])
    );
    let Command::Attach(attach) = next() else { panic!("attach") };
    assert_eq!(
        (attach.id, attach.start, attach.ring_capacity, attach.page_len, attach.scrollback),
        (5, 100, 1 << 20, 4096, 10_000_000)
    );
    assert_eq!(attach.geometry, geometry);
    assert_ne!(attach.ring.as_fd().as_raw_fd(), attach.page.as_fd().as_raw_fd());
    assert!(matches!(next(), Command::Advance { id: 5, end: 200 }));
    assert!(matches!(next(), Command::Resize { id: 5, page: None, .. }));
    assert!(matches!(next(), Command::Resize { id: 5, page: Some((_, 8192)), .. }));
    assert!(matches!(next(), Command::Colors { id: 5, colors: got } if got == colors));
    assert!(matches!(next(), Command::Detach { id: 5 }));
}

#[test]
fn broken_frames_are_wire_errors() {
    let frame = |kind, payload: &[u8]| Frame { kind, payload: payload.to_vec(), fds: Vec::new() };
    assert_eq!(decode_command(frame(99, &[])).unwrap_err(), WireError::UnknownKind(99));
    assert_eq!(
        decode_command(frame(kind::ADVANCE, &[0; 17])).unwrap_err(),
        WireError::Trailing { kind: kind::ADVANCE }
    );
    assert_eq!(
        decode_command(frame(kind::ADVANCE, &[0; 3])).unwrap_err(),
        WireError::Truncated { kind: kind::ADVANCE }
    );
    assert!(matches!(
        decode_command(frame(kind::ATTACH, &[0; 48])).unwrap_err(),
        WireError::Descriptors { expected: 2, got: 0, .. }
    ));
    // An event kind is not a command, and a command kind is not an event.
    assert_eq!(
        decode_command(frame(kind::PARSED, &[0; 24])).unwrap_err(),
        WireError::UnknownKind(kind::PARSED)
    );
    assert_eq!(
        decode_event(frame(kind::ADVANCE, &[0; 16])).unwrap_err(),
        WireError::UnknownKind(kind::ADVANCE)
    );
    let mut title = 1u64.to_le_bytes().to_vec();
    title.push(0xff);
    assert_eq!(
        decode_event(frame(kind::TITLE, &title)).unwrap_err(),
        WireError::BadValue("text UTF-8")
    );

    let (a, b) = pair();
    let mut header = ((MAX_PAYLOAD + 1) as u32).to_le_bytes().to_vec();
    header.extend_from_slice(&[kind::ADVANCE, 0, 0, 0]);
    fds::send_all(a.as_raw_fd(), &header, &[]).expect("send");
    let mut reader = FrameReader::default();
    reader.fill(b.as_raw_fd()).expect("read");
    assert_eq!(reader.next_frame().unwrap_err(), WireError::PayloadTooLarge(MAX_PAYLOAD + 1));
}
