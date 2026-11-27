use super::*;

#[test]
fn names_compressed_by_magic_even_with_a_text_name() {
    assert_eq!(classify("a.txt", &[0x1f, 0x8b, 8, 0]), Kind::Compressed);
    assert_eq!(classify("objects/pack/x.idx", b"PACK\0\0\0\x02"), Kind::Compressed);
    assert_eq!(classify("v", b"\0\0\0\x20ftypisom"), Kind::Compressed);
}

#[test]
fn groups_text() {
    assert_eq!(classify("a.ts", b"export const"), Kind::Text(TextGroup::Script));
    assert_eq!(classify("Cargo.lock", b"[[package]]"), Kind::Text(TextGroup::Json));
    assert_eq!(classify("LICENSE", b"MIT License"), Kind::Text(TextGroup::Other));
    assert_eq!(classify("a.out", b"\x7fELF\x02\x01\x01\0"), Kind::Binary);
}
