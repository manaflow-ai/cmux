//! Reports a source's state: at the first check, then whenever a later check reads another, until
//! stopped. Its owner checks on a tick it already runs (no observer, no timer); the app reads the
//! system's lock and display sleep and passes the reading in.

use crate::wire::SourceState;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SourceMonitor {
    last: Option<SourceState>,
    stopped: bool,
}

impl SourceMonitor {
    pub fn new() -> Self {
        Self::default()
    }

    /// The state the last check read; `None` before the first.
    pub fn state(&self) -> Option<SourceState> {
        self.last
    }

    /// Takes one reading; the state to report, if it changed (and the monitor runs).
    pub fn check(&mut self, reading: SourceState) -> Option<SourceState> {
        if self.stopped || self.last == Some(reading) {
            return None;
        }
        self.last = Some(reading);
        Some(reading)
    }

    pub fn stop(&mut self) {
        self.stopped = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reports_the_first_reading_then_changes_until_stopped() {
        let mut m = SourceMonitor::new();
        assert_eq!(m.state(), None);
        assert_eq!(m.check(SourceState::Live), Some(SourceState::Live));
        assert_eq!(m.check(SourceState::Live), None);
        assert_eq!(m.check(SourceState::from_flags(true, true)), Some(SourceState::Locked));
        m.stop();
        assert_eq!(m.check(SourceState::Asleep), None);
        assert_eq!(m.state(), Some(SourceState::Locked));
    }
}
