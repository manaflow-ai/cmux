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
