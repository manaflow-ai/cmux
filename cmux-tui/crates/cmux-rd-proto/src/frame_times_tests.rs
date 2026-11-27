use super::*;

#[test]
fn frame_times_round_trip_through_a_datagram() {
    let t = FrameTimes {
        display_us: 1,
        encode_start_us: 2,
        encoded_us: 3,
        first_sent_us: 4,
        last_sent_us: 5,
    };
    let d = t.datagram(7, 42);
    let (h, payload) = DatagramHeader::decode(&d).expect("header");
    assert_eq!((h.kind, h.stream, h.frame), (DatagramKind::FrameTimes, 7, 42));
    assert_eq!(FrameTimes::decode(payload).expect("payload"), t);
    assert!(FrameTimes::decode(&payload[..39]).is_err());
}
