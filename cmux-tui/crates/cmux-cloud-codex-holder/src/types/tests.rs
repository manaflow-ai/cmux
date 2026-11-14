use super::*;

#[test]
fn a_timer_never_panics() {
    assert_eq!(wait(f64::NAN), Duration::ZERO);
    assert_eq!(wait(-1.0), Duration::ZERO);
    assert_eq!(wait(1e300), LONGEST_WAIT);
    assert_eq!(wait(f64::INFINITY), LONGEST_WAIT);
    assert_eq!(wait(2.5), Duration::from_millis(2500));
}

#[test]
fn only_a_finite_expiry_before_2100_is_valid() {
    assert!(valid_expiry(2_147_483_647.0));
    for bad in [0.0, -1.0, f64::NAN, f64::INFINITY, 1e300, LATEST_EXPIRY] {
        assert!(!valid_expiry(bad), "{bad}");
    }
}
