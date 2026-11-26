use super::*;

#[test]
fn the_look_is_ten_seconds_unless_the_environment_names_a_sane_one() {
    assert_eq!(look_from(None), LOOK);
    assert_eq!(look_from(Some("750")), Duration::from_millis(750));
    assert_eq!(look_from(Some("0")), LOOK);
    assert_eq!(look_from(Some("3600001")), LOOK);
    assert_eq!(look_from(Some("soon")), LOOK);
}
