//! Detector for design D6 (screen sharing under 100 ms): a frame over one FEC block (a
//! keyframe of more than 255 shards) keeps its parity on a lossy path, split across
//! interleaved blocks when the viewer offered cap `fec.blocks`. A lost shard in each block
//! is rebuilt at once: the frame is released with no NACK and no wait. A clean path still
//! sends no parity, and a one-datagram frame's copy is the idle-link copy (engine).

use cmux_rd_core::packetize::{Packetizer, parity_for};
use cmux_rd_core::reassembly::Reassembler;
use cmux_rd_proto::{
    DatagramHeader, FrameBody, MAX_DATAGRAM_VPC, MAX_FEC_BLOCK, REF_NONE, fec_block_of, fec_blocks,
    flags,
};

fn body(frame: u32, len: usize) -> FrameBody {
    FrameBody {
        t_capture_us: u64::from(frame) * 16_667,
        ref_frame: REF_NONE,
        ltr_token: None,
        access_unit: (0..len).map(|i| (i as u32 ^ (i as u32 >> 8) ^ frame) as u8).collect(),
    }
}

/// Pushes every datagram but those `lose` picks, at time 0; returns the frames released
/// and the NACKs the reassembler would send once the reorder grace has passed.
fn deliver(
    datagrams: &[Vec<u8>],
    lose: impl Fn(&DatagramHeader) -> bool,
) -> (Vec<FrameBody>, usize) {
    let mut r = Reassembler::new(200_000);
    let mut released = Vec::new();
    for d in datagrams {
        let (h, payload) = DatagramHeader::decode(d).expect("every shard header decodes");
        if !lose(&h) {
            released.extend(r.push(&h, payload, 0).into_iter().map(|f| f.body));
        }
    }
    let nacks = r.take_nacks(50_000, 5_000, 50_000).len();
    (released, nacks)
}

#[test]
fn a_frame_over_one_block_rebuilds_a_lost_shard_in_every_block() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    p.set_fec_blocks(true);
    // About 400 KB: a keyframe of more than 255 shards.
    let frame = body(1, 400_000);
    let data_shards = 400_000usize.div_ceil(p.shard_len());
    assert_eq!(parity_for(data_shards, 0.0, true), 0, "a clean path sends no parity");
    // One percent loss: the 10 % share.
    let out = p
        .packetize(1, flags::KEYFRAME, &frame, parity_for(data_shards, 0.01, true))
        .expect("packetize");
    let (count, fec_count) = (out.data_shards, out.parity_shards);
    assert!(usize::from(count) > MAX_FEC_BLOCK as usize, "the frame spans more than one block");
    assert!(fec_count > 0, "a frame over one block keeps its parity");
    let blocks = fec_blocks(count, fec_count);
    assert!(blocks > 1);
    // The first data shard of every block is lost.
    let (released, nacks) =
        deliver(&out.datagrams, |h| h.index < count && usize::from(h.index) < blocks);
    assert_eq!(released, vec![frame.clone()], "each block rebuilds its lost shard");
    assert_eq!(nacks, 0, "no resend is asked for");
    // A burst of consecutive data shards spreads over the interleaved blocks: each block
    // loses no more than its own parity.
    let per_block = usize::from(fec_count) / blocks;
    let burst = per_block * blocks;
    let (released, nacks) =
        deliver(&out.datagrams, |h| h.index >= 10 && usize::from(h.index) < 10 + burst);
    assert_eq!(released, vec![frame], "a burst of {burst} lost shards is rebuilt");
    assert_eq!(nacks, 0);
}

#[test]
fn a_block_that_lost_more_than_its_parity_waits_for_a_resend() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    p.set_fec_blocks(true);
    let frame = body(1, 400_000);
    let data_shards = 400_000usize.div_ceil(p.shard_len());
    let out = p
        .packetize(1, flags::KEYFRAME, &frame, parity_for(data_shards, 0.01, true))
        .expect("packetize");
    let (count, fec_count) = (out.data_shards, out.parity_shards);
    let blocks = fec_blocks(count, fec_count);
    // Block 0 loses one data shard more than it has parity; the others lose nothing.
    let block0_parity =
        (0..fec_count).filter(|&i| fec_block_of(count + i, count, blocks) == 0).count();
    let (released, nacks) = deliver(&out.datagrams, |h| {
        h.index < count
            && fec_block_of(h.index, count, blocks) == 0
            && usize::from(h.index) / blocks <= block0_parity
    });
    assert!(released.is_empty(), "too few shards in one block: not decodable");
    assert_eq!(nacks, 1, "the frame asks for its missing shards");
}

#[test]
fn a_viewer_without_the_cap_never_gets_a_frame_over_one_block_with_parity() {
    let mut p = Packetizer::new(0, MAX_DATAGRAM_VPC);
    let frame = body(1, 400_000);
    let data_shards = 400_000usize.div_ceil(p.shard_len());
    let out = p
        .packetize(1, flags::KEYFRAME, &frame, parity_for(data_shards, 0.01, true))
        .expect("packetize");
    assert_eq!(out.parity_shards, 0, "an older viewer refuses parity over one block");
    // A frame that fits one block keeps the parity that fits.
    let small = body(2, 250 * p.shard_len() - 64);
    let out = p.packetize(2, 0, &small, parity_for(250, 0.01, false)).expect("packetize");
    assert!(
        usize::from(out.data_shards) + usize::from(out.parity_shards) <= MAX_FEC_BLOCK as usize
    );
    assert!(out.parity_shards > 0);
}
