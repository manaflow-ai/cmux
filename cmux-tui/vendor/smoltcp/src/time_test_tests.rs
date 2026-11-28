use super::*;

#[test]
fn test_instant_ops() {
    // std::ops::Add
    assert_eq!(
        Instant::from_millis(4) + Duration::from_millis(6),
        Instant::from_millis(10)
    );
    // std::ops::Sub
    assert_eq!(
        Instant::from_millis(7) - Duration::from_millis(5),
        Instant::from_millis(2)
    );
}

#[test]
fn test_instant_getters() {
    let instant = Instant::from_millis(5674);
    assert_eq!(instant.secs(), 5);
    assert_eq!(instant.millis(), 674);
    assert_eq!(instant.total_millis(), 5674);
}

#[test]
fn test_instant_display() {
    assert_eq!(format!("{}", Instant::from_millis(74)), "0.074s");
    assert_eq!(format!("{}", Instant::from_millis(5674)), "5.674s");
    assert_eq!(format!("{}", Instant::from_millis(5000)), "5.000s");
}

#[test]
#[cfg(feature = "std")]
fn test_instant_conversions() {
    let mut epoc: ::std::time::SystemTime = Instant::from_millis(0).into();
    assert_eq!(
        Instant::from(::std::time::UNIX_EPOCH),
        Instant::from_millis(0)
    );
    assert_eq!(epoc, ::std::time::UNIX_EPOCH);
    epoc = Instant::from_millis(2085955200i64 * 1000).into();
    assert_eq!(
        epoc,
        ::std::time::UNIX_EPOCH + ::std::time::Duration::from_secs(2085955200)
    );
}

#[test]
#[cfg(feature = "std")]
fn test_instant_conversions_from_std_instant() {
    let std_now = ::std::time::Instant::now();

    let before = Instant::from(std_now);
    ::std::thread::sleep(::std::time::Duration::from_millis(5));
    let after = Instant::from(std_now);

    assert_eq!(
        before, after,
        "converting the same std Instant twice should yield the same result"
    );
}

#[test]
fn test_duration_ops() {
    // std::ops::Add
    assert_eq!(
        Duration::from_millis(40) + Duration::from_millis(2),
        Duration::from_millis(42)
    );
    // std::ops::Sub
    assert_eq!(
        Duration::from_millis(555) - Duration::from_millis(42),
        Duration::from_millis(513)
    );
    // std::ops::Mul
    assert_eq!(Duration::from_millis(13) * 22, Duration::from_millis(286));
    // std::ops::Div
    assert_eq!(Duration::from_millis(53) / 4, Duration::from_micros(13250));
}

#[test]
fn test_duration_assign_ops() {
    let mut duration = Duration::from_millis(4735);
    duration += Duration::from_millis(1733);
    assert_eq!(duration, Duration::from_millis(6468));
    duration -= Duration::from_millis(1234);
    assert_eq!(duration, Duration::from_millis(5234));
    duration *= 4;
    assert_eq!(duration, Duration::from_millis(20936));
    duration /= 5;
    assert_eq!(duration, Duration::from_micros(4187200));
}

#[test]
#[should_panic(expected = "overflow when subtracting durations")]
fn test_sub_from_zero_overflow() {
    let _ = Duration::from_millis(0) - Duration::from_millis(1);
}

#[test]
#[should_panic(expected = "attempt to divide by zero")]
fn test_div_by_zero() {
    let _ = Duration::from_millis(4) / 0;
}

#[test]
fn test_duration_getters() {
    let instant = Duration::from_millis(4934);
    assert_eq!(instant.secs(), 4);
    assert_eq!(instant.millis(), 934);
    assert_eq!(instant.total_millis(), 4934);
}

#[test]
fn test_duration_conversions() {
    let mut std_duration = ::core::time::Duration::from_millis(4934);
    let duration: Duration = std_duration.into();
    assert_eq!(duration, Duration::from_millis(4934));
    assert_eq!(Duration::from(std_duration), Duration::from_millis(4934));

    std_duration = duration.into();
    assert_eq!(std_duration, ::core::time::Duration::from_millis(4934));
}
