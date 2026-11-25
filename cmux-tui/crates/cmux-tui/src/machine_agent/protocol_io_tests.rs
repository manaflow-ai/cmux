use std::io::{BufReader, Cursor};

use cmux_tui_machine_agent_protocol::{Heartbeat, Message};

use super::*;

#[test]
fn bounded_reader_rejects_oversized_truncated_and_malformed_frames() {
    let oversized = vec![b'x'; MAX_FRAME_BYTES + 1];
    assert!(matches!(
        read_frame(&mut BufReader::new(Cursor::new(oversized))),
        Err(FrameReadError::TooLarge)
    ));
    assert!(matches!(
        read_frame(&mut BufReader::new(Cursor::new(b"{".to_vec()))),
        Err(FrameReadError::Truncated)
    ));
    assert!(matches!(
        read_frame(&mut BufReader::new(Cursor::new(b"{}\n".to_vec()))),
        Err(FrameReadError::Invalid(_))
    ));

    let mut wire = Vec::new();
    let expected = Envelope::new(Message::Ping(Heartbeat { nonce: 7 }));
    write_frame(&mut wire, &expected).unwrap();
    assert_eq!(read_frame(&mut BufReader::new(Cursor::new(wire))).unwrap(), expected);
}
