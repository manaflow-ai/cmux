use super::*;

#[test]
fn a_quiet_tab_is_throttled_at_the_next_drive_and_wakes_when_driven() {
    let start = Instant::now();
    let mut activity = Activity::default();
    assert_eq!(activity.drove("a", start), vec![]);
    assert_eq!(activity.drove("b", start + Duration::from_secs(10)), vec![]);
    // a went quiet for more than HOT_FOR; b did not.
    let later = start + HOT_FOR + Duration::from_secs(5);
    assert_eq!(activity.drove("b", later), vec![("a".to_owned(), true)]);
    // Driving a wakes it.
    assert_eq!(activity.drove("a", later), vec![("a".to_owned(), false)]);
    // Nothing changes twice.
    assert_eq!(activity.drove("a", later), vec![]);
}

#[test]
fn closed_tabs_are_forgotten() {
    let start = Instant::now();
    let mut activity = Activity::default();
    activity.drove("a", start);
    activity.closed("a");
    assert_eq!(activity.drove("b", start + HOT_FOR * 2), vec![]);
    assert!(activity.last.len() == 1 && activity.throttled.is_empty());
}
