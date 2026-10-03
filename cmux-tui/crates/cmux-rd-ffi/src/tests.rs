//! Round trips through the C ABI, refusal of bad input, panic containment and
//! header parity.

use super::*;
use cmux_rd_core::packetize::Packetizer;
use cmux_rd_proto::{DatagramHeader, DatagramKind, Feedback, FrameBody, HEADER_LEN, MAX_DATAGRAM_VPC, REF_NONE, flags};

fn body(frame: u32, len: usize, keyframe: bool) -> FrameBody {
    FrameBody {
        t_capture_us: u64::from(frame) * 16_667,
        ref_frame: if keyframe { REF_NONE } else { frame - 1 },
        access_unit: (0..len).map(|i| (i as u32 ^ frame) as u8).collect(),
    }
}

/// Datagrams of frames 1..=n (frame 1 a keyframe) with `parity` parity shards each.
fn frames(n: u32, len: usize, parity: usize) -> Vec<(FrameBody, Vec<Vec<u8>>)> {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    (1..=n)
        .map(|f| {
            let key = f == 1;
            let b = body(f, len, key);
            let flags = if key { flags::KEYFRAME } else { 0 };
            let out = p.packetize(f, flags, &b, parity).expect("packetize");
            (b, out.datagrams)
        })
        .collect()
}

struct Owned(*mut CmuxRdReceiver);
impl Drop for Owned {
    fn drop(&mut self) {
        // SAFETY: created by cmux_rd_receiver_new and freed once here.
        unsafe { cmux_rd_receiver_free(self.0) };
    }
}

fn receiver(carrier: u32) -> Owned {
    let r = cmux_rd_receiver_new(carrier, 200_000, 5_000);
    assert!(!r.is_null());
    Owned(r)
}

fn push(r: &Owned, d: &[u8], now: u64) -> i32 {
    // SAFETY: live receiver, readable slice.
    unsafe { cmux_rd_receiver_push_datagram(r.0, d.as_ptr(), d.len(), now) }
}

fn pop_all(r: &Owned) -> Vec<(u32, u8, u64, u32, Vec<u8>)> {
    let mut out = Vec::new();
    loop {
        let mut f = CmuxRdFrame {
            t_capture_us: 0,
            data: std::ptr::null(),
            len: 0,
            frame: 0,
            ref_frame: 0,
            flags: 0,
        };
        // SAFETY: live receiver, writable out.
        match unsafe { cmux_rd_receiver_pop_frame(r.0, &mut f) } {
            0 => return out,
            1 => {
                // SAFETY: data is valid for len bytes until the next call.
                let bytes = unsafe { std::slice::from_raw_parts(f.data, f.len) }.to_vec();
                out.push((f.frame, f.flags, f.t_capture_us, f.ref_frame, bytes));
            }
            code => panic!("pop_frame returned {code}"),
        }
    }
}

fn feedback(r: &Owned, now: u64) -> Option<Vec<u8>> {
    let mut buf = vec![0u8; 2048];
    let mut len = 0usize;
    // SAFETY: live receiver, writable buffer and length.
    match unsafe { cmux_rd_receiver_feedback(r.0, now, buf.as_mut_ptr(), buf.len(), &mut len) } {
        0 => None,
        1 => Some(buf[..len].to_vec()),
        code => panic!("feedback returned {code}"),
    }
}

fn decode_feedback(datagram: &[u8]) -> Feedback {
    let (h, payload) = DatagramHeader::decode(datagram).expect("header");
    assert_eq!(h.kind, DatagramKind::Feedback);
    Feedback::decode(payload).expect("feedback")
}

#[test]
fn datagrams_round_trip_to_access_units() {
    let r = receiver(CMUX_RD_CARRIER_DATAGRAM);
    let sent = frames(4, 3000, 1);
    let mut now = 1_000;
    for (_, datagrams) in &sent {
        // Reverse order inside a frame, and drop one data shard: parity rebuilds it.
        for d in datagrams.iter().rev().skip(1) {
            assert!(push(&r, d, now) >= 0);
            now += 10;
        }
    }
    let got = pop_all(&r);
    assert_eq!(got.len(), 4);
    for ((b, _), (frame, fl, t, rf, au)) in sent.iter().zip(&got) {
        assert_eq!(*t, b.t_capture_us);
        assert_eq!(*rf, b.ref_frame);
        assert_eq!(au, &b.access_unit);
        assert_eq!(*fl & flags::KEYFRAME != 0, *frame == 1);
    }
    let fb = decode_feedback(&feedback(&r, now).expect("due after a release"));
    assert_eq!(fb.acked_frame, 4);
    assert!(!fb.need_recovery);
    assert!(!fb.arrivals.is_empty());
    assert!(feedback(&r, now).is_none());
}

#[test]
fn stream_carrier_splits_frames_and_queues_control() {
    let r = receiver(CMUX_RD_CARRIER_STREAM);
    let mut stream = Vec::new();
    let control = br#"{"t":"started","session":7}"#;
    let mut buf = vec![0u8; 4096];
    let mut len = 0usize;
    // SAFETY: readable payload, writable buffer and length.
    let rc = unsafe {
        cmux_rd_encode_stream_frame(1, control.as_ptr(), control.len(), buf.as_mut_ptr(), buf.len(), &mut len)
    };
    assert_eq!(rc, CMUX_RD_OK);
    stream.extend_from_slice(&buf[..len]);
    let sent = frames(2, 2500, 0);
    for d in sent.iter().flat_map(|(_, ds)| ds) {
        // SAFETY: as above.
        let rc = unsafe { cmux_rd_encode_stream_frame(2, d.as_ptr(), d.len(), buf.as_mut_ptr(), buf.len(), &mut len) };
        assert_eq!(rc, CMUX_RD_OK);
        stream.extend_from_slice(&buf[..len]);
    }
    for chunk in stream.chunks(7) {
        // SAFETY: live receiver, readable chunk.
        assert!(unsafe { cmux_rd_receiver_push_stream(r.0, chunk.as_ptr(), chunk.len(), 10) } >= 0);
    }
    let mut m = CmuxRdMessage { data: std::ptr::null(), len: 0, kind: 0 };
    // SAFETY: live receiver, writable out.
    assert_eq!(unsafe { cmux_rd_receiver_pop_message(r.0, &mut m) }, 1);
    assert_eq!(m.kind, 1);
    // SAFETY: valid until the next call.
    assert_eq!(unsafe { std::slice::from_raw_parts(m.data, m.len) }, control);
    // SAFETY: as above.
    assert_eq!(unsafe { cmux_rd_receiver_pop_message(r.0, &mut m) }, 0);
    let got = pop_all(&r);
    assert_eq!(got.iter().map(|g| g.0).collect::<Vec<_>>(), vec![1, 2]);
    assert_eq!(got[1].4, sent[1].0.access_unit);
    // Feedback on the stream carrier is stream-framed.
    let framed = feedback(&r, 20).expect("feedback");
    assert_eq!(framed[0], 2);
    let inner_len = u32::from_le_bytes([framed[1], framed[2], framed[3], framed[4]]) as usize;
    assert_eq!(decode_feedback(&framed[5..5 + inner_len]).acked_frame, 2);
}

#[test]
fn non_video_datagrams_are_queued_as_messages() {
    let r = receiver(CMUX_RD_CARRIER_DATAGRAM);
    let mut ack = Vec::new();
    DatagramHeader {
        flags: 0,
        kind: DatagramKind::InputAck,
        stream: 0,
        frame: 0,
        index: 0,
        count: 0,
        fec_count: 0,
        transport_seq: 3,
    }
    .encode_into(&mut ack);
    ack.extend_from_slice(&9u32.to_le_bytes());
    assert_eq!(push(&r, &ack, 1), 0);
    let mut m = CmuxRdMessage { data: std::ptr::null(), len: 0, kind: 0 };
    // SAFETY: live receiver, writable out.
    assert_eq!(unsafe { cmux_rd_receiver_pop_message(r.0, &mut m) }, 1);
    assert_eq!(m.kind, 2);
    // SAFETY: valid until the next call.
    assert_eq!(unsafe { std::slice::from_raw_parts(m.data, m.len) }, ack.as_slice());
}

#[test]
fn bad_input_is_refused() {
    assert!(cmux_rd_receiver_new(9, 1, 1).is_null());
    let r = receiver(CMUX_RD_CARRIER_DATAGRAM);
    assert_eq!(push(&r, &[0x11, 0x01], 0), CMUX_RD_ERR_INVALID);
    assert_eq!(push(&r, &[0x21; HEADER_LEN], 0), CMUX_RD_ERR_INVALID);
    // SAFETY: NULL bytes with a length are refused before any read.
    assert_eq!(unsafe { cmux_rd_receiver_push_datagram(r.0, std::ptr::null(), 4, 0) }, CMUX_RD_ERR_NULL);
    // SAFETY: NULL receiver is refused.
    assert_eq!(unsafe { cmux_rd_receiver_tick(std::ptr::null_mut(), 0) }, CMUX_RD_ERR_NULL);
    // SAFETY: live receiver; wrong carrier.
    assert_eq!(unsafe { cmux_rd_receiver_push_stream(r.0, [1u8].as_ptr(), 1, 0) }, CMUX_RD_ERR_CARRIER);
    // SAFETY: NULL is allowed and returns the sentinel.
    assert_eq!(unsafe { cmux_rd_receiver_next_deadline_us(std::ptr::null()) }, u64::MAX);
    let s = receiver(CMUX_RD_CARRIER_STREAM);
    // SAFETY: live receiver, readable bytes.
    assert_eq!(unsafe { cmux_rd_receiver_push_stream(s.0, [9u8, 0, 0, 0, 0].as_ptr(), 5, 0) }, CMUX_RD_ERR_FAILED);
    // The failure is sticky.
    // SAFETY: as above.
    assert_eq!(unsafe { cmux_rd_receiver_push_stream(s.0, [1u8, 0, 0, 0, 0].as_ptr(), 5, 0) }, CMUX_RD_ERR_FAILED);
    let mut len = 0usize;
    // SAFETY: unknown kind is refused before any write.
    let rc = unsafe { cmux_rd_encode_stream_frame(5, std::ptr::null(), 0, std::ptr::null_mut(), 0, &mut len) };
    assert_eq!(rc, CMUX_RD_ERR_INVALID);
}

#[test]
fn garbage_never_panics() {
    let r = receiver(CMUX_RD_CARRIER_DATAGRAM);
    let s = receiver(CMUX_RD_CARRIER_STREAM);
    let mut seed = 0x9e37_79b9_7f4a_7c15u64;
    for i in 0..5_000u64 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let len = (seed % 300) as usize;
        let mut bytes: Vec<u8> = (0..len).map(|j| (seed >> (j % 56)) as u8).collect();
        if let Some(first) = bytes.first_mut() {
            // Keep many inputs past the version check.
            *first = 0x10 | (*first & 0x07);
        }
        let rc = push(&r, &bytes, i);
        assert!(rc >= 0 || rc == CMUX_RD_ERR_INVALID, "rc {rc}");
        // SAFETY: live receiver, readable bytes.
        let rc = unsafe { cmux_rd_receiver_push_stream(s.0, bytes.as_ptr(), bytes.len(), i) };
        assert_ne!(rc, CMUX_RD_ERR_PANIC);
    }
    pop_all(&r);
}

#[test]
fn loss_produces_nacks_then_recovery() {
    let r = receiver(CMUX_RD_CARRIER_DATAGRAM);
    let sent = frames(2, 4000, 0);
    // Frame 1 complete; frame 2 misses shard 0.
    for d in &sent[0].1 {
        push(&r, d, 0);
    }
    assert_eq!(pop_all(&r).len(), 1);
    assert!(feedback(&r, 0).is_some());
    for d in sent[1].1.iter().skip(1) {
        push(&r, d, 1_000);
    }
    // NACK after nack_after_us (5 ms) at the next due feedback (50 ms interval).
    let fb = decode_feedback(&feedback(&r, 50_000).expect("due"));
    assert_eq!(fb.nacks.len(), 1);
    assert_eq!(fb.nacks[0].frame, 2);
    assert_eq!(fb.nacks[0].indexes, vec![0]);
    // The deadline (200 ms) names the next wakeup, then the frame is lost.
    // SAFETY: live receiver.
    let deadline = unsafe { cmux_rd_receiver_next_deadline_us(r.0) };
    assert!(deadline <= 201_001, "deadline {deadline}");
    // SAFETY: live receiver.
    assert_eq!(unsafe { cmux_rd_receiver_tick(r.0, 201_001) }, 0);
    let mut stats = CmuxRdStats::default();
    // SAFETY: live receiver, writable out.
    assert_eq!(unsafe { cmux_rd_receiver_stats(r.0, &mut stats) }, CMUX_RD_OK);
    assert_eq!(stats.frames_lost, 1);
    assert!(stats.need_recovery);
    assert!(decode_feedback(&feedback(&r, 201_001).expect("due")).need_recovery);
}

#[test]
fn keyframe_request_rides_feedback_until_a_keyframe() {
    let r = receiver(CMUX_RD_CARRIER_DATAGRAM);
    assert!(feedback(&r, 0).is_some());
    // SAFETY: live receiver.
    assert_eq!(unsafe { cmux_rd_receiver_request_keyframe(r.0) }, CMUX_RD_OK);
    // SAFETY: live receiver.
    assert_eq!(unsafe { cmux_rd_receiver_note_decode(r.0, 1_500) }, CMUX_RD_OK);
    assert!(decode_feedback(&feedback(&r, 50_000).expect("due")).need_recovery);
    for d in &frames(1, 500, 0)[0].1 {
        push(&r, d, 60_000);
    }
    let fb = decode_feedback(&feedback(&r, 60_000).expect("due after release"));
    assert!(!fb.need_recovery);
    assert_eq!(fb.decode_us, 1_500);
}

#[test]
fn small_buffer_keeps_the_feedback() {
    let r = receiver(CMUX_RD_CARRIER_DATAGRAM);
    let mut len = 0usize;
    let mut tiny = [0u8; 4];
    // SAFETY: live receiver, writable buffer and length.
    let rc = unsafe { cmux_rd_receiver_feedback(r.0, 0, tiny.as_mut_ptr(), tiny.len(), &mut len) };
    assert_eq!(rc, CMUX_RD_ERR_BUFFER);
    assert!(len > tiny.len());
    // SAFETY: live receiver.
    assert_eq!(unsafe { cmux_rd_receiver_next_deadline_us(r.0) }, 0);
    let datagram = feedback(&r, 0).expect("the kept feedback");
    assert_eq!(datagram.len(), len);
}

#[test]
fn a_panic_poisons_only_that_receiver() {
    let r = receiver(CMUX_RD_CARRIER_DATAGRAM);
    let other = receiver(CMUX_RD_CARRIER_DATAGRAM);
    let hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let rc = with_receiver(r.0, |_| panic!("boom"));
    std::panic::set_hook(hook);
    assert_eq!(rc, CMUX_RD_ERR_PANIC);
    // SAFETY: live (poisoned) receiver.
    assert_eq!(unsafe { cmux_rd_receiver_tick(r.0, 0) }, CMUX_RD_ERR_PANIC);
    // SAFETY: as above.
    assert_eq!(unsafe { cmux_rd_receiver_next_deadline_us(r.0) }, u64::MAX);
    // SAFETY: live receiver.
    assert_eq!(unsafe { cmux_rd_receiver_tick(other.0, 0) }, 0);
}

#[test]
fn header_declares_exactly_the_exported_functions_and_codes() {
    let header = include_str!("../include/cmux_rd_ffi.h");
    let source = include_str!("lib.rs");
    let declared: std::collections::BTreeSet<&str> = header
        .lines()
        .filter(|l| !l.trim_start().starts_with('#') && !l.trim_start().starts_with('/'))
        .filter_map(|l| {
            let open = l.find('(')?;
            let name = l[..open].rsplit(|c: char| !(c.is_alphanumeric() || c == '_')).next()?;
            name.starts_with("cmux_rd_").then_some(name)
        })
        .collect();
    let exported: std::collections::BTreeSet<&str> = source
        .split("extern \"C\" fn ")
        .skip(1)
        .filter_map(|rest| rest.split('(').next())
        .collect();
    assert_eq!(declared, exported);
    for (name, value) in [
        ("CMUX_RD_ERR_NULL", CMUX_RD_ERR_NULL),
        ("CMUX_RD_ERR_INVALID", CMUX_RD_ERR_INVALID),
        ("CMUX_RD_ERR_BUFFER", CMUX_RD_ERR_BUFFER),
        ("CMUX_RD_ERR_CARRIER", CMUX_RD_ERR_CARRIER),
        ("CMUX_RD_ERR_FAILED", CMUX_RD_ERR_FAILED),
        ("CMUX_RD_ERR_PANIC", CMUX_RD_ERR_PANIC),
    ] {
        assert!(header.contains(&format!("#define {name} ({value})")), "{name}");
    }
    assert!(header.contains(&format!("#define CMUX_RD_FFI_ABI_VERSION {ABI_VERSION}u")));
    assert!(header.contains(&format!("#define CMUX_RD_MESSAGE_CONTROL {STREAM_CONTROL}u")));
    assert!(header.contains(&format!("#define CMUX_RD_MESSAGE_DATAGRAM {STREAM_DATAGRAM}u")));
    assert!(header.contains(&format!("#define CMUX_RD_FLAG_KEYFRAME 0x0{}u", flags::KEYFRAME)));
    assert!(header.contains(&format!("#define CMUX_RD_FLAG_RECOVERY 0x0{}u", flags::RECOVERY)));
    // Layouts on 64-bit targets (the Swift tests check the imported layouts).
    assert_eq!(std::mem::size_of::<CmuxRdFrame>(), 40);
    assert_eq!(std::mem::size_of::<CmuxRdMessage>(), 24);
    assert_eq!(std::mem::size_of::<CmuxRdStats>(), 24);
}
