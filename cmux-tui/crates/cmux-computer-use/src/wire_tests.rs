use super::*;

#[test]
fn hex_round_trip_and_secret_compare() {
    let s = [1u8, 0xab, 0xff];
    assert_eq!(unhex(&hex(&s)).unwrap(), s);
    assert!(unhex("abc").is_none() && unhex("zz").is_none());
    assert!(same_secret(&s, &s) && !same_secret(&s, &[1, 0xab]));
}
