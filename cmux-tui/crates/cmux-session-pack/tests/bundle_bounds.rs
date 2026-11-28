use cmux_session_pack::{Manifest, Params, Store, pack, ship};
use std::collections::HashSet;
use std::io::{self, Read};

struct ShortReader<'a>(&'a [u8]);

impl Read for ShortReader<'_> {
    fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
        // A tiny input must never be handed a buffer sized from its large header.
        assert!(out.len() <= 64 << 10, "header-sized allocation: {}", out.len());
        let n = out.len().min(self.0.len()).min(3);
        out[..n].copy_from_slice(&self.0[..n]);
        self.0 = &self.0[n..];
        Ok(n)
    }
}

#[test]
fn truncated_bodies_below_the_caps_do_not_preallocate_the_declared_length() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::new(dir.path());
    for len in [1u32, 64 << 10, 128 << 20, (128 << 20) + 1, u32::MAX] {
        let mut bytes = b"CSPB1\n".to_vec();
        bytes.extend_from_slice(&len.to_le_bytes());
        assert!(ship::unbundle(&store, &mut ShortReader(&bytes), ship::Lacking::Refuse).is_err());
    }
    for len in [1u32, 64 << 10, 256 << 20, (256 << 20) + 6, u32::MAX] {
        let mut bytes = b"CSPB1\n\0\0\0\0".to_vec();
        bytes.extend_from_slice(&[0; 32]);
        bytes.extend_from_slice(&len.to_le_bytes());
        assert!(ship::unbundle(&store, &mut ShortReader(&bytes), ship::Lacking::Refuse).is_err());
    }
}

#[test]
fn mutated_lengths_and_truncations_never_replace_the_manifest() {
    let dir = tempfile::tempdir().unwrap();
    let source = Store::new(dir.path().join("source"));
    let target = Store::new(dir.path().join("target"));
    let log = dir.path().join("log.ndjson");
    std::fs::write(&log, b"old session\n").unwrap();
    let (old, _) =
        pack(&target, "s", std::slice::from_ref(&log), &Params::default(), false).unwrap();
    std::fs::write(&log, b"new session with different bytes\n").unwrap();
    let (new, _) = pack(&source, "s", &[log], &Params::default(), false).unwrap();
    let mut valid = Vec::new();
    ship::bundle(&source, "s", &HashSet::new(), &mut valid).unwrap();
    let length_at =
        |offset: usize| u32::from_le_bytes(valid[offset..offset + 4].try_into().unwrap()) as usize;
    let mut lengths = vec![6];
    let mut offset = 10 + length_at(6);
    while offset < valid.len() {
        lengths.push(offset + 32);
        offset += 36 + length_at(offset + 32);
    }
    let unchanged = || assert_eq!(Manifest::load(&target, "s").unwrap(), Some(old.clone()));
    for end in 0..valid.len() {
        assert!(
            ship::unbundle(&target, &mut ShortReader(&valid[..end]), ship::Lacking::Refuse)
                .is_err(),
            "cut {end}"
        );
        unchanged();
    }
    for offset in lengths {
        for len in [0u32, 1, 64 << 10, 128 << 20, 256 << 20, u32::MAX] {
            let mut bad = valid.clone();
            bad[offset..offset + 4].copy_from_slice(&len.to_le_bytes());
            assert!(
                ship::unbundle(&target, &mut ShortReader(&bad), ship::Lacking::Refuse).is_err(),
                "offset {offset}, length {len}"
            );
            unchanged();
        }
    }
    assert_eq!(
        ship::unbundle(&target, &mut ShortReader(&valid), ship::Lacking::Refuse).unwrap(),
        Some(new)
    );
}
