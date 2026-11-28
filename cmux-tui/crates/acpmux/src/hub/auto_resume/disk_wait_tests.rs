use super::*;

#[test]
fn a_disk_with_room_holds_nothing_and_a_floor_past_its_size_holds() {
    let dir = std::env::temp_dir();
    assert!(!short_of(&dir, 0));
    assert!(short_of(&dir, u64::MAX));
    assert!(!short_of(Path::new("/nonexistent/acpmux-disk-wait"), u64::MAX));
}

#[test]
fn it_rechecks_every_15_s_or_sooner_when_the_first_wait_is_shorter() {
    assert_eq!(recheck_ms(None), RECHECK_MS);
    assert_eq!(recheck_ms(Some(&[20, 20])), 20);
    assert_eq!(recheck_ms(Some(&[60_000])), RECHECK_MS);
    assert_eq!(recheck_ms(Some(&[])), RECHECK_MS);
}
