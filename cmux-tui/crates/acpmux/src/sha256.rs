//! SHA-256 for the preset system prompt files' recorded hashes (the `sha2`
//! crate, already in the workspace).

use sha2::{Digest, Sha256};

/// The lowercase hex SHA-256 of `bytes`.
pub fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_vectors() {
        assert_eq!(
            sha256_hex(b""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        );
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
        // Lengths around the 56- and 64-byte padding boundaries.
        assert_eq!(
            sha256_hex(&[b'a'; 55]),
            "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"
        );
        assert_eq!(
            sha256_hex(&[b'a'; 56]),
            "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"
        );
        assert_eq!(
            sha256_hex(&[b'a'; 64]),
            "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"
        );
        assert_eq!(
            sha256_hex(&vec![b'a'; 1_000_000]),
            "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
        );
    }

    /// FIPS 180-4 / NIST CAVP examples: the 448-bit and 896-bit messages.
    #[test]
    fn nist_two_block_vectors() {
        assert_eq!(
            sha256_hex(b"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        );
        assert_eq!(
            sha256_hex(
                b"abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"
            ),
            "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1"
        );
    }

    /// Random inputs of 26 lengths (0 to 10007 bytes, around the 55/56 and
    /// 63/64/65 padding boundaries), digests from macOS `shasum -a 256`.
    #[test]
    fn matches_shasum_on_random_inputs() {
        let fixtures = include_str!("sha256_shasum.txt");
        let mut checked = 0;
        for line in fixtures.lines().filter(|l| !l.starts_with('#') && !l.is_empty()) {
            let parts: Vec<&str> = line.split(' ').collect();
            let len: usize = parts[0].parse().unwrap();
            let input: Vec<u8> = if parts[1] == "-" {
                Vec::new()
            } else {
                (0..parts[1].len())
                    .step_by(2)
                    .map(|i| u8::from_str_radix(&parts[1][i..i + 2], 16).unwrap())
                    .collect()
            };
            assert_eq!(input.len(), len);
            assert_eq!(sha256_hex(&input), parts[2], "{len} bytes");
            checked += 1;
        }
        assert!(checked >= 20, "{checked} fixtures");
    }
}
