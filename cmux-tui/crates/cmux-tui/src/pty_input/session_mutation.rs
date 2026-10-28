//! Session mutations run off the echo thread.
//!
//! A session mutation (a split, a close, a divider drag's ratio, a zoom) is
//! blocking work: for a local session the mux commits it to the workspace
//! registry (SQLite), for a remote one the client waits for the daemon's
//! reply. `mux-pty-input` is an echo thread with blocking disallowed (Chrome's
//! display-critical thread with `DisallowBlocking()`), so it hands each one to
//! `mux-session-mutation`, a thread that may block, as it hands acknowledged
//! surface operations to `mux-surface-operation`. The mutation stays the
//! queue's global barrier: `mux-pty-input` dequeues nothing while it is in
//! flight (`QueueState::in_flight`), so later input still waits for it and
//! the input before it has already been written.

use super::*;

/// The thread that runs session mutations (plans/cmux-next/threading-model.md).
pub(super) const THREAD_NAME: &str = "mux-session-mutation";

/// Whether `event` is a session mutation: a queue-wide barrier, not an
/// operation on one surface's lane.
pub(super) fn is_session_mutation(event: &PtyInputEvent) -> bool {
    event.kind == PtyInputKind::Mutation && !event.concurrent_surface_operation
}

/// Starts the session mutation thread of `queue`. The person waits for its
/// work (the layout they changed), so it runs user-initiated, as the
/// daemon's request threads do.
pub(super) fn spawn(
    queue: Arc<SharedQueue>,
    on_failure: Arc<dyn Fn(PtyOperationFailure) + Send + Sync>,
) -> std::io::Result<JoinHandle<()>> {
    cmux_threads::spawn(THREAD_NAME, cmux_threads::ThreadQos::UserInitiated, move || {
        run(&queue, &on_failure);
    })
}

/// Gives `event`, just dequeued as the queue's in-flight event, to the
/// session mutation thread.
pub(super) fn hand_off(queue: &SharedQueue, event: PtyInputEvent) {
    let mut state = queue.state.lock().unwrap();
    debug_assert!(state.session_mutation.is_none(), "one session mutation is in flight at a time");
    state.session_mutation = Some(event);
    queue.session_mutation_ready.notify_one();
}

/// Held by `mux-pty-input` for its life: when it returns (nothing in flight
/// and the queue closed) or panics, `mux-session-mutation` gets no more
/// events and ends too.
pub(super) struct WorkerDone(pub(super) Arc<SharedQueue>);

impl Drop for WorkerDone {
    fn drop(&mut self) {
        let mut state = self.0.state.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        state.workers_done = true;
        self.0.session_mutation_ready.notify_all();
    }
}

fn run(queue: &Arc<SharedQueue>, on_failure: &Arc<dyn Fn(PtyOperationFailure) + Send + Sync>) {
    loop {
        let event = {
            let mut state = queue.state.lock().unwrap();
            loop {
                if let Some(event) = state.session_mutation.take() {
                    break event;
                }
                if state.workers_done {
                    return;
                }
                // The thread's own next event: an idle wait, never a
                // blocking call.
                state = queue.session_mutation_ready.idle().wait(state).unwrap();
            }
        };
        process_event(queue.clone(), on_failure.clone(), event);
    }
}
