use super::{index_ids, loose_id};

#[test]
fn only_a_loose_objects_path_names_one() {
    let sha1 = format!(".git/objects/ab/{}", "c".repeat(38));
    let sha256 = format!(".git/objects/ab/{}", "c".repeat(62));
    assert_eq!(loose_id(&sha1), Some(format!("ab{}", "c".repeat(38))));
    assert_eq!(loose_id(&sha256), Some(format!("ab{}", "c".repeat(62))));
    for not in [
        ".git/objects/pack/pack-1.pack".to_string(),
        ".git/objects/info/packs".to_string(),
        format!(".git/objects/AB/{}", "c".repeat(38)),
        format!("src/objects/ab/{}", "c".repeat(38)),
        format!(".git/objects/ab/{}", "c".repeat(37)),
    ] {
        assert_eq!(loose_id(&not), None, "{not}");
    }
}

#[test]
fn a_bad_index_names_nothing() {
    assert_eq!(index_ids(b"", 20), None);
    assert_eq!(index_ids(&[0u8; 2000], 20), None);
    let mut header = b"\xfftOc\x00\x00\x00\x02".to_vec();
    header.extend(std::iter::repeat_n(0u8, 1024));
    // No objects: just the two trailing SHA-1 hashes.
    let mut empty = header.clone();
    empty.extend([0u8; 40]);
    assert_eq!(index_ids(&empty, 20), Some(Vec::new()));
    // Says one object, holds none.
    let mut short = header;
    if let Some(last) = short.get_mut(8 + 1023) {
        *last = 1;
    }
    assert_eq!(index_ids(&short, 20), None);
}
