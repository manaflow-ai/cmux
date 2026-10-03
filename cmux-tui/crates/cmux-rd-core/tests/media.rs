//! FEC, packetizing and reassembly properties.

use cmux_rd_core::fec;
use cmux_rd_core::packetize::{Packetizer, parity_for};
use cmux_rd_core::reassembly::{FrameLoss, Reassembler};
use cmux_rd_proto::{DatagramHeader, FrameBody, MAX_DATAGRAM_DEFAULT, MAX_DATAGRAM_VPC, REF_NONE, flags};
use proptest::prelude::*;

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
        prop_assert!(out.datagrams.iter().all(|d| d.len() == max));
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
    let deliver = |r: &mut Reassembler, p: &mut Packetizer, frame: u32, keyframe: bool, skip: &[u16], now: u64| {
        let out = p
            .packetize(frame, if keyframe { flags::KEYFRAME } else { 0 }, &body(frame, 3000, keyframe), 0)
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
    let send = |r: &mut Reassembler, p: &mut Packetizer, frame: u32, b: FrameBody, f: u8, now: u64, lose_all: bool| {
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
fn parity_scales_with_loss() {
    assert_eq!(parity_for(10, 0.0, true), 0);
    assert_eq!(parity_for(10, 0.02, false), 1);
    assert_eq!(parity_for(10, 0.30, false), 5);
    assert_eq!(parity_for(1, 0.01, true), 1);
}
