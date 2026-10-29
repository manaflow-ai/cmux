//! A sequence that changes priority: an attach stream's view
//! drains at input priority while it is focused, utility while it is only
//! visible and background while it is hidden. Chrome moves a hidden
//! renderer's task runners the same way
//! (`UpdateableSequencedTaskRunner::UpdatePriority`,
//! base/task/updateable_sequenced_task_runner.h; ThreadPool's
//! `TaskSource::UpdatePriority` re-sorts the source in its new group,
//! base/task/thread_pool/thread_group.cc).

use super::{PoolState, Sequence, SequencePriority, Shared};

impl Sequence {
    /// Moves this sequence to `priority`: its queued and delayed tasks keep
    /// their order and run on `priority`'s workers from now on. A task
    /// running now finishes on its worker; the sequence's next task runs at
    /// `priority`. When no worker of `priority` is live and none can start,
    /// the sequence stays where it was.
    pub(crate) fn update_priority(&self, priority: SequencePriority) {
        let mut state = self.shared.lock();
        if state.shut_down {
            return;
        }
        let Some(sequence) = state.sequences.get_mut(&self.id) else { return };
        let old = sequence.priority;
        if old == priority {
            return;
        }
        // Ready: in its priority's ready list (not running, a task first).
        let ready = !sequence.running && sequence.tasks > 0;
        let has_delayed = move_sequence(&mut state, self.id, old, priority);
        // One worker of `priority` runs it, or recomputes its wait for the
        // moved delayed tasks.
        if (!ready && !has_delayed) || !self.shared.wake_or_reserve(&mut state, priority) {
            return;
        }
        if self.shared.spawn_worker_locked(&mut state, priority) || state.workers[priority].live > 0
        {
            return;
        }
        move_sequence(&mut state, self.id, priority, old);
        // The worker of `old` woken for it may have found its list empty.
        if ready {
            self.shared.wake_idle(&mut state, old);
        }
    }
}

impl Shared {
    /// After a task of sequence `id` ran on a worker of `worker`: when the
    /// sequence moved to another priority meanwhile and is ready again, a
    /// worker of that priority runs it (the worker that ran the task only
    /// takes its own priority's list).
    pub(super) fn wake_moved(
        self: &std::sync::Arc<Self>,
        state: &mut PoolState,
        id: u64,
        worker: SequencePriority,
    ) {
        let Some(sequence) = state.sequences.get(&id) else { return };
        let priority = sequence.priority;
        if priority == worker || sequence.running || sequence.tasks == 0 {
            return;
        }
        if self.wake_or_reserve(state, priority) {
            // A worker that cannot start is reported; the live ones run it.
            let _ = self.spawn_worker_locked(state, priority);
        }
    }

    /// Notifies one idle worker of `priority`, if there is one.
    fn wake_idle(&self, state: &mut PoolState, priority: SequencePriority) {
        let workers = &mut state.workers[priority];
        if workers.idle > workers.waking {
            workers.waking += 1;
            self.work[priority].notify_one();
        }
    }
}

/// Moves sequence `id` from `from` to `to`: its priority, its place in the
/// ready lists and its delayed tasks. True when it has delayed tasks.
fn move_sequence(
    state: &mut PoolState,
    id: u64,
    from: SequencePriority,
    to: SequencePriority,
) -> bool {
    if let Some(sequence) = state.sequences.get_mut(&id) {
        sequence.priority = to;
    }
    if let Some(position) = state.ready[from].iter().position(|ready| *ready == id) {
        state.ready[from].remove(position);
        state.ready[to].push_back(id);
    }
    let delayed = std::mem::take(&mut state.delayed[from]);
    let (moved, kept): (Vec<_>, Vec<_>) =
        delayed.into_vec().into_iter().partition(|task| task.sequence == id);
    state.delayed[from] = kept.into();
    let has_delayed = !moved.is_empty();
    state.delayed[to].extend(moved);
    has_delayed
}

#[cfg(test)]
#[path = "sequenced_pool_priority_tests.rs"]
mod tests;
