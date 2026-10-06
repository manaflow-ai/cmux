//! Which tabs of a shared headless browser run at full rate (chief,
//! 2026-10-06): a tab an agent session drove in the last [`HOT_FOR`] runs at
//! full rate; every other tab (kept tabs, tabs of sessions that went quiet)
//! is throttled, so a long-lived host does not pile up full-rate pages.
//! Pure state: the caller passes the time (an injected clock) and applies
//! the changes. No timer: a tab cools down at the next drive of any tab
//! (zero idle work); a host with no calls has no agent to slow down.

use std::collections::{HashMap, HashSet};
use std::time::{Duration, Instant};

/// How long a drive keeps a tab at full rate.
pub const HOT_FOR: Duration = Duration::from_secs(30);

#[derive(Debug, Default)]
pub struct Activity {
    last: HashMap<String, Instant>,
    throttled: HashSet<String>,
}

impl Activity {
    /// A session drove `target` at `now`: the changes to apply, as
    /// (tab, throttled).
    pub fn drove(&mut self, _target: &str, _now: Instant) -> Vec<(String, bool)> {
        Vec::new()
    }

    /// The tab closed.
    pub fn closed(&mut self, _target: &str) {}
}

#[cfg(test)]
mod tests {
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
}
