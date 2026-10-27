//! cmux-wg's mesh decrypted-packet path (`cmux_wg::fuzzing::MeshPath`, which
//! calls the mesh driver's own `decrypted::receive_tagged`): the pacer's
//! segment parse, then the tagged TCP stack's SYN-origin bookkeeping
//! (`syn_flow`, bounded by `MAX_SYN_ORIGINS`) and smoltcp itself, with a
//! listener on the link port so SYNs open half-open sockets.
//!
//! Input: records of `[op u8][arg u8][len u16 LE][len bytes]`. Bits 0-1 of
//! `op` pick the session key (one of four peers). Bit 2 sends the packet
//! `arg * 8 + 1` times with the 16-bit word at offset 20 (the TCP source
//! port of an IPv4 packet with a 20-byte header) counting up, so a short
//! input can flood the origin map past its bound; otherwise `arg` moves the
//! clock forward in milliseconds. Bit 3 then lets the stack run.
//!
//! Checked: no panic or overflow in any of it, and the origin map never
//! holds more than `MAX_SYN_ORIGINS` entries.
#![no_main]

use std::time::Duration;

use cmux_wg::fuzzing::{MAX_SYN_ORIGINS, MeshPath};
use libfuzzer_sys::fuzz_target;

const PORT_WORD: usize = 20;

fuzz_target!(|data: &[u8]| {
    let mut path = MeshPath::new().expect("a mesh stack");
    let mut at = Duration::ZERO;
    let mut rest = data;
    while let Some(([op, arg, l0, l1], tail)) = rest.split_first_chunk::<4>() {
        let len = usize::from(u16::from_le_bytes([*l0, *l1])).min(tail.len());
        let (packet, next) = tail.split_at(len);
        rest = next;
        let key = [op & 3; 32];
        if op & 4 == 4 {
            let mut packet = packet.to_vec();
            let base = packet
                .get(PORT_WORD..PORT_WORD + 2)
                .map_or(0, |word| u16::from_be_bytes([word[0], word[1]]));
            for copy in 0..=u16::from(*arg) * 8 {
                if let Some(word) = packet.get_mut(PORT_WORD..PORT_WORD + 2) {
                    word.copy_from_slice(&base.wrapping_add(copy).to_be_bytes());
                }
                path.receive(&packet, key, at);
                assert!(path.syn_origins() <= MAX_SYN_ORIGINS);
            }
        } else {
            at += Duration::from_millis(u64::from(*arg));
            path.receive(packet, key, at);
        }
        assert!(path.syn_origins() <= MAX_SYN_ORIGINS);
        if op & 8 == 8 {
            path.step(at);
            assert!(path.syn_origins() <= MAX_SYN_ORIGINS);
        }
    }
});
