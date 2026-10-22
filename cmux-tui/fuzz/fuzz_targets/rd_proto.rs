//! Remote desktop protocol bytes from a peer: datagram headers and the
//! bodies they carry, the stream deframer (chunked) and the JSON control
//! messages.
#![no_main]

use cmux_rd_proto::control::Control;
use cmux_rd_proto::{
    BulkFrame, ClockPing, ClockPong, DatagramHeader, Feedback, FrameBody, InputPacket,
    StreamDeframer,
};
use libfuzzer_sys::fuzz_target;

fn bodies(bytes: &[u8]) {
    let _ = FrameBody::decode(bytes);
    let _ = InputPacket::decode(bytes);
    let _ = ClockPing::decode(bytes);
    let _ = ClockPong::decode(bytes);
    let _ = BulkFrame::decode(bytes);
    let _ = Feedback::decode(bytes);
    let _ = serde_json::from_slice::<Control>(bytes);
}

fuzz_target!(|data: &[u8]| {
    if let Ok((_, payload)) = DatagramHeader::decode(data) {
        bodies(payload);
    }
    bodies(data);
    let Some((&shape, stream)) = data.split_first() else { return };
    let mut deframer = StreamDeframer::default();
    for piece in stream.chunks(1 + usize::from(shape)) {
        deframer.extend(piece);
        loop {
            match deframer.next_frame() {
                Ok(Some((_, frame))) => bodies(&frame),
                Ok(None) | Err(_) => break,
            }
        }
    }
});
