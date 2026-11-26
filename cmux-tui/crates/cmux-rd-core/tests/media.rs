//! FEC, packetizing and reassembly properties.

use cmux_rd_core::fec;
use cmux_rd_core::packetize::{Packetizer, parity_for};
use cmux_rd_core::reassembly::{FrameLoss, NACK_RETRY_FLOOR_US, Reassembler};
use cmux_rd_proto::{
    DatagramHeader, FRAME_PREFIX_LEN, FrameBody, HEADER_LEN, MAX_DATAGRAM_DEFAULT,
    MAX_DATAGRAM_VPC, REF_NONE, flags,
};
use proptest::prelude::*;

/// Other traffic on the link (clock pongs, other streams) every 5 ms from
/// `from` through `to`, recorded up front: the link is live, so a missing
/// shard is loss, not a hold.
fn keep_alive(r: &mut Reassembler, from: u64, to: u64) {
    let mut t = from;
    while t <= to {
        r.note_datagram(t);
        t += 5_000;
    }
}

fn body(frame: u32, len: usize, keyframe: bool) -> FrameBody {
    FrameBody {
        t_capture_us: u64::from(frame) * 16_667,
        ref_frame: if keyframe { REF_NONE } else { frame - 1 },
        access_unit: (0..len).map(|i| (i as u32 ^ frame) as u8).collect(),
    }
}

proptest! {
    #[test]
    fn any_k_of_n_shards_rebuild_the_data(
        k in 1usize..20,
        m in 0usize..10,
        len in 1usize..64,
        seed in any::<u64>(),
        drop_mask in any::<u32>(),
    ) {
        let data: Vec<Vec<u8>> = (0..k).map(|i| (0..len).map(|j| (seed as usize ^ (i * 131 + j * 7)) as u8).collect()).collect();
        let refs: Vec<&[u8]> = data.iter().map(Vec::as_slice).collect();
        let parity = fec::encode(&refs, m).expect("encode");
        let mut shards: Vec<Option<Vec<u8>>> = data.iter().cloned().chain(parity).map(Some).collect();
        // Drop at most m shards.
        let mut dropped = 0;
        for (i, shard) in shards.iter_mut().enumerate() {
            if dropped < m && drop_mask & (1 << (i % 32)) != 0 {
                *shard = None;
                dropped += 1;
            }
        }
        fec::reconstruct(&mut shards, k).expect("reconstruct");
        for (i, d) in data.iter().enumerate() {
            prop_assert_eq!(shards[i].as_ref(), Some(d));
        }
    }

    #[test]
    fn packets_fit_the_datagram_size(len in 0usize..20_000, vpc in any::<bool>(), parity in 0usize..5) {
        let max = if vpc { MAX_DATAGRAM_VPC } else { MAX_DATAGRAM_DEFAULT };
        let mut p = Packetizer::new(0, max);
        let out = p.packetize(1, flags::KEYFRAME, &body(1, len, true), parity).expect("packetize");
        if out.datagrams.len() == 1 {
            // A lone shard without parity is not padded.
            prop_assert_eq!(out.datagrams[0].len(), HEADER_LEN + FRAME_PREFIX_LEN + len);
        } else {
            prop_assert!(out.datagrams.iter().all(|d| d.len() == max));
        }
        prop_assert_eq!(out.datagrams.len(), usize::from(out.data_shards) + parity);
    }

    #[test]
    fn frames_survive_losses_within_fec_and_any_order(
        sizes in proptest::collection::vec(1usize..6_000, 1..8),
        parity in 1usize..4,
        drop_seed in any::<u64>(),
        shuffle_seed in any::<u64>(),
    ) {
        let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
        let mut r = Reassembler::new(1_000_000);
        let mut released = Vec::new();
        for (i, &len) in sizes.iter().enumerate() {
            let frame = i as u32 + 1;
            let keyframe = frame == 1;
            let out = p
                .packetize(frame, if keyframe { flags::KEYFRAME } else { 0 }, &body(frame, len, keyframe), parity)
                .expect("packetize");
            // Lose up to `parity` shards of each frame, then deliver the rest shuffled.
            let mut datagrams: Vec<Vec<u8>> = out.datagrams;
            let mut lost = 0;
            datagrams.retain(|_| {
                let drop = lost < parity && (drop_seed >> ((frame as u64 * 3 + lost as u64) % 64)) & 1 == 1;
                if drop { lost += 1; }
                !drop
            });
            let n = datagrams.len();
            for j in 0..n {
                let k = (shuffle_seed as usize).wrapping_mul(j + 1) % n;
                datagrams.swap(j, k);
            }
            for d in &datagrams {
                let (h, payload) = DatagramHeader::decode(d).expect("decode");
                released.extend(r.push(&h, payload, u64::from(frame) * 1000));
            }
        }
        let ids: Vec<u32> = released.iter().map(|f| f.frame).collect();
        let expected: Vec<u32> = (1..=sizes.len() as u32).collect();
        prop_assert_eq!(ids, expected);
        for f in &released {
            prop_assert_eq!(&f.body, &body(f.frame, sizes[f.frame as usize - 1], f.frame == 1));
        }
    }
}

#[test]
fn a_frame_that_references_a_lost_frame_is_never_released() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    let mut r = Reassembler::new(50_000);
    let deliver = |r: &mut Reassembler,
                   p: &mut Packetizer,
                   frame: u32,
                   keyframe: bool,
                   skip: &[u16],
                   now: u64| {
        let out = p
            .packetize(
                frame,
                if keyframe { flags::KEYFRAME } else { 0 },
                &body(frame, 3000, keyframe),
                0,
            )
            .expect("packetize");
        let mut released = Vec::new();
        for d in &out.datagrams {
            let (h, payload) = DatagramHeader::decode(d).expect("decode");
            if !skip.contains(&h.index) {
                released.extend(r.push(&h, payload, now));
            }
        }
        released
    };
    assert_eq!(deliver(&mut r, &mut p, 1, true, &[], 0).len(), 1);
    // Frame 2 loses a shard and has no parity: it waits, then expires.
    assert!(deliver(&mut r, &mut p, 2, false, &[0], 1_000).is_empty());
    // Frame 3 is complete but references frame 2.
    assert!(deliver(&mut r, &mut p, 3, false, &[], 2_000).is_empty());
    keep_alive(&mut r, 2_000, 100_000);
    assert!(r.tick(100_000).is_empty());
    let losses = r.take_losses();
    assert!(losses.contains(&FrameLoss::Incomplete { frame: 2 }));
    assert!(losses.contains(&FrameLoss::BrokenReference { frame: 3, ref_frame: 2 }));
    assert!(r.need_recovery());
    // A keyframe recovers.
    let released = deliver(&mut r, &mut p, 4, true, &[], 200_000);
    assert_eq!(released.iter().map(|f| f.frame).collect::<Vec<_>>(), vec![4]);
    assert!(!r.need_recovery());
    assert_eq!(r.last_released(), 4);
}

#[test]
fn recovery_frame_referencing_the_last_released_frame_is_released() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    let mut r = Reassembler::new(10_000);
    let send = |r: &mut Reassembler,
                p: &mut Packetizer,
                frame: u32,
                b: FrameBody,
                f: u8,
                now: u64,
                lose_all: bool| {
        let out = p.packetize(frame, f, &b, 0).expect("packetize");
        let mut released = Vec::new();
        if !lose_all {
            for d in &out.datagrams {
                let (h, payload) = DatagramHeader::decode(d).expect("decode");
                released.extend(r.push(&h, payload, now));
            }
        }
        released
    };
    assert_eq!(send(&mut r, &mut p, 1, body(1, 100, true), flags::KEYFRAME, 0, false).len(), 1);
    assert!(send(&mut r, &mut p, 2, body(2, 100, false), 0, 1, true).is_empty());
    let recovery = FrameBody { t_capture_us: 3, ref_frame: 1, access_unit: vec![1, 2, 3] };
    let released = send(&mut r, &mut p, 3, recovery, flags::RECOVERY, 20_000, false);
    assert_eq!(released.iter().map(|f| f.frame).collect::<Vec<_>>(), vec![3]);
}

#[test]
fn missing_lists_absent_data_shards() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    let mut r = Reassembler::new(1_000_000);
    let out = p.packetize(1, flags::KEYFRAME, &body(1, 5000, true), 0).expect("packetize");
    for d in out.datagrams.iter().skip(1) {
        let (h, payload) = DatagramHeader::decode(d).expect("decode");
        assert!(r.push(&h, payload, 0).is_empty());
    }
    assert_eq!(r.missing(10, 5), vec![(1, vec![0])]);
    assert!(r.missing(10, 50).is_empty());
}

#[test]
fn nack_grace_does_not_request_the_unseen_tail_of_an_arriving_frame() {
    let mut p = Packetizer::new(0, 256);
    let sent = p.packetize(1, flags::KEYFRAME, &body(1, 1500, true), 0).expect("packetize");
    let mut r = Reassembler::new(200_000);
    let last = sent.datagrams.len() - 1;
    for (i, d) in sent.datagrams[..last].iter().enumerate() {
        let now = 25_000 + i as u64 * 4_000;
        let (h, payload) = DatagramHeader::decode(d).expect("decode");
        assert!(r.push(&h, payload, now).is_empty());
        assert_eq!(r.next_nack_us(5_000, 50_000), Some(now + 5_000));
        assert!(r.take_nacks(now + 3_999, 5_000, 50_000).is_empty());
    }
    let tail_due = 25_000 + (last as u64 - 1) * 4_000 + 5_000;
    let requests = r.take_nacks(tail_due, 5_000, 50_000);
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].indexes, vec![last as u16]);

    // A gap proven by a later shard is requested promptly, while shards
    // beyond that later shard are still allowed to arrive normally.
    let mut r = Reassembler::new(200_000);
    for (i, now) in [(0, 0), (2, 6_000)] {
        let (h, payload) = DatagramHeader::decode(&sent.datagrams[i]).expect("decode");
        assert!(r.push(&h, payload, now).is_empty());
    }
    let requests = r.take_nacks(6_000, 5_000, 50_000);
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].indexes, vec![1]);

    // With the viewer's per-gap grace, the same gap is requested one grace
    // after it is first seen, while shards beyond the newest arrival are still
    // allowed to arrive: the tail is requested one grace after the last arrival.
    let mut r = Reassembler::new(200_000);
    r.set_gap_grace(true);
    for (i, now) in [(0, 0), (2, 6_000), (3, 9_000), (4, 10_000)] {
        let (h, payload) = DatagramHeader::decode(&sent.datagrams[i]).expect("decode");
        assert!(r.push(&h, payload, now).is_empty());
    }
    assert!(r.take_nacks(10_999, 5_000, 50_000).is_empty());
    let requests = r.take_nacks(11_000, 5_000, 50_000);
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].indexes, vec![1]);
    assert!(r.take_nacks(14_999, 5_000, 50_000).is_empty());
    let requests = r.take_nacks(15_000, 5_000, 50_000);
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].indexes, vec![5, 6]);
}

#[test]
fn nack_deadlines_are_per_frame_and_only_sent_requests_start_retrying() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    let mut r = Reassembler::new(1_000_000);
    let mut repairs = Vec::new();
    // More gaps than one feedback packet can carry must not starve the tail.
    for frame in 1..=6 {
        let out = p.packetize(frame, 0, &body(frame, 5000, frame == 1), 0).expect("packetize");
        repairs.push(out.datagrams[0].clone());
        for d in out.datagrams.iter().skip(1) {
            let (h, payload) = DatagramHeader::decode(d).expect("decode");
            assert!(r.push(&h, payload, 25_000).is_empty());
        }
    }
    assert_eq!(r.next_nack_us(5_000, 50_000), Some(30_000));
    assert!(r.take_nacks(29_999, 5_000, 50_000).is_empty());
    let first = r.take_nacks(30_000, 5_000, 50_000);
    assert_eq!(first.iter().map(|n| n.frame).collect::<Vec<_>>(), vec![1, 2, 3, 4]);
    assert_eq!(r.next_nack_us(5_000, 50_000), Some(30_000));
    let rest = r.take_nacks(30_000, 5_000, 50_000);
    assert_eq!(rest.iter().map(|n| n.frame).collect::<Vec<_>>(), vec![5, 6]);
    assert!(first.iter().chain(&rest).all(|n| n.indexes == vec![0]));
    assert!(r.take_nacks(30_000, 5_000, 50_000).is_empty());
    // No round trip known: an unanswered request is retried after 50 ms.
    assert_eq!(r.next_nack_us(5_000, 50_000), Some(80_000));

    // A new frame does not inherit the retry deadline of previous gaps.
    let out = p.packetize(7, 0, &body(7, 5000, false), 0).expect("packetize");
    for d in out.datagrams.iter().skip(1) {
        let (h, payload) = DatagramHeader::decode(d).expect("decode");
        assert!(r.push(&h, payload, 40_000).is_empty());
    }
    assert_eq!(r.next_nack_us(5_000, 50_000), Some(45_000));
    assert_eq!(r.take_nacks(45_000, 5_000, 50_000)[0].frame, 7);
    for d in repairs.iter().chain(std::iter::once(&out.datagrams[0])) {
        let (h, payload) = DatagramHeader::decode(d).expect("decode");
        assert_eq!(r.push(&h, payload, 75_000).len(), 1);
    }
    assert_eq!(r.next_nack_us(5_000, 50_000), None);
    assert!(r.take_nacks(80_000, 5_000, 50_000).is_empty());
    assert!(!r.need_recovery());
}

#[test]
fn parity_scales_with_loss() {
    assert_eq!(parity_for(10, 0.0, true), 0);
    assert_eq!(parity_for(10, 0.02, false), 1);
    assert_eq!(parity_for(10, 0.30, false), 5);
    assert_eq!(parity_for(1, 0.01, true), 1);
}

#[test]
fn a_frame_larger_than_one_fec_block_goes_without_parity_and_reassembles() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    let mut r = Reassembler::new(1_000_000);
    // About 400 KB: more than 255 shards of 1136 bytes.
    let big = body(1, 400_000, true);
    let out = p.packetize(1, flags::KEYFRAME, &big, 4).expect("packetize");
    assert_eq!(out.parity_shards, 0);
    assert!(out.data_shards > 255);
    let mut released = Vec::new();
    for d in out.datagrams.iter().rev() {
        let (h, payload) = DatagramHeader::decode(d).expect("decode");
        released.extend(r.push(&h, payload, 0));
    }
    assert_eq!(released.len(), 1);
    assert_eq!(released[0].body, big);
}

#[test]
fn a_shard_of_another_length_is_refused() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    let mut r = Reassembler::new(1_000_000);
    let out = p.packetize(1, flags::KEYFRAME, &body(1, 3000, true), 0).expect("packetize");
    let (h0, payload0) = DatagramHeader::decode(&out.datagrams[0]).expect("decode");
    // A forged oversized copy of shard 1 arrives first and must not be stored.
    let (h1, payload1) = DatagramHeader::decode(&out.datagrams[1]).expect("decode");
    let mut forged = payload1.to_vec();
    forged.extend_from_slice(&[0u8; 60_000]);
    assert!(r.push(&h0, payload0, 0).is_empty());
    assert!(r.push(&h1, &forged, 0).is_empty());
    let mut released = Vec::new();
    for d in &out.datagrams[1..] {
        let (h, payload) = DatagramHeader::decode(d).expect("decode");
        released.extend(r.push(&h, payload, 0));
    }
    assert_eq!(released.len(), 1);
    assert_eq!(released[0].body, body(1, 3000, true));
}

#[test]
fn next_expiry_names_the_oldest_incomplete_frame() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    let mut r = Reassembler::new(200);
    assert_eq!(r.next_expiry_us(), None);
    let out = p.packetize(1, flags::KEYFRAME, &body(1, 5000, true), 0).expect("packetize");
    let (h, payload) = DatagramHeader::decode(&out.datagrams[0]).expect("decode");
    assert!(r.push(&h, payload, 1_000).is_empty());
    // Other traffic keeps the link live: a missing shard is loss, not an outage.
    r.note_datagram(5_000);
    // The frame expires strictly after its deadline.
    assert_eq!(r.next_expiry_us(), Some(1_201));
    assert!(r.tick(1_200).is_empty());
    assert!(r.take_losses().is_empty());
    assert!(r.tick(1_201).is_empty());
    assert_eq!(r.take_losses(), vec![FrameLoss::Incomplete { frame: 1 }]);
    assert_eq!(r.next_expiry_us(), None);
}

/// Lossless tile top-offs (rd change C3): standalone frames on a tile stream
/// whose `ref_frame` names the surface stream's video frame, never a frame
/// of the tile stream itself.
#[test]
fn tile_frames_are_standalone_and_keep_their_video_reference() {
    let mut p = Packetizer::new(7, MAX_DATAGRAM_VPC);
    let mut r = Reassembler::new(10_000);
    let mut send = |frame: u32, video_frame: u32, len: usize, now: u64, lose_all: bool| {
        let b = FrameBody {
            t_capture_us: now,
            ref_frame: video_frame,
            access_unit: vec![frame as u8; len],
        };
        let out = p.packetize(frame, flags::TILE, &b, 1).expect("packetize");
        let mut released = Vec::new();
        if !lose_all {
            for d in &out.datagrams {
                let (h, payload) = DatagramHeader::decode(d).expect("a tile shard decodes");
                assert_ne!(h.flags & flags::TILE, 0, "every shard says tile");
                released.extend(r.push(&h, payload, now));
            }
        }
        released
    };
    // Frame 1 of the tile stream tops off video frame 900 of the surface stream.
    let first = send(1, 900, 3_000, 0, false);
    assert_eq!(
        first.iter().map(|f| (f.frame, f.body.ref_frame)).collect::<Vec<_>>(),
        vec![(1, 900)]
    );
    // A lost tile frame does not block a later one (tiles have no chain).
    assert!(send(2, 905, 3_000, 1_000, true).is_empty());
    let third = send(3, 910, 500, 2_000, false);
    assert_eq!(third.iter().map(|f| f.frame).collect::<Vec<_>>(), vec![3]);
}

// Release timing: a frame goes to the decoder in the call that completes it,
// and waits for nothing it does not need.

type Shard = (DatagramHeader, Vec<u8>);

fn shards(p: &mut Packetizer, frame: u32, f: u8, b: &FrameBody, parity: usize) -> Vec<Shard> {
    let out = p.packetize(frame, f, b, parity).expect("packetize");
    out.datagrams
        .iter()
        .map(|d| {
            let (h, payload) = DatagramHeader::decode(d).expect("decode");
            (h, payload.to_vec())
        })
        .collect()
}

fn push_all(r: &mut Reassembler, shards: &[Shard], now: u64) -> Vec<u32> {
    shards.iter().flat_map(|(h, p)| r.push(h, p, now)).map(|f| f.frame).collect()
}

/// A frame whose reference is `ref_frame`.
fn p_frame(frame: u32, ref_frame: u32) -> FrameBody {
    FrameBody { ref_frame, ..body(frame, 3000, false) }
}

#[test]
fn a_complete_frame_goes_out_with_its_last_shard_without_a_tick() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    // A long deadline: nothing here may depend on it passing.
    let mut r = Reassembler::new(10_000_000);
    let s = shards(&mut p, 1, flags::KEYFRAME, &body(1, 3000, true), 0);
    let (last, rest) = s.split_last().expect("shards");
    assert!(push_all(&mut r, rest, 0).is_empty());
    assert_eq!(r.push(&last.0, &last.1, 0).iter().map(|f| f.frame).collect::<Vec<_>>(), vec![1]);
    assert_eq!(r.next_expiry_us(), None, "no timer is left armed");
}

#[test]
fn a_frame_with_all_data_shards_does_not_wait_for_parity() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    let mut r = Reassembler::new(10_000_000);
    let s = shards(&mut p, 1, flags::KEYFRAME, &body(1, 3000, true), 2);
    let data: Vec<Shard> = s.iter().filter(|(h, _)| h.index < h.count).cloned().collect();
    let parity: Vec<Shard> = s.iter().filter(|(h, _)| h.index >= h.count).cloned().collect();
    assert_eq!(parity.len(), 2);
    assert_eq!(push_all(&mut r, &data, 0), vec![1]);
    // Late parity of a released frame is ignored.
    assert!(push_all(&mut r, &parity, 1).is_empty());
    assert!(r.take_losses().is_empty());
}

#[test]
fn a_complete_frame_on_a_released_reference_skips_an_older_incomplete_frame() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    let mut r = Reassembler::new(10_000_000);
    assert_eq!(
        push_all(&mut r, &shards(&mut p, 1, flags::KEYFRAME, &body(1, 3000, true), 0), 0),
        vec![1]
    );
    // Frame 2 arrives in part.
    let two = shards(&mut p, 2, 0, &p_frame(2, 1), 0);
    assert!(push_all(&mut r, &two[1..], 1_000).is_empty());
    // Frame 3 predicts from frame 1, already shown: it goes now, not at frame 2's deadline.
    assert_eq!(push_all(&mut r, &shards(&mut p, 3, 0, &p_frame(3, 1), 0), 2_000), vec![3]);
    assert_eq!(r.take_losses(), vec![FrameLoss::Incomplete { frame: 2 }]);
    assert_eq!(r.last_released(), 3);
    // Frame 2's repair, late, is ignored.
    assert!(push_all(&mut r, &two[..1], 3_000).is_empty());
    assert!(r.take_losses().is_empty());
}

#[test]
fn a_recovery_frame_skips_older_incomplete_frames() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    let mut r = Reassembler::new(10_000_000);
    assert_eq!(
        push_all(&mut r, &shards(&mut p, 1, flags::KEYFRAME, &body(1, 3000, true), 0), 0),
        vec![1]
    );
    assert_eq!(push_all(&mut r, &shards(&mut p, 2, 0, &p_frame(2, 1), 0), 0), vec![2]);
    let three = shards(&mut p, 3, 0, &p_frame(3, 2), 0);
    assert!(push_all(&mut r, &three[1..], 1_000).is_empty());
    let four = shards(&mut p, 4, 0, &p_frame(4, 3), 0);
    assert!(push_all(&mut r, &four[1..], 1_000).is_empty());
    // A recovery frame on frame 1 (acked, not the newest) goes at once.
    let recovery = shards(&mut p, 5, flags::RECOVERY, &p_frame(5, 1), 0);
    assert_eq!(push_all(&mut r, &recovery, 2_000), vec![5]);
    let losses = r.take_losses();
    assert!(losses.contains(&FrameLoss::Incomplete { frame: 3 }));
    assert!(losses.contains(&FrameLoss::Incomplete { frame: 4 }));
    assert!(!r.need_recovery());
}

#[test]
fn a_frame_that_needs_a_waiting_frame_goes_with_its_repair() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    let mut r = Reassembler::new(10_000_000);
    assert_eq!(
        push_all(&mut r, &shards(&mut p, 1, flags::KEYFRAME, &body(1, 3000, true), 0), 0),
        vec![1]
    );
    let two = shards(&mut p, 2, 0, &p_frame(2, 1), 0);
    assert!(push_all(&mut r, &two[1..], 1_000).is_empty());
    // Frame 3 predicts from frame 2, which is still repairable: it waits.
    assert!(push_all(&mut r, &shards(&mut p, 3, 0, &p_frame(3, 2), 0), 2_000).is_empty());
    // The repair releases both in the same call, in order.
    assert_eq!(push_all(&mut r, &two[..1], 30_000), vec![2, 3]);
    assert!(r.take_losses().is_empty());
}

#[test]
fn a_waiting_frame_is_dropped_one_microsecond_past_its_deadline() {
    let deadline = 50_000;
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    let mut r = Reassembler::new(deadline);
    assert_eq!(
        push_all(&mut r, &shards(&mut p, 1, flags::KEYFRAME, &body(1, 3000, true), 0), 0),
        vec![1]
    );
    let two = shards(&mut p, 2, 0, &p_frame(2, 1), 0);
    assert!(push_all(&mut r, &two[1..], 1_000).is_empty());
    keep_alive(&mut r, 1_000, 1_000 + deadline + 5_000);
    assert_eq!(r.next_expiry_us(), Some(1_000 + deadline + 1));
    assert!(r.tick(1_000 + deadline).is_empty());
    assert!(r.take_losses().is_empty(), "held through the deadline");
    assert!(r.tick(1_000 + deadline + 1).is_empty());
    assert_eq!(r.take_losses(), vec![FrameLoss::Incomplete { frame: 2 }]);
    assert!(r.need_recovery());
}

/// A hold on the path (nothing at all arrives for 300 ms, then everything at
/// once, as on Wi-Fi away from the access point) is not loss: the frame in
/// flight completes when the burst lands, with no loss and no recovery
/// request. Before, the round-trip-sized give-up (about 67 ms here) dropped
/// it mid-hold and asked for a keyframe that the same hold delayed.
#[test]
fn a_hold_then_a_burst_completes_the_frame_in_flight_without_recovery() {
    let mut p = Packetizer::new(0, 256);
    let mut r = Reassembler::new(200_000);
    r.set_path_rtt_us(Some(8_000));
    let mut now = 0;
    // Steady 60 fps before the hold sets the frame interval.
    for frame in 1..=10 {
        let out = p.packetize(frame, 0, &body(frame, 600, frame == 1), 0).expect("packetize");
        let mut released = Vec::new();
        for d in &out.datagrams {
            let (h, payload) = DatagramHeader::decode(d).expect("decode");
            released.extend(r.push(&h, payload, now));
        }
        assert_eq!(released.len(), 1, "frame {frame} released");
        now += 16_667;
    }
    let out = p.packetize(11, 0, &body(11, 600, false), 0).expect("packetize");
    assert!(out.datagrams.len() >= 3);
    let (h, payload) = DatagramHeader::decode(&out.datagrams[0]).expect("decode");
    assert!(r.push(&h, payload, now).is_empty());
    // The hold: the caller's timers keep firing; requests go out, nothing arrives.
    let hold_end = now + 300_000;
    let mut t = now;
    while t < hold_end {
        t += 5_000;
        assert!(r.tick(t).is_empty());
        let _ = r.take_nacks(t, 5_000, 50_000);
        assert!(r.next_expiry_us().is_none_or(|at| at > t), "a timer due in the past spins");
    }
    assert!(r.take_losses().is_empty(), "the frame in flight was given up during the hold");
    assert!(!r.need_recovery(), "a hold asked for a recovery frame");
    let mut released = Vec::new();
    for d in &out.datagrams[1..] {
        let (h, payload) = DatagramHeader::decode(d).expect("decode");
        released.extend(r.push(&h, payload, hold_end));
    }
    assert_eq!(released.len(), 1, "the frame in flight completes after the hold");
    assert!(r.take_losses().is_empty());
    assert!(!r.need_recovery());
}

/// A hold shorter than the outage threshold (90 ms against max(100 ms, 4 RTT),
/// a wifi-gate hold) is not an outage, so the give-up pause never starts; the
/// frame in flight must still complete from the burst. Before, its give-up
/// (two repair windows, about 67 ms) fell inside the hold, and the burst's
/// first datagram expired it before its own shard was taken: a loss and a
/// recovery request on every such hold (wifi-gate: 3-10 recovery keyframes a
/// run, none on base).
#[test]
fn a_hold_shorter_than_the_outage_threshold_completes_the_frame_without_recovery() {
    let mut p = Packetizer::new(0, 256);
    let mut r = Reassembler::new(200_000);
    r.set_path_rtt_us(Some(8_000));
    let mut now = 0;
    for frame in 1..=10 {
        let out = p.packetize(frame, 0, &body(frame, 600, frame == 1), 0).expect("packetize");
        let mut released = Vec::new();
        for d in &out.datagrams {
            let (h, payload) = DatagramHeader::decode(d).expect("decode");
            released.extend(r.push(&h, payload, now));
        }
        assert_eq!(released.len(), 1, "frame {frame} released");
        now += 16_667;
    }
    let out = p.packetize(11, 0, &body(11, 600, false), 0).expect("packetize");
    assert!(out.datagrams.len() >= 3);
    let (h, payload) = DatagramHeader::decode(&out.datagrams[0]).expect("decode");
    assert!(r.push(&h, payload, now).is_empty());
    let hold_end = now + 90_000;
    let mut t = now;
    while t < hold_end {
        t += 5_000;
        assert!(r.tick(t).is_empty());
        let _ = r.take_nacks(t, 5_000, 50_000);
    }
    let mut released = Vec::new();
    for d in &out.datagrams[1..] {
        let (h, payload) = DatagramHeader::decode(d).expect("decode");
        released.extend(r.push(&h, payload, hold_end));
    }
    assert!(r.take_losses().is_empty(), "a 90 ms hold cost the frame in flight");
    assert!(!r.need_recovery(), "a 90 ms hold asked for a recovery frame");
    assert_eq!(released.len(), 1, "the frame in flight completes after the hold");
}

/// The reorder grace counts from when a gap is first seen, not from the
/// frame's first shard. A shard overtaken late in a frame's arrival (a burst
/// after a hold, released out of order) and arriving within the grace is never
/// requested; a shard really lost is requested once its own grace has passed.
/// Before, a gap first seen more than 5 ms into the frame was requested at once:
/// on wifi-away, about 1,660 more NACKed shards a run than the base and the
/// host resending shards the viewer then received anyway.
#[test]
fn a_reordered_shard_inside_its_grace_is_never_nacked_and_a_real_loss_is() {
    use cmux_rd_core::reassembly::NACK_AFTER_US;
    let mut p = Packetizer::new(0, 256);
    let mut r = Reassembler::new(200_000);
    r.set_gap_grace(true);
    r.set_path_rtt_us(Some(8_000));
    let out = p.packetize(1, flags::KEYFRAME, &body(1, 2_400, true), 0).expect("packetize");
    let d: Vec<_> =
        out.datagrams.iter().map(|d| DatagramHeader::decode(d).expect("decode")).collect();
    assert!(d.len() >= 8, "{} shards", d.len());
    let push = |r: &mut Reassembler, i: usize, at: u64| {
        let (h, payload) = &d[i];
        r.push(h, payload, at)
    };
    push(&mut r, 0, 0);
    push(&mut r, 1, 0);
    // Shard 3 overtakes shard 2, 10 ms into the frame: gap 2 is first seen now.
    push(&mut r, 3, 10_000);
    assert!(
        r.take_nacks(10_000, 5_000, 50_000).is_empty(),
        "a gap just seen was requested at once"
    );
    assert_eq!(r.next_nack_us(5_000, 50_000), Some(10_000 + NACK_AFTER_US));
    // The overtaken shard arrives inside its grace: it is never requested.
    push(&mut r, 2, 12_000);
    assert!(r.take_nacks(12_000, 5_000, 50_000).is_empty());
    // Shard 5 is lost: shard 6 shows the gap at 20 ms, and 5 never comes.
    push(&mut r, 4, 20_000);
    push(&mut r, 6, 20_000);
    assert!(
        r.take_nacks(20_000 + NACK_AFTER_US - 1, 5_000, 50_000).is_empty(),
        "requested inside its grace"
    );
    let nacks = r.take_nacks(20_000 + NACK_AFTER_US, 5_000, 50_000);
    assert_eq!(nacks.len(), 1);
    assert_eq!(nacks[0].indexes.first(), Some(&5), "the lost shard, after its own grace");
    assert!(!nacks[0].indexes.contains(&2), "the overtaken shard was requested");
}

/// Real loss still gives a frame up within the outage threshold, not the
/// 200 ms deadline: the link stays live, the shard never comes.
#[test]
fn a_lost_shard_on_a_live_link_is_given_up_at_the_outage_threshold() {
    use cmux_rd_core::cc::outage_threshold_us;
    let mut p = Packetizer::new(0, 256);
    let mut r = Reassembler::new(200_000);
    r.set_path_rtt_us(Some(8_000));
    let out = p.packetize(1, flags::KEYFRAME, &body(1, 600, true), 0).expect("packetize");
    assert!(out.datagrams.len() >= 3);
    for d in &out.datagrams[..out.datagrams.len() - 1] {
        let (h, payload) = DatagramHeader::decode(d).expect("decode");
        assert!(r.push(&h, payload, 0).is_empty());
    }
    let floor = outage_threshold_us(Some(8_000));
    keep_alive(&mut r, 0, floor);
    assert!(r.tick(floor).is_empty());
    assert!(r.take_losses().is_empty(), "given up before the outage threshold");
    keep_alive(&mut r, floor, floor + 1_000);
    assert!(r.tick(floor + 1_000).is_empty());
    assert_eq!(r.take_losses().len(), 1, "a real loss waits no longer than the threshold");
    assert!(r.need_recovery());
}

/// A link that stays silent past the pause gives the frame up after all.
#[test]
fn a_silence_longer_than_the_pause_still_gives_the_frame_up() {
    use cmux_rd_core::cc::OUTAGE_FREEZE_MAX_US;
    let mut p = Packetizer::new(0, 256);
    let mut r = Reassembler::new(200_000);
    r.set_path_rtt_us(Some(8_000));
    let out = p.packetize(1, flags::KEYFRAME, &body(1, 600, true), 0).expect("packetize");
    let (h, payload) = DatagramHeader::decode(&out.datagrams[0]).expect("decode");
    assert!(r.push(&h, payload, 0).is_empty());
    let at = r.next_expiry_us().expect("an expiry");
    assert!(at <= 200_000 + OUTAGE_FREEZE_MAX_US + 1, "expiry {at}");
    assert!(r.tick(at).is_empty());
    assert_eq!(r.take_losses().len(), 1);
    assert!(r.need_recovery());
}

/// A frame still arriving when its first NACK goes out: a gap that a later
/// shard exposes after that NACK must be requested at once, not held to the
/// frame's 50 ms retry cadence (screen-share +45 ms repair, 1% loss).
#[test]
fn a_gap_exposed_after_the_frames_first_nack_is_requested_without_the_retry_wait() {
    let mut p = Packetizer::new(0, 256);
    let sent = p.packetize(1, flags::KEYFRAME, &body(1, 5000, true), 0).expect("packetize");
    let n = sent.datagrams.len();
    assert!(n >= 16, "{n} shards");
    let mut r = Reassembler::new(1_000_000);
    r.set_gap_grace(true);
    // One shard every 500 us over ~10 ms; shards 3 and 12 are lost.
    let at = |i: usize| i as u64 * 500;
    for i in (0..n).filter(|&i| i != 3 && i != 12) {
        let (h, payload) = DatagramHeader::decode(&sent.datagrams[i]).expect("decode");
        r.push(&h, payload, at(i));
        if at(i) == 5_000 {
            // Gap 3 was seen at 2 ms (shard 4): its grace runs to 7 ms.
            assert!(r.take_nacks(5_000, 5_000, 50_000).is_empty());
        }
        if at(i) == 7_000 {
            // The first NACK, 5 ms after the gap was seen, carries the early gap.
            let first = r.take_nacks(7_000, 5_000, 50_000);
            assert_eq!(first.len(), 1);
            assert_eq!(first[0].indexes, vec![3]);
        }
    }
    // Shard 13 arrived at 6.5 ms and proved 12 missing.
    let exposed = at(13);
    let due = r.next_nack_us(5_000, 50_000).expect("frame still incomplete");
    assert!(due <= exposed + 5_000, "late gap NACK due at {due} us, exposed at {exposed} us");
    let late = r.take_nacks(exposed + 5_000, 5_000, 50_000);
    assert!(late.iter().any(|n| n.indexes.contains(&12)), "{late:?}");
}

/// One lost shard per frame at 1% loss: a gap the viewer first sees after the
/// frame's first NACK went out is asked for at once, not on the 50 ms retry of
/// the earlier request (that wait was the ~45 ms a lost shard cost on the fleet).
#[test]
fn a_gap_exposed_after_the_frames_first_nack_is_requested_at_once() {
    let mut p = Packetizer::new(0, 256);
    let sent = p.packetize(1, flags::KEYFRAME, &body(1, 2500, true), 0).expect("packetize");
    assert!(sent.datagrams.len() >= 9);
    let mut r = Reassembler::new(200_000);
    let push = |r: &mut Reassembler, i: usize, now: u64| {
        let (h, payload) = DatagramHeader::decode(&sent.datagrams[i]).expect("decode");
        r.push(&h, payload, now)
    };
    // Shard 1 is lost; shard 2 shows the gap.
    push(&mut r, 0, 0);
    push(&mut r, 2, 1_000);
    assert_eq!(r.next_nack_us(5_000, 50_000), Some(5_000));
    let first = r.take_nacks(5_000, 5_000, 50_000);
    assert_eq!(first.len(), 1);
    assert_eq!(first[0].indexes, vec![1]);
    // The frame keeps arriving; shard 6 is lost and shard 7 shows it at 9 ms.
    for (i, now) in [(3, 6_000), (4, 7_000), (5, 8_000), (7, 9_000)] {
        push(&mut r, i, now);
    }
    let due = r.next_nack_us(5_000, 50_000).expect("a gap waits");
    assert!(due <= 9_000, "the late gap waits for no retry: due at {due} us, exposed at 9000 us");
    let late = r.take_nacks(9_000, 5_000, 50_000);
    assert_eq!(late.len(), 1);
    assert_eq!(late[0].indexes, vec![6], "shard 1's request is not repeated before its retry");
    // The rest of the frame arrives; each shard keeps its own retry clock.
    for i in 8..sent.datagrams.len() {
        push(&mut r, i, 10_000);
    }
    assert_eq!(r.next_nack_us(5_000, 50_000), Some(55_000));
    assert!(r.take_nacks(54_999, 5_000, 50_000).is_empty());
    assert_eq!(r.take_nacks(55_000, 5_000, 50_000)[0].indexes, vec![1]);
    assert_eq!(r.next_nack_us(5_000, 50_000), Some(59_000));
}

/// With the RTT retry on, a lost repair is asked for again after a couple of
/// measured repair round trips (floored), not after the caller's 50 ms; off, the
/// retry stays the caller's cadence (today's behavior).
#[test]
fn rtt_nack_retry_follows_the_measured_repair_round_trip() {
    for on in [false, true] {
        let mut p = Packetizer::new(0, 256);
        let mut r = Reassembler::new(1_000_000);
        r.set_rtt_nack_retry(on);
        let push = |r: &mut Reassembler, d: &[u8], now: u64| {
            let (h, payload) = DatagramHeader::decode(d).expect("decode");
            r.push(&h, payload, now)
        };
        // Frame 1 loses shard 1; its repair comes back 1 ms after the request.
        let one = p.packetize(1, flags::KEYFRAME, &body(1, 1500, true), 0).expect("packetize");
        push(&mut r, &one.datagrams[0], 0);
        for d in &one.datagrams[2..] {
            push(&mut r, d, 500);
        }
        assert_eq!(r.take_nacks(5_000, 5_000, 50_000)[0].indexes, vec![1]);
        assert_eq!(push(&mut r, &one.datagrams[1], 6_000).len(), 1);
        assert_eq!(r.repair_rtt_us(), Some(1_000));
        // Frame 2 loses shard 1, and the repair of it too.
        let two = p.packetize(2, 0, &body(2, 1500, false), 0).expect("packetize");
        push(&mut r, &two.datagrams[0], 20_000);
        for d in &two.datagrams[2..] {
            push(&mut r, d, 20_500);
        }
        assert_eq!(r.take_nacks(25_000, 5_000, 50_000)[0].indexes, vec![1]);
        let retry = if on { 25_000 + NACK_RETRY_FLOOR_US } else { 75_000 };
        assert_eq!(r.next_nack_us(5_000, 50_000), Some(retry), "rtt retry {on}");
        assert_eq!(r.take_nacks(retry, 5_000, 50_000)[0].indexes, vec![1]);
        // The answer to a retried shard is ambiguous: no sample.
        assert_eq!(push(&mut r, &two.datagrams[1], retry + 1_000).len(), 1);
        assert_eq!(r.repair_rtt_us(), Some(1_000));
    }
}
