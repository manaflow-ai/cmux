//! FNV-1a, 64 bits: a hash that is the same in every process and on every
//! launch (std's hasher is seeded per process, so a saved fingerprint could
//! never match it again).

const OFFSET: u64 = 0xcbf2_9ce4_8422_2325;
const PRIME: u64 = 0x0000_0100_0000_01b3;

/// One running FNV-1a hash.
pub(crate) struct Fnv(u64);

impl Fnv {
    pub(crate) fn new() -> Self {
        Self(OFFSET)
    }

    pub(crate) fn bytes(&mut self, bytes: &[u8]) {
        for byte in bytes {
            self.0 ^= u64::from(*byte);
            self.0 = self.0.wrapping_mul(PRIME);
        }
    }

    pub(crate) fn u64(&mut self, value: u64) {
        self.bytes(&value.to_le_bytes());
    }

    /// A length-prefixed field, so ("ab", "c") and ("a", "bc") differ.
    pub(crate) fn field(&mut self, bytes: &[u8]) {
        self.u64(u64::try_from(bytes.len()).unwrap_or(u64::MAX));
        self.bytes(bytes);
    }

    pub(crate) fn finish(&self) -> u64 {
        self.0
    }
}

#[cfg(test)]
mod tests {
    use super::Fnv;

    #[test]
    fn matches_the_published_fnv1a_vectors() {
        let mut empty = Fnv::new();
        empty.bytes(b"");
        assert_eq!(empty.finish(), 0xcbf2_9ce4_8422_2325);
        let mut a = Fnv::new();
        a.bytes(b"a");
        assert_eq!(a.finish(), 0xaf63_dc4c_8601_ec8c);
        let mut foobar = Fnv::new();
        foobar.bytes(b"foobar");
        assert_eq!(foobar.finish(), 0x8594_4171_f739_67e8);
    }

    #[test]
    fn fields_are_length_prefixed() {
        let mut one = Fnv::new();
        one.field(b"ab");
        one.field(b"c");
        let mut two = Fnv::new();
        two.field(b"a");
        two.field(b"bc");
        assert_ne!(one.finish(), two.finish());
    }
}
