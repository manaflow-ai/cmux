//! The liveness of a connection. A daemon that stops answering keeps its
//! socket open (an owner stopped with SIGSTOP or wedged in its main loop), so
//! no EOF ends the connection. Every interval the app asks the daemon
//! `identify`; `misses` unanswered asks in a row mark it not answering, and
//! the next answer clears it.
//!
//! No client clock ends a live daemon's connection: a local connection whose
//! daemon process is alive stays open and keeps its pending requests; only a
//! connection whose daemon this Mac cannot see (a bridge), or whose process
//! exited, closes after its misses.
//!
//! [`CmuxHeartbeat`] is the state under the app's lock; the timer, the ask and
//! the observer stay in the app.

/// The heartbeat's state: unanswered asks in a row, the run they belong to
/// (a reconnect starts a new run) and whether the daemon answers.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CmuxHeartbeat {
    pub misses: i64,
    pub run: u64,
    pub answering: bool,
}

impl Default for CmuxHeartbeat {
    fn default() -> Self {
        Self { misses: 0, run: 0, answering: true }
    }
}

/// What the app does after one ask.
#[repr(C)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct CmuxHeartbeatStep {
    /// 0: the run is over (a later start or a stop): do nothing more.
    /// 1: close the transport (missed, and its daemon is not alive).
    /// 2: schedule the next ask.
    pub action: u32,
    /// Tell the observer `answering`.
    pub tell: bool,
    pub answering: bool,
}

pub const STEP_STALE: u32 = 0;
pub const STEP_CLOSE: u32 = 1;
pub const STEP_CONTINUE: u32 = 2;

impl CmuxHeartbeat {
    /// Sets `answering` for `run` (any run when `None`); whether the observer
    /// is told: on a change, and at every unanswered ask past the misses.
    pub fn set_answering(&mut self, answering: bool, run: Option<u64>) -> bool {
        if run.is_some_and(|run| run != self.run) {
            return false;
        }
        let changed = self.answering != answering;
        self.answering = answering;
        changed || !answering
    }

    /// A new run (a connect): its number, and whether the observer is told
    /// `answering` true.
    pub fn start(&mut self) -> (u64, bool) {
        self.misses = 0;
        self.run = self.run.wrapping_add(1);
        let tell = self.set_answering(true, None);
        (self.run, tell)
    }

    /// Ends the run; whether the observer is told `answering` true.
    pub fn stop(&mut self) -> bool {
        self.run = self.run.wrapping_add(1);
        self.set_answering(true, None)
    }

    /// One ask of `run` ended (`answered`), with the misses limit and whether
    /// the daemon's process is alive (a bridged connection: false).
    pub fn tick(
        &mut self,
        run: u64,
        answered: bool,
        limit: i64,
        peer_alive: bool,
    ) -> CmuxHeartbeatStep {
        let stale =
            CmuxHeartbeatStep { action: STEP_STALE, tell: false, answering: self.answering };
        if run != self.run {
            return stale;
        }
        self.misses = if answered { 0 } else { self.misses.saturating_add(1) };
        let missed = self.misses >= limit;
        if missed && !peer_alive {
            return CmuxHeartbeatStep {
                action: STEP_CLOSE,
                tell: false,
                answering: self.answering,
            };
        }
        let tell = (answered || missed) && self.set_answering(answered, Some(run));
        CmuxHeartbeatStep { action: STEP_CONTINUE, tell, answering: self.answering }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn misses_mark_not_answering_while_alive_and_an_answer_clears_it() {
        let mut beat = CmuxHeartbeat::default();
        let (run, tell) = beat.start();
        assert!(!tell);
        assert_eq!(
            beat.tick(run, false, 2, true),
            CmuxHeartbeatStep { action: 2, tell: false, answering: true }
        );
        assert_eq!(
            beat.tick(run, false, 2, true),
            CmuxHeartbeatStep { action: 2, tell: true, answering: false }
        );
        // Past the misses each unanswered ask tells again.
        assert_eq!(
            beat.tick(run, false, 2, true),
            CmuxHeartbeatStep { action: 2, tell: true, answering: false }
        );
        assert_eq!(
            beat.tick(run, true, 2, true),
            CmuxHeartbeatStep { action: 2, tell: true, answering: true }
        );
        assert_eq!(
            beat.tick(run, true, 2, true),
            CmuxHeartbeatStep { action: 2, tell: false, answering: true }
        );
    }

    #[test]
    fn a_dead_peer_closes_and_a_stale_run_does_nothing() {
        let mut beat = CmuxHeartbeat::default();
        let (run, _) = beat.start();
        assert_eq!(beat.tick(run, false, 1, false).action, STEP_CLOSE);
        assert!(!beat.stop());
        assert_eq!(beat.tick(run, false, 1, true).action, STEP_STALE);
    }
}
