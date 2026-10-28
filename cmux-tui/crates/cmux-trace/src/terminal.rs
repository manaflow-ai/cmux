//! A terminal's trace number: the one `u64` every process's PTY records carry for a terminal (the
//! holder, the terminal host, the daemon), so a trace joins them without carrying the 16-byte id.

/// FNV-1a 64 of a terminal's 16 id bytes. Stable across processes and builds: the decoder may
/// recompute it from a terminal id it knows.
#[inline]
pub fn terminal_hash(id: &[u8; 16]) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in id {
        hash = (hash ^ u64::from(*byte)).wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

#[cfg(test)]
mod tests {
    use super::terminal_hash;

    #[test]
    fn terminal_hash_is_fnv1a_of_the_id_bytes() {
        // FNV-1a 64 of sixteen zero bytes and of 0..16, computed by the reference algorithm.
        assert_eq!(terminal_hash(&[0; 16]), 0x8820_1fb9_60ff_6465);
        let counting: [u8; 16] = std::array::from_fn(|index| index as u8);
        assert_eq!(terminal_hash(&counting), 0x7c84_dc94_7785_1775);
    }
}
