use super::pick_index;

#[test]
fn picks_main_index_and_display_id() {
    let ids = [1, 5, 17];
    assert_eq!(pick_index(&ids, 5, "main").unwrap(), 1);
    assert_eq!(pick_index(&ids, 5, "2").unwrap(), 2);
    assert!(pick_index(&ids, 5, "3").is_err());
    assert_eq!(pick_index(&ids, 5, "id:17").unwrap(), 2);
    // A run's display that is gone falls back to the main display.
    assert_eq!(pick_index(&ids, 5, "id:99").unwrap(), 1);
    assert!(pick_index(&ids, 5, "id:x").is_err());
    assert!(pick_index(&[], 5, "main").is_err());
}
