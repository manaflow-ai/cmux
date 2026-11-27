use cmux_cas::dedup::{Options, measure};

fn noise(seed: u64, n: usize) -> Vec<u8> {
    let mut x = seed;
    (0..n)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            x as u8
        })
        .collect()
}

#[test]
fn shared_chunks_are_counted_once_and_attributed_to_both_roots() {
    let a = tempfile::tempdir().unwrap();
    let b = tempfile::tempdir().unwrap();
    let common = noise(1, 2 << 20);
    std::fs::write(a.path().join("x"), &common).unwrap();
    std::fs::write(b.path().join("y"), &common).unwrap();
    // The same bytes with a prefix: whole-file dedup misses it, chunking finds all but the first chunk.
    let mut shifted = b"prefix".to_vec();
    shifted.extend_from_slice(&common);
    std::fs::write(b.path().join("z"), &shifted).unwrap();
    std::fs::write(a.path().join("own"), noise(2, 1 << 20)).unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(a.path().join("x"), a.path().join("link")).unwrap();

    let r = measure(
        &[("a".into(), a.path().into()), ("b".into(), b.path().into())],
        &Options { sample_every: 1, zstd_level: 3, threads: 4, public: None },
    );
    assert_eq!(r.files, 4, "symlink not followed");
    assert_eq!(r.logical, (2 << 20) * 3 + 6 + (1 << 20));
    assert_eq!(r.whole_file_physical, (2 << 20) + (2 << 20) + 6 + (1 << 20));
    assert!(r.physical < r.whole_file_physical);
    assert!(r.physical < (2 << 20) + (1 << 20) + 300_000, "physical {}", r.physical);
    let (ra, rb) = (&r.roots[0], &r.roots[1]);
    assert!(ra.shared >= (2 << 20) - 300_000 && ra.shared <= 2 << 20, "a shared {}", ra.shared);
    assert_eq!(ra.shared, rb.shared);
    assert!(r.zstd_ratio > 0.95, "noise does not compress: {}", r.zstd_ratio);
}

/// Allocation is exact on Unix and explicitly unavailable elsewhere.
#[test]
fn allocated_counts_hardlinks_portably() {
    let root = tempfile::tempdir().unwrap();
    let bytes = noise(3, 1 << 20);
    std::fs::write(root.path().join("x"), &bytes).unwrap();
    std::fs::hard_link(root.path().join("x"), root.path().join("x2")).unwrap();

    let r = measure(
        &[("root".into(), root.path().into())],
        &Options { sample_every: 1, zstd_level: 3, threads: 2, public: None },
    );
    assert_eq!(r.files, 2);
    assert_eq!(r.logical, (bytes.len() * 2) as u64);
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        let expected = std::fs::metadata(root.path().join("x")).unwrap().blocks() * 512;
        assert_eq!(r.allocated, Some(expected), "hardlink must count once");
    }
    #[cfg(not(unix))]
    {
        assert_eq!(r.allocated, None);
        assert!(serde_json::to_value(&r).unwrap()["allocated"].is_null());
    }
}

#[test]
fn sparse_file_allocation_is_never_replaced_with_length() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("sparse");
    let file = std::fs::File::create(&path).unwrap();
    file.set_len(1 << 20).unwrap();
    let r = measure(
        &[("root".into(), root.path().into())],
        &Options { sample_every: 0, ..Options::default() },
    );
    assert_eq!(r.logical, 1 << 20);
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        assert_eq!(r.allocated, Some(file.metadata().unwrap().blocks() * 512));
    }
    #[cfg(not(unix))]
    assert_eq!(r.allocated, None);
}
