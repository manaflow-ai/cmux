//! How long the real launch window stays under stage 0 before it swaps in. Swapping at the real
//! window's first commit showed its panes blank and then filling in (their saved pictures not yet
//! drawn): a layout shift in time. The window now waits until every visible pane is ready (its
//! launch read ended and it shows saved or live content), bounded per stage-0 kind so a stuck
//! pane never holds the launch.
use serde::{Deserialize, Serialize};

/// What stage 0 showed.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[repr(u8)]
pub enum ShellKind {
    /// The window's saved picture: the swap must land on the same picture, so it may wait longest
    /// of the drawn kinds.
    Image = 0,
    /// The plain shell (background and bar only): little to match, a short wait.
    Plain = 1,
    /// The bare launch (Home): today's bound for it.
    Bare = 2,
}

impl ShellKind {
    /// Unknown values read as `Plain`: the shortest wait, never a hold.
    pub fn from_u8(v: u8) -> Self {
        match v {
            0 => Self::Image,
            2 => Self::Bare,
            _ => Self::Plain,
        }
    }

    /// The longest the real window waits under stage 0, from when stage 0 showed.
    pub fn bound_ms(self) -> u64 {
        match self {
            Self::Image => 400,
            Self::Plain => 150,
            Self::Bare => 1_500,
        }
    }
}

/// Milliseconds more to wait before the swap; 0 means swap now. Now when every visible pane is
/// ready (no visible pane counts as all ready); otherwise the rest of the kind's bound, never more.
pub fn swap_wait_ms(kind: ShellKind, visible_panes: u32, panes_ready: u32, elapsed_ms: u64) -> u64 {
    if panes_ready >= visible_panes {
        return 0;
    }
    kind.bound_ms().saturating_sub(elapsed_ms)
}

#[cfg(test)]
mod tests {
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
}
