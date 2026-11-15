use super::*;

fn policy(timed: i64, socket: i64) -> CmuxRetryPolicy {
    CmuxRetryPolicy::new(250_000_000, 30_000_000_000, timed, socket, false)
}

#[test]
fn spacing_doubles_to_the_cap_with_no_jitter_at_the_middle_draw() {
    let p = policy(10, 3);
    let spaced: Vec<u64> = (0..10).map(|a| p.spacing_ns(a, 0.5)).collect();
    assert_eq!(
        spaced,
        vec![
            250_000_000,
            500_000_000,
            1_000_000_000,
            2_000_000_000,
            4_000_000_000,
            8_000_000_000,
            16_000_000_000,
            30_000_000_000,
            30_000_000_000,
            30_000_000_000
        ]
    );
    // The floor: 80 % of initial; the ceiling: the cap.
    assert_eq!(p.spacing_ns(0, 0.0), 200_000_000);
    assert_eq!(p.spacing_ns(20, 1.0), 30_000_000_000);
}

#[test]
fn a_zero_initial_is_corrected() {
    let p = CmuxRetryPolicy::new(0, 0, 1, 3, false);
    assert_eq!((p.initial_ns, p.maximum_ns), (100_000_000, 100_000_000));
}
