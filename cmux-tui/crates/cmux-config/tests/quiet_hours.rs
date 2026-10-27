//! `time_range` values (Swift `QuietHours.minutes`): `"HH:MM"` in range, and
//! any other number refused without arithmetic on it (found by the
//! cmux-tui/fuzz `config_schema` target).

use cmux_config::text::quiet_hours_minutes;

#[test]
fn an_hour_and_minute_in_range_are_minutes_after_midnight() {
    assert_eq!(quiet_hours_minutes("22:00"), Some(22 * 60));
    assert_eq!(quiet_hours_minutes("07:30"), Some(7 * 60 + 30));
    assert_eq!(quiet_hours_minutes("+0:59"), Some(59));
}

#[test]
fn an_hour_out_of_range_is_refused_not_multiplied() {
    for text in
        ["-000000000000000040000000001064563953:220", "9223372036854775807:00", "24:00", "-1:00"]
    {
        assert_eq!(quiet_hours_minutes(text), None, "{text}");
    }
}
