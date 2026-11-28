use super::failed_at;

#[test]
fn failed_at_names_the_first_step_missed() {
    assert_eq!(failed_at(false, false, false, false, false), Some("the host printed no key"));
    assert_eq!(failed_at(true, false, false, false, false), Some("the link did not come up"));
    assert_eq!(failed_at(true, true, false, true, true), Some("no welcome from the host"));
    assert_eq!(failed_at(true, true, true, false, false), Some("no media from the host"));
    assert_eq!(failed_at(true, true, true, true, false), Some("the host printed no ended line"));
    assert_eq!(failed_at(true, true, true, true, true), None);
}
