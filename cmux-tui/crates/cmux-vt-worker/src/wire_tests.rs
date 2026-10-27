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
    shm::create_segment(4096).expect("segment")
}

const LIMITS: KittyGraphicsLimits =
    KittyGraphicsLimits { image_bytes: 4096, inflight_bytes: 8192, images: 3, placements: 7 };

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
        Event::ProgramStatus { id: 3, event: ProgramStatusEvent::PromptStart },
        Event::ProgramStatus {
            id: 3,
            event: ProgramStatusEvent::Report(ProgramStatusReport {
                state: ProgramStatusState::Blocked,
                kind: Some(ProgramStatusKind::Question),
                progress: Some(40),
                id: "a/b".to_owned(),
                app: "terraform".to_owned(),
                title: "Plan".to_owned(),
                message: "Apply?".to_owned(),
            }),
        },
        Event::ProgramStatus {
            id: 3,
            event: ProgramStatusEvent::Report(ProgramStatusReport {
                state: ProgramStatusState::Clear,
                kind: None,
                progress: None,
                id: String::new(),
                app: String::new(),
                title: String::new(),
                message: String::new(),
            }),
        },
        Event::KittyMediaRequest {
            id: 3,
            request: MediaRequest {
                medium: FileMedium::TempFile,
                name: b"L3RtcC90dHktZ3JhcGhpY3MtcHJvdG9jb2w=".to_vec(),
                offset: 7,
                size: 99,
            },
        },
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
            kitty_limits: LIMITS,
        }),
    )
    .expect("attach");
    send_command(
        a.as_raw_fd(),
        &Command::KittyLimits { id: 5, limits: KittyGraphicsLimits::disabled() },
    )
    .expect("kitty limits");
    let answer = MediaAnswer::from_read(Ok(b"image bytes".to_vec())).expect("segment");
    send_command(a.as_raw_fd(), &Command::KittyMedia { id: 5, answer }).expect("kitty media");
    let answer = MediaAnswer::from_read(Ok(Vec::new())).expect("no segment");
    send_command(a.as_raw_fd(), &Command::KittyMedia { id: 5, answer }).expect("empty media");
    let answer = MediaAnswer::Refused(MediaRefusal::NotTemporary);
    send_command(a.as_raw_fd(), &Command::KittyMedia { id: 5, answer }).expect("refusal");
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
    assert_eq!(attach.kitty_limits, LIMITS);
    assert_ne!(attach.ring.as_fd().as_raw_fd(), attach.page.as_fd().as_raw_fd());
    assert!(matches!(
        next(),
        Command::KittyLimits { id: 5, limits } if limits == KittyGraphicsLimits::disabled()
    ));
    let Command::KittyMedia { id: 5, answer } = next() else { panic!("kitty media") };
    assert_eq!(answer.into_read(), Ok(b"image bytes".to_vec()));
    let Command::KittyMedia { id: 5, answer } = next() else { panic!("empty media") };
    assert!(matches!(answer, MediaAnswer::Bytes { segment: None, len: 0 }));
    let Command::KittyMedia { id: 5, answer } = next() else { panic!("refusal") };
    assert_eq!(answer.into_read(), Err(MediaRefusal::NotTemporary));
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

    // Kitty limits past ghostty-vt's per-terminal maximum.
    let mut limits = 5u64.to_le_bytes().to_vec();
    for value in [u64::MAX, 0, 0, 0] {
        limits.extend_from_slice(&value.to_le_bytes());
    }
    assert_eq!(
        decode_command(frame(kind::KITTY_LIMITS, &limits)).unwrap_err(),
        WireError::BadValue("kitty limits")
    );
    // A media answer longer than the rewriter's cap, or a refusal with bytes.
    let media = |outcome: u8, len: u64| {
        let mut payload = 5u64.to_le_bytes().to_vec();
        payload.push(outcome);
        payload.extend_from_slice(&len.to_le_bytes());
        payload
    };
    assert_eq!(
        decode_command(frame(kind::KITTY_MEDIA, &media(0, MAX_MEDIA_BYTES + 1))).unwrap_err(),
        WireError::BadValue("kitty media length")
    );
    assert_eq!(
        decode_command(frame(kind::KITTY_MEDIA, &media(3, 1))).unwrap_err(),
        WireError::BadValue("kitty media refusal length")
    );
    assert_eq!(
        decode_command(frame(kind::KITTY_MEDIA, &media(200, 0))).unwrap_err(),
        WireError::BadValue("kitty media refusal")
    );
    // Program status: a bad state, progress past 100, text past the bound.
    let status = |state: u8, progress: u8, text_len: u16| {
        let mut payload = 1u64.to_le_bytes().to_vec();
        payload.extend_from_slice(&[1, state, 0, progress]);
        payload.extend_from_slice(&text_len.to_le_bytes());
        payload.extend(std::iter::repeat_n(b'x', usize::from(text_len)));
        for _ in 0..3 {
            payload.extend_from_slice(&0u16.to_le_bytes());
        }
        payload
    };
    assert!(decode_event(frame(kind::PROGRAM_STATUS, &status(1, 40, 3))).is_ok());
    assert_eq!(
        decode_event(frame(kind::PROGRAM_STATUS, &status(9, 40, 3))).unwrap_err(),
        WireError::BadValue("status state")
    );
    assert_eq!(
        decode_event(frame(kind::PROGRAM_STATUS, &status(1, 101, 3))).unwrap_err(),
        WireError::BadValue("status progress")
    );
    assert_eq!(
        decode_event(frame(kind::PROGRAM_STATUS, &status(1, 40, MAX_STATUS_TEXT as u16 + 1)))
            .unwrap_err(),
        WireError::BadValue("status text length")
    );
    // A Kitty request with an unknown medium or a name past the held bound.
    let request = |medium: u8, name_len: usize| {
        let mut payload = 1u64.to_le_bytes().to_vec();
        payload.push(medium);
        payload.extend_from_slice(&[0; 16]);
        payload.extend(std::iter::repeat_n(b'A', name_len));
        payload
    };
    assert!(decode_event(frame(kind::KITTY_MEDIA_REQUEST, &request(1, 8))).is_ok());
    assert_eq!(
        decode_event(frame(kind::KITTY_MEDIA_REQUEST, &request(4, 8))).unwrap_err(),
        WireError::BadValue("kitty medium")
    );
    assert_eq!(
        decode_event(frame(kind::KITTY_MEDIA_REQUEST, &request(1, MAX_MEDIA_NAME + 1)))
            .unwrap_err(),
        WireError::BadValue("kitty media name length")
    );

    let (a, b) = pair();
    let mut header = ((MAX_PAYLOAD + 1) as u32).to_le_bytes().to_vec();
    header.extend_from_slice(&[kind::ADVANCE, 0, 0, 0]);
    fds::send_all(a.as_raw_fd(), &header, &[]).expect("send");
    let mut reader = FrameReader::default();
    reader.fill(b.as_raw_fd()).expect("read");
    assert_eq!(reader.next_frame().unwrap_err(), WireError::PayloadTooLarge(MAX_PAYLOAD + 1));
}
