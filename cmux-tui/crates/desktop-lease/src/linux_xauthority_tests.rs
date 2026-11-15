use super::xauthority_entry;

#[test]
fn the_entry_is_one_wild_mit_magic_cookie_record_for_the_display() {
    let cookie = [7u8; 16];
    let entry = xauthority_entry(301, &cookie);
    let mut want = vec![0xff, 0xff, 0, 0, 0, 3];
    want.extend_from_slice(b"301");
    want.extend_from_slice(&[0, 18]);
    want.extend_from_slice(b"MIT-MAGIC-COOKIE-1");
    want.extend_from_slice(&[0, 16]);
    want.extend_from_slice(&cookie);
    assert_eq!(entry, want);
}
