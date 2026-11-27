use super::*;

const GB: u64 = 1 << 30;

#[test]
fn lucas_machine_is_overloaded_on_both_counts() {
    let v = evaluate(Some(290.0), 15, Some(21_300 * (GB / 1000)), Some(22_500 * (GB / 1000)));
    assert!(v.load_over && v.swap_over && v.overloaded());
    assert_eq!(v.swap_percent(), Some(95));
    assert_eq!(v.to_json()["load1"], json!(290.0));
}

#[test]
fn load_threshold_is_five_per_core_exclusive() {
    assert!(!evaluate(Some(75.0), 15, None, None).overloaded());
    assert!(evaluate(Some(75.1), 15, None, None).load_over);
    assert!(!evaluate(Some(40.0), 8, None, None).overloaded());
    assert!(evaluate(Some(41.0), 8, None, None).overloaded());
}

#[test]
fn swap_threshold_is_eighty_percent_exclusive() {
    assert!(!evaluate(None, 8, Some(80), Some(100)).overloaded());
    assert!(evaluate(None, 8, Some(81), Some(100)).swap_over);
    assert!(!evaluate(None, 8, Some(5), Some(0)).overloaded(), "no swap is not full swap");
}

#[test]
fn missing_readings_are_never_over() {
    assert!(!evaluate(None, 0, None, None).overloaded());
    assert_eq!(evaluate(None, 4, None, None).swap_percent(), None);
}

#[test]
fn the_fake_reading_parses() {
    let v = parse_fake("290, 15, 95").unwrap();
    assert!(v.overloaded());
    assert_eq!(v.cores, 15);
    assert_eq!(v.swap_percent(), Some(95));
    assert!(parse_fake("290,15").is_none());
    assert!(!parse_fake("2,15,10").unwrap().overloaded());
}
