use super::*;
use proptest::prelude::*;

#[test]
fn every_pane_ready_swaps_now() {
    for kind in [ShellKind::Image, ShellKind::Plain, ShellKind::Bare] {
        assert_eq!(swap_wait_ms(kind, 3, 3, 0), 0);
        assert_eq!(swap_wait_ms(kind, 0, 0, 0), 0);
    }
}

#[test]
fn bounds_per_kind() {
    assert_eq!(swap_wait_ms(ShellKind::Image, 2, 1, 0), 400);
    assert_eq!(swap_wait_ms(ShellKind::Image, 2, 1, 150), 250);
    assert_eq!(swap_wait_ms(ShellKind::Plain, 2, 0, 100), 50);
    assert_eq!(swap_wait_ms(ShellKind::Bare, 1, 0, 1_000), 500);
    assert_eq!(swap_wait_ms(ShellKind::Bare, 1, 0, 9_000), 0);
    assert_eq!(ShellKind::from_u8(9), ShellKind::Plain);
}

proptest! {
    #[test]
    fn never_past_the_bound(kind in 0u8..4, visible in 0u32..20, ready in 0u32..20, elapsed in 0u64..5_000) {
        let kind = ShellKind::from_u8(kind);
        let wait = swap_wait_ms(kind, visible, ready, elapsed);
        prop_assert!(wait <= kind.bound_ms().saturating_sub(elapsed));
        prop_assert!(ready < visible || wait == 0);
    }
}
