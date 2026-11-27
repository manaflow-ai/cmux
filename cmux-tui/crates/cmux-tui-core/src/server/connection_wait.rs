//! Legacy `wait-for` runs off the connection's dispatcher.
//!
//! A `wait-for` blocks until its pattern shows on the surface or its
//! `timeout_ms` passes, which the caller chooses (the app sends 60 s waits).
//! Run inline, it held every later request on its connection, terminal
//! creates too, until it ended. Now the dispatcher hands it to a worker
//! thread and moves on; the worker answers under the request's id when the
//! wait ends, with the same reply as before.
//!
//! No count bounds the workers: each is one thread, a `wait-for`'s with a
//! `RESOURCE_WORKER_STACK_BYTES` (256 KiB) stack, as a v2 `terminal.wait`'s
//! (device setup keeps the default stack: it runs the host's setup runner),
//! counted in `resource_wait_admission` for the drain. Only the long
//! connections' bound (`long_connection`) refuses one. The wait is handed
//! over in request order, so input sent before it reaches the terminal first; later requests no longer wait for its
//! end and may run while it makes its first check, and their replies may come
//! before its own (clients match replies by id). A one-shot check
//! (`timeout_ms` 0) does not wait and stays on the dispatcher. Closing the connection cancels the wait (the scheduler's
//! cancellation and the writer's close both wake it), and its worker returns
//! the permit as it ends. A graceful drain (the client half-closed after
//! sending) still waits for the reply, as it did inline.

use super::*;
use crate::panic_free::RecoverPoison;

impl Command {
    /// Commands that block until something outside the daemon happens, and
    /// so run on a wait worker rather than the connection's dispatcher. A
    /// one-shot `wait-for` (`timeout_ms` 0) is a single screen check: it stays
    /// on the dispatcher, exactly in request order, and takes no permit.
    pub(super) fn waits_off_dispatch(&self) -> bool {
        matches!(self, Self::WaitFor { timeout_ms, .. } if *timeout_ms > 0)
            || matches!(self, Self::DeviceSetup { .. })
    }
}

/// Ends one wait worker's share of the scheduler's drain, on every path.
struct ActiveWaitGuard(Arc<ConnectionSurfaceScheduler>);

impl Drop for ActiveWaitGuard {
    fn drop(&mut self) {
        let mut state = self.0.state.lock().recover_poison();
        state.active_waits = state.active_waits.saturating_sub(1);
        self.0.changed.notify_all();
    }
}

impl ConnectionSurfaceScheduler {
    /// Start `pending` (see [`Command::waits_off_dispatch`]) on a wait
    /// worker. Returns false when the connection must close.
    pub(super) fn submit_wait(
        self: &Arc<Self>,
        mux: &Arc<Mux>,
        client: u64,
        pending: PendingSurfaceRequest,
        writer: &MessageWriter,
    ) -> bool {
        // The wait outlives its request for as long as the caller chose: a
        // terminal's connection leaves the short lane first (`long_connection`).
        // At the bound nothing started and the connection goes on.
        if let Err(full) = writer.long.hold() {
            let id = pending.request.id.clone();
            drop(pending);
            return send_request_error(writer, id, &full.to_string());
        }
        let permit = mux.control_clients.resource_wait_admission.reserve(client);
        let mut builder = std::thread::Builder::new().name("mux-control-wait".into());
        if matches!(pending.request.cmd, Command::WaitFor { .. }) {
            builder = builder.stack_size(RESOURCE_WORKER_STACK_BYTES);
        }
        self.state.lock().recover_poison().active_waits += 1;
        let active = ActiveWaitGuard(self.clone());
        // The request is handed over exactly once: to the worker, or back to
        // the spawn-failure path below.
        let shared_pending = Arc::new(Mutex::new(Some(pending)));
        let worker_pending = shared_pending.clone();
        let worker_scheduler = self.clone();
        let worker_mux = mux.clone();
        let worker_writer = writer.clone();
        let spawn = builder.spawn(move || {
            // Return the permit before the drain counts this wait as done.
            let _active = active;
            let _permit = permit;
            let Some(pending) = worker_pending.lock().recover_poison().take() else {
                return;
            };
            if !run_pending_request(&worker_scheduler, &worker_mux, client, pending, &worker_writer)
            {
                worker_scheduler.close();
            }
        });
        match spawn {
            Ok(_) => writer.is_open(),
            Err(error) => {
                // The closure (with its permit and drain guard) was dropped.
                let Some(pending) = shared_pending.lock().recover_poison().take() else {
                    return writer.is_open();
                };
                let id = pending.request.id.clone();
                drop(pending);
                send_request_error(writer, id, &format!("could not start wait-for worker: {error}"))
            }
        }
    }
}
