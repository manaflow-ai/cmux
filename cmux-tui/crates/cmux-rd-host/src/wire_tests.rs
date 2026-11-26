use super::*;
use cmux_rd_proto::{encode_stream_frame, StreamDeframer, STREAM_CONTROL, STREAM_DATAGRAM};
use std::net::TcpListener;
use std::time::{Duration, Instant};

/// The stream carrier bytes of `{"t":"stop"}` then a 3-byte datagram. The
/// same vector is pinned in cmux-rd-proto's tests/wire.rs, so the host's
/// framing and the viewer's (cmux-rd-ffi through cmux-rd-proto) cannot drift.
const GOLDEN: &[u8] = &[
    1, 12, 0, 0, 0, b'{', b'"', b't', b'"', b':', b'"', b's', b't', b'o', b'p', b'"', b'}', 2, 3,
    0, 0, 0, 7, 7, 7,
];

fn pair() -> (TcpStream, TcpStream) {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind");
    let client = TcpStream::connect(listener.local_addr().expect("addr")).expect("connect");
    let (server, _) = listener.accept().expect("accept");
    (client, server)
}

#[test]
fn host_writes_the_golden_bytes_and_proto_reads_them() {
    let (mut tx, mut rx) = pair();
    write_frame(&mut tx, FRAME_CONTROL, br#"{"t":"stop"}"#).expect("control");
    write_frame(&mut tx, FRAME_DATAGRAM, &[7, 7, 7]).expect("datagram");
    drop(tx);
    let mut bytes = Vec::new();
    rx.read_to_end(&mut bytes).expect("read");
    assert_eq!(bytes, GOLDEN);
    let mut d = StreamDeframer::default();
    d.extend(&bytes);
    assert_eq!(d.next_frame().expect("frame"), Some((STREAM_CONTROL, br#"{"t":"stop"}"#.to_vec())));
    assert_eq!(d.next_frame().expect("frame"), Some((STREAM_DATAGRAM, vec![7, 7, 7])));
    assert_eq!(d.next_frame().expect("end"), None);
}

#[test]
fn proto_writes_the_golden_bytes_and_the_host_reads_them() {
    let mut bytes = Vec::new();
    encode_stream_frame(STREAM_CONTROL, br#"{"t":"stop"}"#, &mut bytes).expect("control");
    encode_stream_frame(STREAM_DATAGRAM, &[7, 7, 7], &mut bytes).expect("datagram");
    assert_eq!(bytes, GOLDEN);
    let (mut tx, mut rx) = pair();
    tx.write_all(&bytes).expect("write");
    rx.set_nonblocking(true).expect("nonblocking");
    let mut reader = FrameReader::default();
    let mut frames = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    while frames.len() < 2 && Instant::now() < deadline {
        reader.fill(&mut rx).expect("fill");
        while let Some(frame) = reader.next().expect("next") {
            frames.push(frame);
        }
        // Test-only wait for loopback delivery.
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        frames,
        vec![(FRAME_CONTROL, br#"{"t":"stop"}"#.to_vec()), (FRAME_DATAGRAM, vec![7, 7, 7])]
    );
}
