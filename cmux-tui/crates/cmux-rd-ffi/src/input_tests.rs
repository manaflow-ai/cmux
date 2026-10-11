//! The input channel through the C ABI: packets the host applies exactly once,
//! resends on the timer, both carriers, refusal of bad events, buffer reuse.

use super::*;
use cmux_rd_core::input::InputApplier;
use cmux_rd_proto::{
    DatagramHeader, DatagramKind, HEADER_LEN, InputEvent, InputPacket, MAX_DATAGRAM_VPC,
    STREAM_DATAGRAM, StreamDeframer,
};

const RESEND_US: u64 = 20_000;

struct Owned(*mut CmuxRdInput);
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: created by cmux_rd_input_new and freed once here.
        unsafe { cmux_rd_input_free(self.0) };
    }
}

fn input(carrier: u32) -> Owned {
    let h = cmux_rd_input_new(carrier, RESEND_US);
    assert!(!h.is_null());
    Owned(h)
}

fn blank(kind: u32) -> CmuxRdInputEvent {
    CmuxRdInputEvent {
        kind,
        usage: 0,
        x: 0,
        y: 0,
        dx: 0,
        dy: 0,
        text: std::ptr::null(),
        text_len: 0,
        button: 0,
        down: 0,
        precise: 0,
        service_flags: 0,
    }
}

fn key(usage: u32, down: bool) -> CmuxRdInputEvent {
    CmuxRdInputEvent { usage, down: u8::from(down), ..blank(CMUX_RD_INPUT_KEY) }
}

fn push(h: &Owned, e: &CmuxRdInputEvent) -> (i32, u32) {
    let mut seq = 0;
    // SAFETY: live handle, readable event, writable seq.
    let rc = unsafe { cmux_rd_input_push(h.0, e, &mut seq) };
    (rc, seq)
}

fn push_text(h: &Owned, bytes: &[u8]) -> i32 {
    let e = CmuxRdInputEvent {
        text: bytes.as_ptr(),
        text_len: bytes.len(),
        ..blank(CMUX_RD_INPUT_TEXT)
    };
    push(h, &e).0
}

/// Every packet due at `now`.
fn packets(h: &Owned, now: u64) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    loop {
        let mut buf = [0u8; CMUX_RD_INPUT_PACKET_MAX];
        let mut len = 0;
        // SAFETY: live handle, writable buffer and length.
        let rc = unsafe { cmux_rd_input_packet(h.0, now, buf.as_mut_ptr(), buf.len(), &mut len) };
        assert!(rc >= 0, "packet rc {rc}");
        if rc == 0 {
            return out;
        }
        out.push(buf[..len].to_vec());
    }
}

fn decode(datagram: &[u8]) -> InputPacket {
    let (h, payload) = DatagramHeader::decode(datagram).expect("header");
    assert_eq!(h.kind, DatagramKind::Input);
    assert!(datagram.len() <= MAX_DATAGRAM_VPC);
    InputPacket::decode(payload).expect("input packet")
}

fn ack_datagram(applied: u32) -> Vec<u8> {
    let mut d = Vec::with_capacity(HEADER_LEN + 4);
    DatagramHeader {
        flags: 0,
        kind: DatagramKind::InputAck,
        stream: 0,
        frame: 0,
        index: 0,
        count: 0,
        fec_count: 0,
        transport_seq: 0,
    }
    .encode_into(&mut d);
    d.extend_from_slice(&applied.to_le_bytes());
    d
}

fn ack(h: &Owned, d: &[u8]) -> i32 {
    // SAFETY: live handle, readable slice.
    unsafe { cmux_rd_input_ack(h.0, d.as_ptr(), d.len()) }
}

fn deadline(h: &Owned) -> u64 {
    // SAFETY: live handle.
    unsafe { cmux_rd_input_next_deadline_us(h.0) }
}

#[test]
fn events_reach_the_host_once_and_in_order() {
    let h = input(CMUX_RD_CARRIER_DATAGRAM);
    assert_eq!(deadline(&h), u64::MAX);
    assert_eq!(push(&h, &key(0x0007_0004, true)), (CMUX_RD_OK, 1));
    let pointer = CmuxRdInputEvent { x: 640, y: -3, ..blank(CMUX_RD_INPUT_POINTER) };
    assert_eq!(push(&h, &pointer), (CMUX_RD_OK, 2));
    assert_eq!(push_text(&h, "é!".as_bytes()), CMUX_RD_OK);
    assert_eq!(push(&h, &key(0x0007_0004, false)).1, 4);
    assert_eq!(deadline(&h), 0);

    let mut host = InputApplier::new(200_000);
    let sent = packets(&h, 1_000);
    assert_eq!(sent.len(), 1);
    let applied = host.accept(&decode(&sent[0]), 1_000);
    assert_eq!(
        applied,
        vec![
            InputEvent::Key { usage: 0x0007_0004, down: true },
            InputEvent::Pointer { x: 640, y: -3 },
            InputEvent::Text("é!".into()),
            InputEvent::Key { usage: 0x0007_0004, down: false },
        ]
    );
    // Nothing new: the next packet waits for the resend timer.
    assert_eq!(deadline(&h), 1_000 + RESEND_US);
    assert!(packets(&h, 1_000 + RESEND_US - 1).is_empty());
    // A repeat is not applied twice.
    let again = packets(&h, 1_000 + RESEND_US);
    assert_eq!(again.len(), 1);
    assert!(host.accept(&decode(&again[0]), 30_000).is_empty());
    assert_eq!(ack(&h, &ack_datagram(host.applied())), CMUX_RD_OK);
    assert!(packets(&h, 1_000_000).is_empty());
    assert_eq!(deadline(&h), u64::MAX);
}

#[test]
fn a_lost_release_is_resent_until_acknowledged() {
    let h = input(CMUX_RD_CARRIER_DATAGRAM);
    push(&h, &key(0x0007_0029, false));
    let mut now = 0;
    for _ in 0..10 {
        let sent = packets(&h, now);
        assert_eq!(sent.len(), 1, "release goes out at {now}");
        now += RESEND_US;
    }
    assert_eq!(ack(&h, &ack_datagram(1)), CMUX_RD_OK);
    assert!(packets(&h, now).is_empty());
}

#[test]
fn every_event_arrives_through_heavy_loss() {
    let h = input(CMUX_RD_CARRIER_DATAGRAM);
    let mut host = InputApplier::new(1_000_000);
    let mut applied = Vec::new();
    let mut now = 0u64;
    let mut n = 0u64;
    for usage in 0..40u32 {
        push(&h, &key(usage, true));
        push(&h, &key(usage, false));
        for _ in 0..6 {
            for d in packets(&h, now) {
                n += 1;
                // Two of every three datagrams are lost.
                if n.is_multiple_of(3) {
                    applied.extend(host.accept(&decode(&d), now));
                    ack(&h, &ack_datagram(host.applied()));
                }
            }
            now += RESEND_US;
        }
    }
    while deadline(&h) != u64::MAX {
        for d in packets(&h, now) {
            applied.extend(host.accept(&decode(&d), now));
            ack(&h, &ack_datagram(host.applied()));
        }
        now += RESEND_US;
    }
    // Releases are never lost; presses may be skipped after three sends.
    let releases: Vec<u32> = applied
        .iter()
        .filter_map(|e| match e {
            InputEvent::Key { usage, down: false } => Some(*usage),
            _ => None,
        })
        .collect();
    assert_eq!(releases, (0..40).collect::<Vec<_>>());
}

#[test]
fn long_text_splits_into_datagrams_that_fit() {
    let h = input(CMUX_RD_CARRIER_DATAGRAM);
    let text = "x".repeat(CMUX_RD_INPUT_MAX_TEXT);
    for _ in 0..12 {
        assert_eq!(push_text(&h, text.as_bytes()), CMUX_RD_OK);
    }
    let sent = packets(&h, 0);
    assert!(sent.len() >= 3);
    let mut seqs = Vec::new();
    for d in &sent {
        assert!(d.len() <= MAX_DATAGRAM_VPC);
        let p = decode(d);
        seqs.extend((0..p.events.len() as u32).map(|i| p.first_seq + i));
    }
    // New text is sent once each, in order, with no repeats in the same burst.
    assert_eq!(seqs, (1..=12).collect::<Vec<_>>());
}

#[test]
fn stream_carrier_frames_each_packet() {
    let h = input(CMUX_RD_CARRIER_STREAM);
    push(&h, &CmuxRdInputEvent { dx: -120, dy: 300, precise: 1, ..blank(CMUX_RD_INPUT_SCROLL) });
    push(&h, &CmuxRdInputEvent { button: 3, down: 1, ..blank(CMUX_RD_INPUT_BUTTON) });
    let sent = packets(&h, 0);
    assert_eq!(sent.len(), 1);
    let mut d = StreamDeframer::default();
    d.extend(&sent[0]);
    let (kind, datagram) = d.next_frame().expect("frame").expect("complete");
    assert_eq!(kind, STREAM_DATAGRAM);
    assert_eq!(
        decode(&datagram).events,
        vec![
            InputEvent::Scroll { dx: -120, dy: 300, precise: true },
            InputEvent::Button { button: 3, down: true },
        ]
    );
}

#[test]
fn bad_events_and_acks_are_refused() {
    assert!(cmux_rd_input_new(7, RESEND_US).is_null());
    let h = input(CMUX_RD_CARRIER_DATAGRAM);
    assert_eq!(push(&h, &blank(0)).0, CMUX_RD_ERR_INVALID);
    assert_eq!(push(&h, &blank(6)).0, CMUX_RD_ERR_INVALID);
    assert_eq!(push_text(&h, b""), CMUX_RD_ERR_INVALID);
    assert_eq!(push_text(&h, &[0xff, 0xfe]), CMUX_RD_ERR_INVALID);
    assert_eq!(push_text(&h, &[b'a'; CMUX_RD_INPUT_MAX_TEXT + 1]), CMUX_RD_ERR_INVALID);
    let null_text = CmuxRdInputEvent { text_len: 4, ..blank(CMUX_RD_INPUT_TEXT) };
    assert_eq!(push(&h, &null_text).0, CMUX_RD_ERR_INVALID);
    assert_eq!(deadline(&h), u64::MAX, "nothing was queued");
    // SAFETY: NULL handle and NULL event are refused before any access.
    unsafe {
        assert_eq!(
            cmux_rd_input_push(std::ptr::null_mut(), &key(4, true), std::ptr::null_mut()),
            CMUX_RD_ERR_NULL
        );
        assert_eq!(
            cmux_rd_input_push(h.0, std::ptr::null(), std::ptr::null_mut()),
            CMUX_RD_ERR_NULL
        );
        assert_eq!(cmux_rd_input_next_deadline_us(std::ptr::null()), u64::MAX);
    }
    // A seq pointer may be NULL.
    // SAFETY: live handle, readable event.
    assert_eq!(unsafe { cmux_rd_input_push(h.0, &key(4, true), std::ptr::null_mut()) }, CMUX_RD_OK);
    let mut feedback = ack_datagram(1);
    feedback[1] = DatagramKind::Feedback as u8;
    assert_eq!(ack(&h, &feedback), CMUX_RD_ERR_INVALID);
    assert_eq!(ack(&h, &ack_datagram(1)[..HEADER_LEN + 3]), CMUX_RD_ERR_INVALID);
    assert_eq!(ack(&h, b"garbage"), CMUX_RD_ERR_INVALID);
}

#[test]
fn small_buffer_keeps_the_packet() {
    let h = input(CMUX_RD_CARRIER_DATAGRAM);
    push(&h, &key(4, true));
    let mut small = [0u8; 4];
    let mut len = 0;
    // SAFETY: live handle, writable buffer and length.
    let rc = unsafe { cmux_rd_input_packet(h.0, 0, small.as_mut_ptr(), small.len(), &mut len) };
    assert_eq!(rc, CMUX_RD_ERR_BUFFER);
    assert!(len > small.len());
    assert_eq!(deadline(&h), 0);
    let sent = packets(&h, 0);
    assert_eq!(sent.len(), 1);
    assert_eq!(sent[0].len(), len);
    assert_eq!(decode(&sent[0]).events, vec![InputEvent::Key { usage: 4, down: true }]);
}

#[test]
fn older_lost_events_repeat_while_new_input_keeps_flowing() {
    let h = input(CMUX_RD_CARRIER_DATAGRAM);
    let mut host = InputApplier::new(200_000);
    for x in 0..40 {
        push(&h, &CmuxRdInputEvent { x, ..blank(CMUX_RD_INPUT_POINTER) });
    }
    // The first burst is lost.
    assert!(!packets(&h, 0).is_empty());
    let mut now = 0;
    let mut applied = Vec::new();
    // New motion every 8 ms keeps a never-sent event in the queue.
    while now < 150_000 {
        now += 8_000;
        push(&h, &CmuxRdInputEvent { x: 1_000, ..blank(CMUX_RD_INPUT_POINTER) });
        for d in packets(&h, now) {
            applied.extend(host.accept(&decode(&d), now));
            ack(&h, &ack_datagram(host.applied()));
        }
    }
    // The lost events were repeated before the host's gap timeout.
    assert!(!host.take_skipped_gap());
    assert_eq!(applied.first(), Some(&InputEvent::Pointer { x: 0, y: 0 }));
}

#[test]
fn packet_writes_out_len_on_every_path() {
    let mut len = 99;
    let mut buf = [0u8; 8];
    // SAFETY: NULL handle is refused before any access; buffer and length are writable.
    let rc = unsafe {
        cmux_rd_input_packet(std::ptr::null_mut(), 0, buf.as_mut_ptr(), buf.len(), &mut len)
    };
    assert_eq!(rc, CMUX_RD_ERR_NULL);
    assert_eq!(len, 0);
    // The receiver's feedback call follows the same rule.
    len = 99;
    // SAFETY: as above.
    let rc = unsafe {
        cmux_rd_receiver_feedback(std::ptr::null_mut(), 0, buf.as_mut_ptr(), buf.len(), &mut len)
    };
    assert_eq!(rc, CMUX_RD_ERR_NULL);
    assert_eq!(len, 0);
}

#[test]
fn flag_bytes_other_than_zero_and_one_are_refused() {
    let h = input(CMUX_RD_CARRIER_DATAGRAM);
    let key = CmuxRdInputEvent { usage: 4, down: 2, ..blank(CMUX_RD_INPUT_KEY) };
    assert_eq!(push(&h, &key).0, CMUX_RD_ERR_INVALID);
    let button = CmuxRdInputEvent { button: 1, down: 0xff, ..blank(CMUX_RD_INPUT_BUTTON) };
    assert_eq!(push(&h, &button).0, CMUX_RD_ERR_INVALID);
    let scroll = CmuxRdInputEvent { dy: 1, precise: 7, ..blank(CMUX_RD_INPUT_SCROLL) };
    assert_eq!(push(&h, &scroll).0, CMUX_RD_ERR_INVALID);
    assert_eq!(deadline(&h), u64::MAX, "nothing was queued");
    // Flags of kinds that do not use them are ignored.
    let pointer = CmuxRdInputEvent { x: 1, down: 9, precise: 9, ..blank(CMUX_RD_INPUT_POINTER) };
    assert_eq!(push(&h, &pointer).0, CMUX_RD_OK);
}

#[test]
fn service_events_carry_bytes_and_refuse_bad_flags_and_sizes() {
    let h = input(CMUX_RD_CARRIER_DATAGRAM);
    let payload = [7u8, 0, 9, 255];
    let event = CmuxRdInputEvent {
        text: payload.as_ptr(),
        text_len: payload.len(),
        service_flags: CMUX_RD_INPUT_MUST_DELIVER,
        ..blank(CMUX_RD_INPUT_SERVICE)
    };
    assert_eq!(push(&h, &event).0, CMUX_RD_OK);
    let sent = packets(&h, 0);
    assert_eq!(
        decode(&sent[0]).events,
        vec![InputEvent::Service { must_deliver: true, bytes: payload.to_vec() }]
    );
    let h = input(CMUX_RD_CARRIER_DATAGRAM);
    let unknown_bit = CmuxRdInputEvent { service_flags: 0x02, ..event };
    assert_eq!(push(&h, &unknown_bit).0, CMUX_RD_ERR_INVALID);
    let empty = CmuxRdInputEvent { text_len: 0, ..event };
    assert_eq!(push(&h, &empty).0, CMUX_RD_ERR_INVALID);
    let big = vec![1u8; CMUX_RD_INPUT_MAX_SERVICE + 1];
    let too_big = CmuxRdInputEvent { text: big.as_ptr(), text_len: big.len(), ..event };
    assert_eq!(push(&h, &too_big).0, CMUX_RD_ERR_INVALID);
    assert_eq!(deadline(&h), u64::MAX, "nothing was queued");
    // The largest service event still fits one datagram of the smallest session.
    let max = vec![2u8; CMUX_RD_INPUT_MAX_SERVICE];
    let largest = CmuxRdInputEvent { text: max.as_ptr(), text_len: max.len(), ..event };
    assert_eq!(push(&h, &largest).0, CMUX_RD_OK);
    let sent = packets(&h, 0);
    assert_eq!(sent.len(), 1);
    assert!(sent[0].len() <= MAX_DATAGRAM_VPC);
}
