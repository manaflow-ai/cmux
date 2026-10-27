//! Wire framing and query stripping: malformed or oversized input is an
//! error or passes through, never a panic.

use cmux_mux2::{self as proto, QueryStripper};

#[test]
fn a_frame_round_trips_and_partial_frames_wait() {
    let mut out = Vec::new();
    proto::put_frame(&mut out, proto::OUTPUT, b"hello").expect("small frame");
    for cut in 0..out.len() {
        assert_eq!(proto::take_frame(&out[..cut]).expect("partial frame"), None, "cut {cut}");
    }
    let (kind, payload, used) = proto::take_frame(&out).expect("whole frame").expect("complete");
    assert_eq!((kind, payload, used), (proto::OUTPUT, &b"hello"[..], out.len()));
    let (kind, payload) = proto::read_frame(&mut out.as_slice()).expect("read");
    assert_eq!((kind, payload.as_slice()), (proto::OUTPUT, &b"hello"[..]));
}

#[test]
fn bad_lengths_are_errors() {
    // Zero length (no kind byte) and a length over MAX_FRAME.
    let zero = [0, 0, 0, 0, proto::OK];
    assert!(proto::take_frame(&zero).is_err());
    assert!(proto::read_frame(&mut zero.as_slice()).is_err());
    let huge = u32::try_from(proto::MAX_FRAME + 1).expect("fits").to_le_bytes();
    let over = [huge[0], huge[1], huge[2], huge[3], proto::OK];
    assert!(proto::take_frame(&over).is_err());
}

#[test]
fn a_frame_the_peer_would_refuse_is_not_written() {
    let payload = vec![0u8; proto::MAX_FRAME];
    let mut out = Vec::new();
    let err = proto::put_frame(&mut out, proto::OUTPUT, &payload).expect_err("over MAX_FRAME");
    assert_eq!(err.kind(), std::io::ErrorKind::InvalidInput);
    assert!(out.is_empty());
    // The largest frame the reader accepts still goes out.
    proto::put_frame(&mut out, proto::OUTPUT, &payload[1..]).expect("MAX_FRAME exactly");
}

#[test]
fn create_payload_refuses_too_many_arguments() {
    let arg: &[u8] = b"x";
    let argv = vec![arg; usize::from(u16::MAX) + 1];
    let err = proto::create_payload(80, 24, b"", &argv).expect_err("argc over u16");
    assert_eq!(err.kind(), std::io::ErrorKind::InvalidInput);
    let p = proto::create_payload(80, 24, b"/tmp", &argv[..2]).expect("two arguments");
    let mut r = proto::Reader(&p);
    assert_eq!((r.u16(), r.u16()), (Some(80), Some(24)));
    assert_eq!(r.bytes(), Some(&b"/tmp"[..]));
    assert_eq!(r.u16(), Some(2));
}

fn strip(input: &[u8]) -> Vec<u8> {
    let mut stripper = QueryStripper::default();
    let mut out = Vec::new();
    stripper.push(input, &mut out);
    out
}

#[test]
fn queries_are_stripped_and_other_sequences_pass() {
    assert_eq!(strip(b"a\x1b[cb"), b"ab"); // DA1
    assert_eq!(strip(b"\x1b[1mx"), b"\x1b[1mx"); // SGR
    assert_eq!(strip(b"\x1b]11;?\x07z"), b"z"); // OSC color query, BEL
    assert_eq!(strip(b"\x1b]11;?\x1b\\z"), b"z"); // OSC color query, ST
    assert_eq!(strip(b"\x1bP+q544e\x1b\\"), b""); // XTGETTCAP
    // The shortest strings: nothing between the introducer and the terminator.
    assert_eq!(strip(b"\x1b]\x07"), b"\x1b]\x07");
    assert_eq!(strip(b"\x1b]\x1b\\"), b"\x1b]\x1b\\");
}

#[test]
fn short_reply_and_exit_bodies_are_none_not_panics() {
    for short in [&b""[..], b"\x01", b"\x01\x02\x03"] {
        assert_eq!(proto::exit_status(short), None, "{short:?}");
        assert_eq!(proto::created_id(short), None, "{short:?}");
    }
    assert_eq!(proto::exit_status(&(-1i32).to_le_bytes()), Some(-1));
    assert_eq!(proto::exit_status(&[7, 0, 0, 0, 9]), Some(7));
    assert_eq!(proto::created_id(&42u32.to_le_bytes()), Some(42));
}
