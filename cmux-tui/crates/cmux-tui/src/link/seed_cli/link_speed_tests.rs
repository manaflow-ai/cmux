use std::time::Duration;

use super::{DEFAULT_BUDGET_S, MIN_SAMPLE_BYTES, cap_for, next_rate};

const MIB: u64 = 1024 * 1024;

#[test]
fn the_cap_is_todays_until_a_rate_is_measured_and_a_pinned_one_always() {
    assert_eq!(cap_for(None, None, DEFAULT_BUDGET_S), 512 * MIB);
    // 100 MiB/s for a minute carries cmux's 690 MB pack the fixed cap refused.
    assert_eq!(cap_for(Some(100 * MIB), None, 60), 6000 * MIB);
    assert!(cap_for(Some(100 * MIB), None, 60) > 690_680_146);
    // 1 MiB/s: a 690 MB pack would take 11 minutes; the machine clones.
    assert!(cap_for(Some(MIB), None, 60) < 690_680_146);
    assert_eq!(cap_for(Some(MIB), Some(2048), 60), 2048 * MIB);
}

#[test]
fn a_rate_is_the_mean_of_samples_and_small_uploads_do_not_count() {
    assert_eq!(next_rate(None, MIB, Duration::from_secs(1)), None);
    assert_eq!(next_rate(Some(7), MIB, Duration::from_secs(1)), Some(7));
    let first = next_rate(None, 100 * MIB, Duration::from_secs(1));
    assert_eq!(first, Some(100 * MIB));
    assert_eq!(next_rate(first, 100 * MIB, Duration::from_secs(4)), Some(50 * MIB + 25 * MIB / 2));
    assert_eq!(
        next_rate(None, MIN_SAMPLE_BYTES, Duration::ZERO),
        Some(MIN_SAMPLE_BYTES * 1_000_000)
    );
}
