//! Part of `Hub`; see `hub/mod.rs`. Whether a starting harness still works (`StartWatch`), and
//! the errors a start ends with when it hangs or misses its deadline.

use super::*;

/// How long a start that waits on its harness (`Session::wait_start`) lets the harness use no CPU
/// with no thread ready before it ends the start: minutes, since a harness on a loaded host waits
/// on its disk, but one that truly works moves its CPU time within them.
pub(super) const START_HUNG: std::time::Duration = std::time::Duration::from_secs(5 * 60);

/// Whether a start's harness still works (`HarnessState::worked_since`, over its whole process
/// tree): a thread on a CPU, CPU time, a page read in or a process started since the last read. A
/// loaded host or short memory slows that down, it does not stop it. A harness not spawned yet,
/// or one whose state cannot be read (not macOS), is never called hung here: its creator's own
/// wait bounds that.
#[derive(Default)]
pub(super) struct StartWatch {
    /// The read the next is judged against, and when it was taken. Kept until a later read
    /// shows work or a [`WORK_WINDOW`](crate::cpu_class::WORK_WINDOW) has passed, so a short tick
    /// sums a launcher's runtime ticks over a whole window instead of judging each alone.
    last: Option<(crate::cpu_class::HarnessState, std::time::Duration)>,
    idle_since: Option<std::time::Duration>,
}

impl StartWatch {
    /// `seen` at `waited` into the start: whether its harness has not worked for `START_HUNG`.
    pub(super) fn hung(
        &mut self,
        seen: &crate::cpu_class::HarnessSeen,
        waited: std::time::Duration,
    ) -> bool {
        let crate::cpu_class::HarnessSeen::Running(state) = seen else {
            self.last = None;
            self.idle_since = None;
            return false;
        };
        let (worked, window_passed) = match &self.last {
            None => (true, true),
            Some((last, at)) => {
                let between = waited.saturating_sub(*at);
                (state.worked_since(last, between), between >= crate::cpu_class::WORK_WINDOW)
            }
        };
        if worked || window_passed {
            self.last = Some((state.clone(), waited));
        }
        if worked {
            self.idle_since = None;
            return false;
        }
        waited.saturating_sub(*self.idle_since.get_or_insert(waited)) >= START_HUNG
    }
}

#[cfg(test)]
#[path = "start_watch_tests.rs"]
mod start_watch_tests;

/// The error of a start whose harness did no work for `START_HUNG` (`StartWatch`): it waits on
/// something no wait cures (input, a lock, a sign-in prompt). Not retryable on this harness (it
/// is ended), and worded apart from a deadline so its creator does not wait on it again: Chief
/// tries a fresh harness through its reply ledger and, if none starts, says so (#36028).
pub(super) fn start_hung(harness: &crate::cpu_class::HarnessSeen) -> RpcError {
    let mut e = RpcError::new(
        -32000,
        format!("agent_start: its agent did no work for {} s", START_HUNG.as_secs()),
    )
    .with_data(json!({"reason": "harness_hung", "retryable": false}));
    e.message.push_str(&harness.detail());
    if let (crate::cpu_class::HarnessSeen::Running(state), Some(data)) =
        (harness, e.data.as_mut().and_then(Value::as_object_mut))
    {
        data.insert("harness".into(), json!(state));
    }
    e
}

/// `agent_start`'s deadline error, with what its harness was doing (`cpu_class.rs`, item 4).
/// Its `data.harness` carries the same fields when they were read.
pub(super) fn start_deadline_exceeded(
    budget: std::time::Duration,
    harness: &crate::cpu_class::HarnessSeen,
) -> RpcError {
    let mut e = RpcError::deadline_exceeded("agent_start", budget);
    e.message.push_str(&harness.detail());
    if let (crate::cpu_class::HarnessSeen::Running(state), Some(data)) =
        (harness, e.data.as_mut().and_then(Value::as_object_mut))
    {
        data.insert("harness".into(), json!(state));
    }
    e
}
